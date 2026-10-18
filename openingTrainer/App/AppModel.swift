import Foundation
import Observation
import OpeningCore

/// Shared services and the open documents.
@Observable
final class AppModel {
    let auth = LichessAuth()
    let stats = StatsStore()
    let library = RepertoireLibrary()
    @ObservationIgnored lazy var queue = ExplorerQueue(store: stats, auth: auth)

    private(set) var documents: [String: RepertoireDocument] = [:]
    /// Why an entry could not be opened, by entry id.
    private(set) var openErrors: [String: String] = [:]
    @ObservationIgnored private var opening: [String: Task<RepertoireDocument?, Never>] = [:]
    /// Old entry id → new one, for renamed repertoires, so open screens keep their document.
    private var renamedIDs: [String: String] = [:]

    /// Opens (or returns the already open) document for a library entry. The PGN is parsed
    /// in the background; concurrent calls for the same entry share one load.
    func open(_ entry: RepertoireEntry) async -> RepertoireDocument? {
        if let existing = documents[entry.id] { return existing }
        if let task = opening[entry.id] { return await task.value }
        let task = Task { () -> RepertoireDocument? in
            defer { opening[entry.id] = nil }
            do {
                let (text, tree) = try await RepertoireDocument.load(entry.pgnURL)
                if let existing = documents[entry.id] { return existing }
                let doc = try RepertoireDocument(entry: entry, text: text, tree: tree, store: stats, queue: queue)
                documents[entry.id] = doc
                openErrors[entry.id] = nil
                return doc
            } catch {
                openErrors[entry.id] = "Could not open \(entry.name): \(error.localizedDescription)"
                return nil
            }
        }
        opening[entry.id] = task
        return await task.value
    }

    func rename(_ document: RepertoireDocument, to name: String) throws {
        let oldID = document.entryID
        try document.rename(to: name, in: library)
        guard document.entryID != oldID else { return }
        documents[oldID] = nil
        documents[document.entryID] = document
        renamedIDs[oldID] = document.entryID
    }

    /// The current id of an entry that may have been renamed since `id` was taken.
    func currentID(_ id: String) -> String {
        var id = id
        while let next = renamedIDs[id], next != id { id = next }
        return id
    }

    func close(_ entryID: String) {
        documents[entryID]?.close()
        documents[entryID] = nil
        openErrors[entryID] = nil
    }

    func flushAll() {
        for doc in documents.values { doc.flush() }
    }

    func closeAll() {
        for id in Array(documents.keys) { close(id) }
    }
}
