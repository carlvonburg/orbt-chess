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

    /// A row while the folder is listed (`RepertoireLibrary.remembered`); no file.
    static func placeholder(_ name: String) -> RepertoireEntry {
        let none = URL(filePath: "/dev/null")
        return RepertoireEntry(id: "placeholder:" + name, name: name, pgnURL: none, sidecarURL: none,
                               sidecarData: nil, sidecar: nil, isDownloading: false)
    }

    static func == (a: RepertoireEntry, b: RepertoireEntry) -> Bool {
        a.id == b.id && a.name == b.name && a.pgnURL == b.pgnURL && a.sidecarURL == b.sidecarURL
            && a.sidecarData == b.sidecarData && a.isDownloading == b.isDownloading
    }
}

/// A repertoire as the library last listed it: its row while the folder is listed again.
nonisolated struct RememberedRepertoire: Codable, Equatable, Sendable {
    var name: String
    /// The side it is for; nil when not set up.
    var white: Bool?
}

/// The repertoires in the app's iCloud Drive folder ("ORBT Chess" in Files), or in the device's
/// own Documents folder: when Dropbox or Google Drive syncs them instead (one syncs them, never
/// two), when sync is off, or without iCloud. Imported PGNs are copied into this folder.
@Observable
final class RepertoireLibrary {
    nonisolated static let containerID = "iCloud.org.orbtchess.orbt"
    nonisolated static let sidecarExtension = OpeningCoreRust.sidecarExtension()

    private(set) var folder: URL?
    private(set) var usesICloud = false
    /// iCloud Drive's folder as onboarding's sync menu shows it: `usesICloud`, or the device's
    /// folder standing in for it (`SlowICloudSimulation`, DEBUG only).
    var isICloud: Bool {
        #if DEBUG
        if SlowICloudSimulation.seconds != nil { return true }
        #endif
        return usesICloud
    }
    private(set) var entries: [RepertoireEntry] = [] {
        didSet { rememberRepertoires() }
    }
    /// The folder's listing is complete: no repertoires now means there are none. iCloud Drive
    /// lists its files a while after launch on a new install or after an update.
    private(set) var isLoaded = false {
        didSet { rememberRepertoires() }
    }
    /// The repertoires when last seen on this device: while iCloud Drive lists the folder, the
    /// library shows them as placeholders (HIG, Launching: restore the previous state), never
    /// the welcome screen (`RootView`).
    let remembered: [RememberedRepertoire]
    /// Repertoires are expected: remembered, or (after an update from a version that did not
    /// remember them) a repertoire was set up on this device, whose setup choices are kept.
    let expectsRepertoires: Bool
    var lastError: String?

    @ObservationIgnored private var presenter: FilePresenter?
    @ObservationIgnored private var scheduledRefresh: Task<Void, Never>?
    @ObservationIgnored private var scanGeneration = 0
    /// The folder to use instead of looking for one (tests).
    @ObservationIgnored private let fixedFolder: URL?
    /// `SlowICloudSimulation`: the folder's repertoires are not listed yet.
    @ObservationIgnored private var hidesRepertoires = false
    /// iCloud Drive's list of the folder's PGNs, until the folder shows them (`waitForICloudListing`).
    @ObservationIgnored private var listing: NSMetadataQuery?
    @ObservationIgnored private var listingObservers: [any NSObjectProtocol] = []

    /// Resumed once the folder is known (`readyFolder`).
    @ObservationIgnored private var folderWaiters: [CheckedContinuation<URL, Never>] = []

    private static let rememberedKey = "libraryRepertoires"

    init(folder: URL? = nil) {
        fixedFolder = folder
        #if DEBUG
        if folder == nil, let launch = SlowICloudSimulation.launch {
            remembered = launch == .returning ? [RememberedRepertoire(name: SlowICloudSimulation.sampleName, white: true)] : []
            expectsRepertoires = launch != .new
            return
        }
        #endif
        remembered = folder == nil ? Self.loadRemembered() : []
        expectsRepertoires = !remembered.isEmpty
            || folder == nil && UserDefaults.standard.object(forKey: RepertoireSettingsDraft.sourceKey) != nil
    }

    /// The folder, once `setUp` has found it (iCloud Drive's can take a while after an install):
    /// onboarding's ways in can be used before.
    func readyFolder() async -> URL {
        if let folder { return folder }
        return await withCheckedContinuation { folderWaiters.append($0) }
    }

    /// iCloud Drive's folder, when there is one (`inICloud`); else the device's.
    func setUp(inICloud: Bool = true) async {
        guard folder == nil else { return }
        if let fixedFolder {
            use(fixedFolder, iCloud: false)
        } else if await simulatesSlowICloud() {
            // The device's folder, listed later (DEBUG only).
            return
        } else if inICloud, let ubiquity = await Self.iCloudFolder() {
            use(ubiquity, iCloud: true)
            await refresh()
            if entries.isEmpty { waitForICloudListing() } else { isLoaded = true }
            return
        } else {
            use(URL.documentsDirectory, iCloud: false)
        }
        await refresh()
        isLoaded = true
    }

    /// The folder showed no repertoires, which in iCloud Drive may only mean that its files are
    /// not listed yet. Its metadata query says which PGNs the folder holds once it has gathered
    /// (Apple's way to list a ubiquity container): none, and the library is empty; some, and
    /// it is loaded when the folder shows them (`refresh`), or after 20 seconds at most.
    private func waitForICloudListing() {
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K LIKE '*.pgn'", NSMetadataItemFSNameKey)
        query.operationQueue = .main
        let center = NotificationCenter.default
        listingObservers = [NSNotification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate].map { name in
            center.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.listingChanged() }
            }
        }
        listing = query
        query.start()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            self?.listingComplete()
        }
    }

    private func listingChanged() {
        guard let query = listing else { return }
        query.disableUpdates()
        let pgns = query.resultCount
        query.enableUpdates()
        if pgns == 0 {
            listingComplete()
        } else {
            Task { await refresh() }
        }
    }

    /// The listing is in: what the folder shows is what there is.
    private func listingComplete() {
        listing?.stop()
        listing = nil
        listingObservers.forEach(NotificationCenter.default.removeObserver)
        listingObservers = []
        isLoaded = true
    }

    /// Remembers the repertoires, for the next launch (`remembered`).
    private func rememberRepertoires() {
        #if DEBUG
        if SlowICloudSimulation.seconds != nil { return }
        #endif
        guard fixedFolder == nil, isLoaded || !entries.isEmpty else { return }
        let now = entries.map { RememberedRepertoire(name: $0.name, white: $0.sidecar.map { $0.color() == .white }) }
        guard now != Self.loadRemembered() else { return }
        UserDefaults.standard.set(try? JSONEncoder().encode(now), forKey: Self.rememberedKey)
    }

    private static func loadRemembered() -> [RememberedRepertoire] {
        guard let data = UserDefaults.standard.data(forKey: rememberedKey) else { return [] }
        return (try? JSONDecoder().decode([RememberedRepertoire].self, from: data)) ?? []
    }

    /// Moves the repertoires to iCloud Drive's folder or to the device's (close the documents
    /// first). A file already there is merged with the one moved (the core's merge, as the sync
    /// does); none is lost. The device's copies are removed once moved; iCloud Drive's stay, as
    /// the Mac or iPad still syncing with it has them. Without iCloud, it stays on the device.
    func move(toICloud: Bool) async throws {
        guard let source = folder, fixedFolder == nil, toICloud != usesICloud else { return }
        let destination: URL
        if toICloud {
            guard let ubiquity = await Self.iCloudFolder() else { return }
            destination = ubiquity
        } else {
            destination = URL.documentsDirectory
        }
        let removing = !usesICloud
        try await Task.detached(priority: .userInitiated) {
            try Self.moveRepertoireFiles(from: source, to: destination, removingSource: removing)
        }.value
        presenter?.stop()
        presenter = nil
        scheduledRefresh?.cancel()
        entries = []
        use(destination, iCloud: toICloud)
        await refresh()
    }

    private func use(_ url: URL, iCloud: Bool) {
        folder = url
        usesICloud = iCloud
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let presenter = FilePresenter(url: url) { [weak self] in self?.scheduleRefresh() }
        presenter.start()
        self.presenter = presenter
        folderWaiters.forEach { $0.resume(returning: url) }
        folderWaiters = []
    }

    /// `SlowICloudSimulation`: always false in Release builds.
    private func simulatesSlowICloud() async -> Bool {
        #if DEBUG
        guard let seconds = SlowICloudSimulation.seconds, fixedFolder == nil else { return false }
        try? await Task.sleep(for: .seconds(seconds))
        hidesRepertoires = true
        if SlowICloudSimulation.launch != nil {
            let scratch = SlowICloudSimulation.scratchFolder
            let pgn = scratch.appending(path: SlowICloudSimulation.sampleName + ".pgn")
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: pgn.path) {
                try? FileAccess.write(Data(newRepertoirePgn(name: SlowICloudSimulation.sampleName).utf8), to: pgn)
                try? FileAccess.write(RepertoireSettingsDraft().makeSidecar(), to: Self.sidecarURL(for: pgn))
            }
            use(scratch, iCloud: false)
        } else {
            use(URL.documentsDirectory, iCloud: false)
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            hidesRepertoires = false
            await refresh()
            // As iCloud Drive's metadata query gathering (`waitForICloudListing`).
            listingComplete()
        }
        return true
        #else
        return false
        #endif
    }

    nonisolated private static func iCloudFolder() async -> URL? {
        await Task.detached {
            FileManager.default.url(forUbiquityContainerIdentifier: containerID)?
                .appending(path: "Documents", directoryHint: .isDirectory)
        }.value
    }

    /// The repertoires' files (PGNs, sidecars, review logs) of `source` into `destination`,
    /// iCloud placeholders downloaded on the way (the coordinated read waits for them).
    nonisolated static func moveRepertoireFiles(from source: URL, to destination: URL, removingSource: Bool) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let names = Set(((try? fm.contentsOfDirectory(atPath: source.path)) ?? []).map { name in
            // ".Najdorf.pgn.icloud": a file iCloud has not downloaded yet.
            name.hasPrefix(".") && name.hasSuffix(".icloud") ? String(name.dropFirst().dropLast(".icloud".count)) : name
        })
        for name in names.sorted() where syncFileKind(name: name) != nil {
            let from = source.appending(path: name)
            let to = destination.appending(path: name)
            let data = try FileAccess.read(from)
            if fm.fileExists(atPath: to.path) {
                let there = try FileAccess.read(to)
                let merged = syncMergeFiles(name: name, local: there, other: data) ?? there
                if merged != there { try FileAccess.write(merged, to: to) }
            } else {
                try FileAccess.write(data, to: to)
            }
            if removingSource { try FileAccess.delete(from) }
        }
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
        let result = hidesRepertoires ? [] : await Task.detached(priority: .userInitiated) { Self.scan(folder) }.value
        // A later scan started meanwhile and has fresher results.
        guard generation == scanGeneration else { return }
        if result != entries { entries = result }
        // iCloud Drive's files have arrived (`waitForICloudListing`).
        if listing != nil, !entries.isEmpty { listingComplete() }
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
        try add(name: name, pgn: { Data(newRepertoirePgn(name: $0).utf8) }, sidecar: sidecar)
    }

    /// Adds a PGN picked from Files as `<name>.pgn`, with its sidecar. Nothing is written
    /// until the user has set it up, so cancelling leaves no file behind.
    func importPGN(data: Data, name: String, sidecar: Data) throws -> RepertoireEntry {
        try add(name: name, pgn: { _ in data }, sidecar: sidecar)
    }

    private func add(name: String, pgn: (String) throws -> Data, sidecar: Data) throws -> RepertoireEntry {
        guard let folder else { throw CocoaError(.fileNoSuchFile) }  // `readyFolder` first
        let clean = Self.cleanName(name)
        guard !clean.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        let url = folder.appending(path: clean + ".pgn")
        guard !FileManager.default.fileExists(atPath: url.path),
              !FileManager.default.fileExists(atPath: Self.sidecarURL(for: url).path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try FileAccess.write(pgn(clean), to: url)
        try FileAccess.write(sidecar, to: Self.sidecarURL(for: url))
        return insertEntry(for: url)
    }

    /// A PGN picked from Files, read in its security scope: its bytes and a name for it.
    nonisolated static func readImport(_ url: URL) throws -> (data: Data, name: String) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try FileAccess.read(url)
        return (data, cleanName(url.deletingPathExtension().lastPathComponent).nonEmpty ?? "Imported")
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

nonisolated private extension String {
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

