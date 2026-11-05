import Foundation
import Observation
import OpeningCoreRust

enum AppTab: Hashable {
    case repertoires, statistics
}

/// Shared services and the open documents.
@Observable
final class AppModel {
    var selectedTab = AppTab.repertoires
    /// The setup sheet shown over the whole app (`RootView`), from onboarding or the library.
    var setup: SetupRequest?
    /// A repertoire just set up, for the library to show (`LibraryView.openPending`).
    var pendingShow: PendingShow?
    /// The Statistics tab's repertoire, set when a repertoire's overview shows more.
    var statisticsScope = StatisticsModel.Scope.all

    let auth = LichessAuth()
    let stats = ExplorerCacheStore()
    let library = RepertoireLibrary()
    @ObservationIgnored lazy var queue = ExplorerService(store: stats, auth: auth)
    @ObservationIgnored lazy var coverage = CoverageTables(explorer: queue)
    @ObservationIgnored lazy var sync = SyncService(library: library) { [unowned self] in Array(self.documents.values) }
    let engineNetwork = EngineNetwork()
    @ObservationIgnored lazy var engine = EngineService(network: engineNetwork)

    private(set) var documents: [String: RepertoireDocument] = [:]
    /// Why an entry could not be opened, by entry id.
    private(set) var openErrors: [String: String] = [:]
    /// Open repertoires deleted elsewhere (another device, iCloud Drive, Files): their screens
    /// close (`LibraryView`).
    private(set) var removedEntryIDs: Set<String> = []
    @ObservationIgnored private var opening: [String: Task<RepertoireDocument?, Never>] = [:]
    /// Closed documents' last saves (done ones return at once); opening the entry again waits
    /// for them.
    @ObservationIgnored private var closing: [String: Task<Void, Never>] = [:]
    /// Old entry id → new one, for renamed repertoires, so open screens keep their document.
    private var renamedIDs: [String: String] = [:]

    /// Sets up the library's folder (the device's while Dropbox or Google Drive syncs it), then
    /// the sync. Repertoires still in iCloud Drive with a provider chosen (before one synced them
    /// alone) are moved to the device first.
    func setUpLibrary() async {
        sync.moveFolder = { [unowned self] toICloud in await moveRepertoires(toICloud: toICloud) }
        let onDevice = UserDefaults.standard.bool(forKey: Self.onDeviceKey)
        await library.setUp(inICloud: !onDevice)
        if SyncService.chosenProvider() != nil, library.usesICloud { await moveRepertoires(toICloud: false) }
        #if DEBUG
        // Nothing synced from a simulated folder (`SlowICloudSimulation`).
        if SlowICloudSimulation.seconds != nil { return }
        #endif
        sync.start()
    }

    /// The repertoires were moved to the device (a provider syncs them, or sync is off): iCloud
    /// Drive's folder, which still has its old copies, is not used again until moved back.
    static let onDeviceKey = "repertoiresOnDevice"

    /// Moves the repertoires between iCloud Drive and the device (`RepertoireLibrary.move`),
    /// the open ones saved and closed first.
    func moveRepertoires(toICloud: Bool) async {
        guard toICloud != library.usesICloud else { return }
        await flushAll()
        closeAll()
        for task in closing.values { await task.value }
        do {
            try await library.move(toICloud: toICloud)
            UserDefaults.standard.set(!library.usesICloud, forKey: Self.onDeviceKey)
        } catch {
            library.lastError = "Could not move the repertoires: \(error.localizedDescription)"
        }
        await reloadCoverageTables()
    }

    /// Loads the offline coverage tables and reads which ones the server offers.
    func setUpCoverageTables() async {
        await coverage.setUp(appFolder: library.folder)
    }

    /// Picks up tables added to the app folder's "Coverage" subfolder.
    func reloadCoverageTables() async {
        guard let folder = library.folder else { return }
        await coverage.load(from: folder.appending(path: "Coverage", directoryHint: .isDirectory))
    }

    /// Opens (or returns the already open) document for a library entry. The files are read
    /// and parsed in the background; concurrent calls for the same entry share one load.
    func open(_ entry: RepertoireEntry) async -> RepertoireDocument? {
        if let existing = documents[entry.id] { return existing }
        if let task = opening[entry.id] { return await task.value }
        let task = Task { [self] () -> RepertoireDocument? in
            defer { opening[entry.id] = nil }
            await closing[entry.id]?.value
            do {
                let loaded = try await RepertoireDocument.load(pgnURL: entry.pgnURL, sidecarURL: entry.sidecarURL,
                                                              defaults: TrainingDefaults.studyDefaults, explorer: queue.core)
                if let existing = documents[entry.id] { return existing }
                let doc = RepertoireDocument(entry: entry, loaded: loaded, explorer: queue)
                doc.onRemoved = { [weak self, weak doc] in
                    guard let self, let doc, self.documents[doc.entryID] === doc else { return }
                    self.documents[doc.entryID] = nil
                    self.removedEntryIDs.insert(doc.entryID)
                    Task { await self.library.refresh() }
                }
                doc.onRenamed = { [weak self, weak doc] oldID in
                    guard let self, let doc else { return }
                    self.moved(doc, from: oldID)
                    Task { await self.library.refresh() }
                }
                coverage.want(doc.sidecar.database)
                documents[entry.id] = doc
                openErrors[entry.id] = nil
                removedEntryIDs.remove(entry.id)
                return doc
            } catch {
                openErrors[entry.id] = "Could not open \(entry.name): \(error.localizedDescription)"
                return nil
            }
        }
        opening[entry.id] = task
        return await task.value
    }

    func rename(_ document: RepertoireDocument, to name: String) async throws {
        let oldID = document.entryID
        try await document.rename(to: name, in: library)
        moved(document, from: oldID)
    }

    private func moved(_ document: RepertoireDocument, from oldID: String) {
        guard document.entryID != oldID else { return }
        if documents[oldID] === document { documents[oldID] = nil }
        documents[document.entryID] = document
        renamedIDs[oldID] = document.entryID
    }

    /// The current id of an entry that may have been renamed since `id` was taken.
    func currentID(_ id: String) -> String {
        var id = id
        while let next = renamedIDs[id], next != id { id = next }
        return id
    }

    /// Closes the document; it finishes saving in the background.
    func close(_ entryID: String) {
        openErrors[entryID] = nil
        guard let doc = documents.removeValue(forKey: entryID) else { return }
        let previous = closing[entryID]
        closing[entryID] = Task {
            await previous?.value
            await doc.close()
        }
    }

    /// Deletes a repertoire's files. Its open document is dropped without saving, so nothing
    /// writes the files again.
    func delete(_ entry: RepertoireEntry) async throws {
        documents.removeValue(forKey: entry.id)?.discard()
        openErrors[entry.id] = nil
        await closing[entry.id]?.value
        try await library.delete(entry)
    }

    /// Writes every pending change, including documents still closing.
    func flushAll() async {
        for doc in documents.values { await doc.flush() }
        for task in closing.values { await task.value }
    }

    func closeAll() {
        for id in Array(documents.keys) { close(id) }
    }
}

/// A repertoire to show when the library appears: on Browse (`build`) or its overview.
struct PendingShow: Equatable {
    let entryID: String
    let build: Bool
}
