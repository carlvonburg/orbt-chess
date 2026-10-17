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
    var openError: String?

    /// Opens (or returns the already open) document for a library entry.
    func document(for entry: RepertoireEntry) -> RepertoireDocument? {
        if let existing = documents[entry.id] { return existing }
        do {
            let doc = try RepertoireDocument(entry: entry, store: stats, queue: queue)
            documents[entry.id] = doc
            return doc
        } catch {
            openError = "Could not open \(entry.name): \(error.localizedDescription)"
            return nil
        }
    }

    func close(_ entryID: String) {
        documents[entryID]?.close()
        documents[entryID] = nil
    }

    func flushAll() {
        for doc in documents.values { doc.flush() }
    }

    func closeAll() {
        for id in Array(documents.keys) { close(id) }
    }
}
