import Foundation
import Observation
import OpeningCore

struct RepertoireEntry: Identifiable, Equatable {
    /// Path of the sidecar, stable across launches.
    let id: String
    var name: String
    /// nil for a connected PGN whose bookmark cannot be resolved on this device.
    var pgnURL: URL?
    var sidecarURL: URL
    /// nil when a PGN was dropped into the folder and has not been set up yet.
    var sidecar: Sidecar?
    var isConnected: Bool
    var isDownloading: Bool

    var needsSetup: Bool { sidecar == nil }
    var needsReconnect: Bool { isConnected && pgnURL == nil }
}

/// The repertoires in the app's iCloud Drive folder ("Opening Trainer" in Files) plus
/// PGNs connected from elsewhere. Falls back to the local Documents folder without iCloud.
@Observable
final class RepertoireLibrary {
    nonisolated static let containerID = "iCloud.ch.cvb.openingTrainer"
    static let sidecarExtension = "otrep.json"

    private(set) var folder: URL?
    private(set) var usesICloud = false
    private(set) var entries: [RepertoireEntry] = []
    private(set) var isLoaded = false
    var lastError: String?

    @ObservationIgnored private var presenter: FilePresenter?

    var connectedFolder: URL? { folder?.appending(path: "Connected", directoryHint: .isDirectory) }

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
            let presenter = FilePresenter(url: folder) { [weak self] in self?.refresh() }
            presenter.start()
            self.presenter = presenter
        }
        refresh()
        isLoaded = true
    }

    func refresh() {
        guard let folder else { return }
        var result: [RepertoireEntry] = []
        let fm = FileManager.default
        let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsPackageDescendants])
        var pgns: [URL] = []
        var placeholders: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == "Connected" { enumerator?.skipDescendants(); continue }
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
        for pgn in pgns + placeholders {
            let sidecarURL = Self.sidecarURL(for: pgn)
            let sidecar = (try? FileAccess.read(sidecarURL)).flatMap { try? Sidecar.decode($0) }
            if sidecar == nil { try? fm.startDownloadingUbiquitousItem(at: sidecarURL) }
            result.append(RepertoireEntry(id: sidecarURL.path, name: pgn.deletingPathExtension().lastPathComponent,
                                          pgnURL: pgn, sidecarURL: sidecarURL, sidecar: sidecar,
                                          isConnected: false, isDownloading: placeholders.contains(pgn)))
        }
        if let connectedFolder, let files = try? fm.contentsOfDirectory(at: connectedFolder, includingPropertiesForKeys: nil) {
            for url in files where url.lastPathComponent.hasSuffix(Self.sidecarExtension) {
                guard let sidecar = (try? FileAccess.read(url)).flatMap({ try? Sidecar.decode($0) }) else { continue }
                var pgnURL: URL?
                if let bookmark = sidecar.bookmark {
                    var stale = false
                    pgnURL = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale)
                }
                result.append(RepertoireEntry(id: url.path, name: sidecar.connectedName ?? "Connected PGN",
                                              pgnURL: pgnURL, sidecarURL: url, sidecar: sidecar,
                                              isConnected: true, isDownloading: false))
            }
        }
        entries = result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func sidecarURL(for pgn: URL) -> URL {
        pgn.deletingPathExtension().appendingPathExtension(sidecarExtension)
    }

    func entry(id: String) -> RepertoireEntry? { entries.first { $0.id == id } }

    /// Creates `<name>.pgn` and its sidecar in the repertoire folder.
    func create(name: String, sidecar: Sidecar) throws -> RepertoireEntry {
        guard let folder else { throw CocoaError(.fileNoSuchFile) }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        guard !clean.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        let pgn = folder.appending(path: clean + ".pgn")
        guard !FileManager.default.fileExists(atPath: pgn.path) else { throw CocoaError(.fileWriteFileExists) }
        var tree = RepertoireTree()
        tree.renameFirstChapter(clean)
        try FileAccess.write(Data(tree.pgnText().utf8), to: pgn)
        try FileAccess.write(sidecar.encoded(), to: Self.sidecarURL(for: pgn))
        refresh()
        return entry(id: Self.sidecarURL(for: pgn).path)!
    }

    /// Connects a PGN picked from Files. Only the PGN itself is accessible, so the sidecar
    /// lives in the app folder together with a bookmark to the file.
    func connect(_ url: URL, sidecar: Sidecar) throws -> RepertoireEntry {
        guard let connectedFolder else { throw CocoaError(.fileNoSuchFile) }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        var sidecar = sidecar
        sidecar.bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        sidecar.connectedName = url.deletingPathExtension().lastPathComponent
        try FileManager.default.createDirectory(at: connectedFolder, withIntermediateDirectories: true)
        let sidecarURL = connectedFolder.appending(path: "\(sidecar.id.uuidString).\(Self.sidecarExtension)")
        try FileAccess.write(sidecar.encoded(), to: sidecarURL)
        refresh()
        return entry(id: sidecarURL.path)!
    }

    /// Writes a sidecar for a PGN that was dropped into the folder, or updates the bookmark of a connected PGN.
    func saveSidecar(_ sidecar: Sidecar, for entry: RepertoireEntry) throws {
        try FileAccess.write(sidecar.encoded(), to: entry.sidecarURL)
        refresh()
    }

    func reconnect(_ entry: RepertoireEntry, to url: URL) throws {
        guard var sidecar = entry.sidecar else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        sidecar.bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        try saveSidecar(sidecar, for: entry)
    }

    /// Deletes a repertoire from the folder (PGN and sidecar). For a connected PGN only the
    /// link and training data are removed; the PGN itself is left alone.
    func delete(_ entry: RepertoireEntry) throws {
        if !entry.isConnected, let pgn = entry.pgnURL { try FileAccess.delete(pgn) }
        try? FileAccess.delete(entry.sidecarURL)
        refresh()
    }
}

extension RepertoireTree {
    mutating func renameFirstChapter(_ name: String) {
        setChapterTag(0, "Event", name)
    }
}
