import Foundation
import Observation
import OpeningCore

struct RepertoireEntry: Identifiable, Equatable {
    /// Path of the sidecar, stable across launches.
    let id: String
    var name: String
    var pgnURL: URL
    var sidecarURL: URL
    /// nil when a PGN was dropped into the folder and has not been set up yet.
    var sidecar: Sidecar?
    var isDownloading: Bool

    var needsSetup: Bool { sidecar == nil }
}

/// The repertoires in the app's iCloud Drive folder ("Opening Trainer" in Files). Falls back
/// to the local Documents folder without iCloud. Imported PGNs are copied into this folder.
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
                                          isDownloading: placeholders.contains(pgn)))
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
        let clean = Self.cleanName(name)
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
                || FileManager.default.fileExists(atPath: Self.sidecarURL(for: pgn).path) {
            pgn = folder.appending(path: "\(base) \(n).pgn")
            n += 1
        }
        try FileAccess.write(data, to: pgn)
        refresh()
        return entry(id: Self.sidecarURL(for: pgn).path)!
    }

    /// Writes a sidecar for a PGN that was imported or dropped into the folder.
    func saveSidecar(_ sidecar: Sidecar, for entry: RepertoireEntry) throws {
        try FileAccess.write(sidecar.encoded(), to: entry.sidecarURL)
        refresh()
    }

    /// Deletes a repertoire from the folder (PGN and sidecar).
    func delete(_ entry: RepertoireEntry) throws {
        try FileAccess.delete(entry.pgnURL)
        try? FileAccess.delete(entry.sidecarURL)
        refresh()
    }

    private static func cleanName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

extension RepertoireTree {
    mutating func renameFirstChapter(_ name: String) {
        setChapterTag(0, "Event", name)
    }
}
