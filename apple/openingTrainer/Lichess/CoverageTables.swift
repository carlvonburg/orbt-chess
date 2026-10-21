import Foundation
import Observation
import os
import OpeningCoreRust

/// Offline coverage tables: loads them into the core, lists the ones on the server
/// (`manifest.json`) and downloads them. Which file a repertoire needs and whether a download
/// is intact are decided by the core.
///
/// Downloads live in Application Support/Coverage (local, not synced: they can be downloaded
/// again). Tables put by hand in the app folder's "Coverage" subfolder are loaded too.
@Observable
final class CoverageTables {
    /// The tables in the core.
    private(set) var loaded: [CoverageTableInfo] = []
    /// What the server offers (the last manifest read, kept for offline use).
    private(set) var available: [CoverageFile] = []
    /// Downloads in progress: file name → fraction done.
    private(set) var downloads: [String: Double] = [:]
    var lastError: String?

    private let explorer: ExplorerService
    @ObservationIgnored private var loadedFiles: Set<String> = []
    /// Databases of open repertoires, downloaded once the manifest is known.
    @ObservationIgnored private var wanted: Set<ExplorerDatabase> = []
    /// Downloaded files the server has a different version of (rebuilt tables keep their names).
    @ObservationIgnored private var stale: Set<String> = []

    static let server = URL(string: "https://pub-7bc2c6c30e4d4311a454d55fb34e57ba.r2.dev/coverage_bins/")!
    static let directory = URL.applicationSupportDirectory.appending(path: "Coverage", directoryHint: .isDirectory)
    private static var savedManifest: URL { directory.appending(path: "manifest.json") }
    private static let log = Logger(subsystem: "ch.cvb.openingTrainer", category: "coverage")

    init(explorer: ExplorerService) {
        self.explorer = explorer
    }

    /// The loaded table for a database, if any.
    func table(for database: ExplorerDatabase) -> CoverageTableInfo? {
        loaded.first { $0.database == database }
    }

    /// The file to download for `database` (the deepest), if the server has one.
    func file(for database: ExplorerDatabase) -> CoverageFile? {
        coverageFileFor(files: available, database: database)
    }

    /// Whether the database's table is loaded (and is the deepest the server has).
    func isReady(_ database: ExplorerDatabase) -> Bool {
        guard let table = table(for: database) else { return false }
        guard let file = file(for: database) else { return true }
        return table.targetGames >= file.targetGames && !stale.contains(file.file)
    }

    /// Downloads the table of an opened repertoire's database, now or once the manifest is read.
    func want(_ database: ExplorerDatabase) {
        guard database != .masters else { return }
        wanted.insert(database)
        ensure(database)
    }

    /// Starts downloading the database's table unless it is here or already downloading.
    func ensure(_ database: ExplorerDatabase) {
        guard !isReady(database), let file = file(for: database), downloads[file.file] == nil else { return }
        Task { await download(file) }
    }

    /// Every selection there is: downloadable or already on the device.
    var selections: [ExplorerDatabase] {
        var result = coverageSelections(files: available).map(\.database)
        for table in loaded where !result.contains(table.database) { result.append(table.database) }
        return result
    }

    /// Loads local tables, then reads the server's list.
    func setUp(appFolder: URL?) async {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: Self.savedManifest) {
            available = coverageManifestFiles(json: data) ?? []
        }
        await load(from: Self.directory)
        if let appFolder {
            await load(from: appFolder.appending(path: "Coverage", directoryHint: .isDirectory))
        }
        await refreshManifest()
    }

    func refreshManifest() async {
        do {
            let (data, response) = try await URLSession.shared.data(from: Self.server.appending(path: "manifest.json"))
            guard (response as? HTTPURLResponse)?.statusCode == 200, let files = coverageManifestFiles(json: data) else {
                Self.log.error("coverage manifest: unexpected response")
                return
            }
            available = files
            try? data.write(to: Self.savedManifest, options: .atomic)
            let directory = Self.directory
            stale = await Task.detached {
                Set(files.filter { file in
                    guard let bytes = try? Data(contentsOf: directory.appending(path: file.file)) else { return false }
                    return !coverageFileVerify(file: file, bytes: bytes)
                }.map(\.file))
            }.value
            for database in wanted { ensure(database) }
        } catch {
            Self.log.error("coverage manifest: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Downloads a table, checks it, replaces any other file for the same selection and loads it.
    func download(_ file: CoverageFile) async {
        guard downloads[file.file] == nil else { return }
        downloads[file.file] = 0
        lastError = nil
        // No Lichess requests for this database meanwhile: the table answers most of them.
        explorer.core.expectCoverageTable(database: file.database)
        defer {
            downloads[file.file] = nil
            explorer.core.coverageTableDownloadEnded(database: file.database)
        }
        do {
            let temporary = try await Self.fetch(Self.server.appending(path: file.file)) { [weak self] fraction in
                self?.downloads[file.file] = fraction
            }
            let destination = Self.directory.appending(path: file.file)
            let intact = await Task.detached {
                guard let data = try? Data(contentsOf: temporary) else { return false }
                return coverageFileVerify(file: file, bytes: data)
            }.value
            guard intact else {
                try? FileManager.default.removeItem(at: temporary)
                lastError = "The download was damaged. Try again."
                return
            }
            for other in available where other.database == file.database && other.file != file.file {
                try? FileManager.default.removeItem(at: Self.directory.appending(path: other.file))
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            stale.remove(file.file)
            loadedFiles.remove(Self.directory.standardizedFileURL.path + "/" + file.file)
            await load(from: Self.directory)
        } catch {
            lastError = "Could not download the table: \(error.localizedDescription)"
        }
    }

    /// Reads the tables (`*.otcb`, `*.otcb.zst`) in `directory` that are not loaded yet. Files
    /// iCloud has not downloaded yet are requested and picked up on a later call.
    func load(from directory: URL) async {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(".") && name.hasSuffix(".icloud") {
            let real = directory.appending(path: String(name.dropFirst().dropLast(".icloud".count)))
            try? FileManager.default.startDownloadingUbiquitousItem(at: real)
        }
        let path = directory.standardizedFileURL.path
        for name in names where (name.hasSuffix(".otcb") || name.hasSuffix(".otcb.zst")) && !loadedFiles.contains(path + "/" + name) {
            loadedFiles.insert(path + "/" + name)
            let url = directory.appending(path: name)
            let started = ContinuousClock.now
            let result = await Task.detached { () -> Result<CoverageTableFile, Error> in
                Result { try CoverageTableFile(bytes: try Data(contentsOf: url)) }
            }.value
            switch result {
            case .success(let file):
                let info = file.info()
                explorer.core.addCoverageTable(file: file)
                loaded.removeAll { $0.database == info.database }
                loaded.append(info)
                Self.log.info("coverage table \(name, privacy: .public): \(info.positions) positions in \(started.duration(to: .now).description, privacy: .public)")
            case .failure(let error):
                Self.log.error("coverage table \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Downloads to a temporary file, reporting progress on the main actor.
    private nonisolated static func fetch(_ url: URL, progress: @escaping @Sendable @MainActor (Double) -> Void) async throws -> URL {
        let box = ObservationBox()
        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: url) { @Sendable location, response, error in
                box.observation?.invalidate()
                if let error { return continuation.resume(throwing: error) }
                guard let location, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    return continuation.resume(throwing: URLError(.badServerResponse))
                }
                // The system deletes `location` when this returns: keep it.
                let kept = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
                do {
                    try FileManager.default.moveItem(at: location, to: kept)
                    continuation.resume(returning: kept)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            box.observation = task.progress.observe(\.fractionCompleted) { @Sendable p, _ in
                let fraction = p.fractionCompleted
                Task { @MainActor in progress(fraction) }
            }
            task.resume()
        }
    }

    private nonisolated final class ObservationBox: @unchecked Sendable {
        var observation: NSKeyValueObservation?
    }
}
