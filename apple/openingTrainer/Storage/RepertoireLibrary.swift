import Foundation
import Observation
import OpeningCoreRust

nonisolated struct RepertoireEntry: Identifiable, Equatable, Sendable {
    /// Path of the sidecar, stable across launches.
    let id: String
    var name: String
    var pgnURL: URL
    var sidecarURL: URL
    /// The sidecar file's bytes; nil when a PGN was dropped into the folder and has not been
    /// set up yet.
    var sidecarData: Data?
    /// The sidecar, read by the core, for the library row.
    var sidecar: LibrarySidecar?
    var isDownloading: Bool

    var needsSetup: Bool { sidecar == nil }

    static func == (a: RepertoireEntry, b: RepertoireEntry) -> Bool {
        a.id == b.id && a.name == b.name && a.pgnURL == b.pgnURL && a.sidecarURL == b.sidecarURL
            && a.sidecarData == b.sidecarData && a.isDownloading == b.isDownloading
    }
}

/// The repertoires in the app's iCloud Drive folder ("Opening Trainer" in Files). Falls back
/// to the local Documents folder without iCloud. Imported PGNs are copied into this folder.
@Observable
final class RepertoireLibrary {
    nonisolated static let containerID = "iCloud.ch.cvb.openingTrainer"
    nonisolated static let sidecarExtension = OpeningCoreRust.sidecarExtension()

    private(set) var folder: URL?
    private(set) var usesICloud = false
    private(set) var entries: [RepertoireEntry] = []
    private(set) var isLoaded = false
    var lastError: String?

    @ObservationIgnored private var presenter: FilePresenter?
    @ObservationIgnored private var scheduledRefresh: Task<Void, Never>?
    @ObservationIgnored private var scanGeneration = 0

    func setUp() async {
        guard folder == nil else { return }
        let ubiquity = await Task.detached {
            FileManager.default.url(forUbiquityContainerIdentifier: Self.containerID)
        }.value
        if let ubiquity {
            folder = ubiquity.appending(path: "Documents", directoryHint: .isDirectory)
            usesICloud = true
        } else {
            folder = URL.documentsDirectory
            usesICloud = false
        }
        if let folder {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let presenter = FilePresenter(url: folder) { [weak self] in self?.scheduleRefresh() }
            presenter.start()
            self.presenter = presenter
        }
        await refresh()
        isLoaded = true
    }

    /// Rescans soon. The folder reports every save of an open repertoire, so bursts of
    /// changes become one scan.
    func scheduleRefresh() {
        scheduledRefresh?.cancel()
        scheduledRefresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// Rescans the folder off the main actor.
    func refresh() async {
        guard let folder else { return }
        scanGeneration += 1
        let generation = scanGeneration
        let result = await Task.detached(priority: .userInitiated) { Self.scan(folder) }.value
        // A later scan started meanwhile and has fresher results.
        guard generation == scanGeneration else { return }
        if result != entries { entries = result }
    }

    nonisolated private static func scan(_ folder: URL) -> [RepertoireEntry] {
        let fm = FileManager.default
        let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsPackageDescendants])
        var pgns: [URL] = []
        var placeholders: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            let name = url.lastPathComponent
            if name.hasSuffix(".pgn") {
                pgns.append(url)
            } else if name.hasPrefix("."), name.hasSuffix(".pgn.icloud") {
                // iCloud placeholder ".Name.pgn.icloud" for a file that is not downloaded yet
                let real = url.deletingLastPathComponent().appending(path: String(name.dropFirst().dropLast(".icloud".count)))
                placeholders.append(real)
                try? fm.startDownloadingUbiquitousItem(at: real)
            }
        }
        let result = (pgns + placeholders).map { pgn in
            entry(for: pgn, isDownloading: placeholders.contains(pgn))
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    nonisolated private static func entry(for pgn: URL, isDownloading: Bool = false) -> RepertoireEntry {
        let sidecarURL = sidecarURL(for: pgn)
        let data = try? FileAccess.read(sidecarURL)
        let sidecar = data.flatMap { librarySidecar(data: $0) }
        if sidecar == nil { try? FileManager.default.startDownloadingUbiquitousItem(at: sidecarURL) }
        return RepertoireEntry(id: sidecarURL.path, name: pgn.deletingPathExtension().lastPathComponent,
                               pgnURL: pgn, sidecarURL: sidecarURL, sidecarData: sidecar == nil ? nil : data,
                               sidecar: sidecar, isDownloading: isDownloading)
    }

    /// Puts the entry for a file the app just wrote in the list right away; a scan follows.
    private func insertEntry(for pgn: URL) -> RepertoireEntry {
        let entry = Self.entry(for: pgn)
        var result = entries.filter { $0.id != entry.id }
        result.append(entry)
        entries = result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        scheduleRefresh()
        return entry
    }

    nonisolated static func sidecarURL(for pgn: URL) -> URL {
        pgn.deletingPathExtension().appendingPathExtension(sidecarExtension)
    }

    /// The review log next to a PGN.
    nonisolated static func revlogURL(for pgn: URL) -> URL {
        pgn.deletingPathExtension().appendingPathExtension(revlogExtension())
    }

    func entry(id: String) -> RepertoireEntry? { entries.first { $0.id == id } }

    /// Creates `<name>.pgn` and its sidecar (bytes from `newSidecar`) in the repertoire folder.
    func create(name: String, sidecar: Data) throws -> RepertoireEntry {
        guard let folder else { throw CocoaError(.fileNoSuchFile) }
        let clean = Self.cleanName(name)
        guard !clean.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        let pgn = folder.appending(path: clean + ".pgn")
        guard !FileManager.default.fileExists(atPath: pgn.path) else { throw CocoaError(.fileWriteFileExists) }
        try FileAccess.write(Data(newRepertoirePgn(name: clean).utf8), to: pgn)
        try FileAccess.write(sidecar, to: Self.sidecarURL(for: pgn))
        return insertEntry(for: pgn)
    }

    /// Copies a PGN picked from Files into the repertoire folder, as "Name 2.pgn" when the
    /// name is taken. The new entry has no sidecar yet and needs setup.
    func importPGN(from url: URL) throws -> RepertoireEntry {
        guard let folder else { throw CocoaError(.fileNoSuchFile) }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try FileAccess.read(url)
        let base = Self.cleanName(url.deletingPathExtension().lastPathComponent).nonEmpty ?? "Imported"
        var pgn = folder.appending(path: base + ".pgn")
        var n = 2
        while FileManager.default.fileExists(atPath: pgn.path)
                || FileManager.default.fileExists(atPath: Self.sidecarURL(for: pgn).path)
                || FileManager.default.fileExists(atPath: Self.revlogURL(for: pgn).path) {
            pgn = folder.appending(path: "\(base) \(n).pgn")
            n += 1
        }
        try FileAccess.write(data, to: pgn)
        return insertEntry(for: pgn)
    }

    /// Writes a sidecar for a PGN that was imported or dropped into the folder.
    func saveSidecar(_ sidecar: Data, for entry: RepertoireEntry) throws {
        try FileAccess.write(sidecar, to: entry.sidecarURL)
        _ = insertEntry(for: entry.pgnURL)
    }

    /// Renames a repertoire's PGN, sidecar and review log to `<name>.pgn`, `<name>.otrep.json`
    /// and `<name>.otlog.jsonl`. Blocking; returns the new PGN and sidecar.
    nonisolated static func renameFiles(pgn: URL, to name: String) throws -> (pgnURL: URL, sidecarURL: URL) {
        let clean = cleanName(name)
        guard !clean.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        let newPGN = pgn.deletingLastPathComponent().appending(path: clean + ".pgn")
        let sidecar = sidecarURL(for: pgn)
        let newSidecar = sidecarURL(for: newPGN)
        // A case-only rename points at the same file on a case-insensitive volume.
        let sameFile = newPGN.path.lowercased() == pgn.path.lowercased()
        if !sameFile, FileManager.default.fileExists(atPath: newPGN.path)
            || FileManager.default.fileExists(atPath: newSidecar.path) {
            throw CocoaError(.fileWriteFileExists)
        }
        if newPGN != pgn {
            try FileAccess.move(pgn, to: newPGN)
            do {
                try FileAccess.move(sidecar, to: newSidecar)
            } catch {
                try? FileAccess.move(newPGN, to: pgn)
                throw error
            }
            let revlog = revlogURL(for: pgn)
            if FileManager.default.fileExists(atPath: revlog.path) {
                try? FileAccess.move(revlog, to: revlogURL(for: newPGN))
            }
        }
        return (newPGN, newSidecar)
    }

    /// After someone else renamed a PGN from `old` to `new`, moves its sidecar and review log
    /// along, unless a file already has the new name.
    nonisolated static func moveCompanions(of old: URL, to new: URL) {
        for (from, to) in [(sidecarURL(for: old), sidecarURL(for: new)), (revlogURL(for: old), revlogURL(for: new))] {
            let fm = FileManager.default
            guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { continue }
            try? FileAccess.move(from, to: to)
        }
    }

    /// Deletes a repertoire from the folder (PGN, sidecar and review log).
    func delete(_ entry: RepertoireEntry) async throws {
        try await Task.detached(priority: .userInitiated) {
            try FileAccess.delete(entry.pgnURL)
            try? FileAccess.delete(entry.sidecarURL)
            try? FileAccess.delete(Self.revlogURL(for: entry.pgnURL))
        }.value
        entries.removeAll { $0.id == entry.id }
        scheduleRefresh()
    }

    /// The name as a file name: safe characters only, single spaces, no leading dot, at
    /// most 100 characters.
    nonisolated private static func cleanName(_ name: String) -> String {
        let words = name.safeRepertoireName.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(words.drop { $0 == "." || $0 == " " }.prefix(100))
            .trimmingCharacters(in: .whitespaces)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

nonisolated extension String {
    /// Keeps letters and digits of any script, spaces, and - _ . , ( ) ' & + !
    /// Path separators become "-" (":" becomes " -", as in "Ruy Lopez - Berlin"); emoji and
    /// other symbols that cause trouble in file names (on iOS, Windows or in sync) are removed.
    var safeRepertoireName: String {
        let allowed = Set("-_.,()'&+! ")
        return String(flatMap { c -> String in
            if c == ":" { return " -" }
            if "/\\".contains(c) { return "-" }
            if allowed.contains(c) { return String(c) }
            let ok = c.unicodeScalars.allSatisfy { scalar in
                switch scalar.properties.generalCategory {
                case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                     .decimalNumber, .letterNumber, .otherNumber, .spacingMark:
                    return true
                case .nonspacingMark:
                    // Accents, but not the emoji variation selector.
                    return scalar.value != 0xFE0F
                default:
                    return false
                }
            }
            return ok ? String(c) : ""
        })
    }
}

