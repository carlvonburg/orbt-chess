import Foundation
import Observation
import OpeningCoreRust

/// Loads cards and review logs for the Statistics tab: all repertoires (Anki's whole
/// collection) or one repertoire. The core decides what each scope counts.
@Observable
final class StatisticsModel {
    enum Scope: Hashable {
        case all
        case repertoire(String)
    }

    var scope = Scope.all

    private(set) var graphs: Graphs?
    private(set) var cards: [EPD: Card] = [:]
    /// The open repertoire, for reach, opening branches and move names.
    private(set) var document: RepertoireDocument?
    /// Moves still due today (with the daily limits, as Study counts them).
    private(set) var dueLeft = 0
    private(set) var isLoading = false

    func load(_ app: AppModel) async {
        isLoading = true
        defer { isLoading = false }
        let timing = SchedTiming()
        let offset = Int64(TimeZone.current.secondsFromGMT())
        switch scope {
        case .all:
            document = nil
            var parts: [GraphParts] = []
            var due = 0
            for entry in app.library.entries where !entry.needsSetup {
                let revlogURL = RepertoireLibrary.revlogURL(for: entry.pgnURL)
                if let doc = app.documents[entry.id] {
                    parts.append(await doc.graphParts(wholeCollection: true))
                } else if let sidecar = entry.sidecar {
                    parts.append(sidecar.graphParts(revlog: await StudyLog.readData(revlogURL)))
                }
                due += Int(EntryStats(entry: entry, document: app.documents[entry.id]).counts.total)
            }
            cards = [:]
            dueLeft = due
            graphs = Graphs.fromParts(parts: parts, timing: timing, localOffsetSecs: offset)
        case .repertoire(let id):
            guard let entry = app.library.entry(id: id), let doc = await app.open(entry) else {
                graphs = nil
                return
            }
            document = doc
            cards = doc.core.repertoireCards()
            dueLeft = Int(EntryStats(document: doc).counts.total)
            let parts = await doc.graphParts(wholeCollection: false)
            graphs = Graphs.fromParts(parts: [parts], timing: timing, localOffsetSecs: offset)
        }
    }

    // MARK: Chess statistics

    var expectedRecall: Double? {
        guard let document else { return nil }
        return OpeningCoreRust.expectedRecall(cards: cards, reach: document.core.cardReach(),
                                              nowSecs: Date.now.timeIntervalSince1970)
    }

    func weakestMoves(limit: Int) -> [WeakMove] {
        OpeningCoreRust.weakestMoves(cards: cards, nowSecs: Date.now.timeIntervalSince1970, limit: UInt32(limit))
    }

    /// The first node with a position, for naming and opening it.
    func node(for epd: EPD) -> NodeID? {
        document?.tree.nodes(at: epd).first
    }

    func lineText(_ epd: EPD) -> String {
        guard let document, let id = node(for: epd) else { return "" }
        let text = document.tree.lineText(to: id)
        return text.isEmpty ? "Starting position" : text
    }

    var branches: [NodeID] { document?.openingBranches() ?? [] }

    /// True retention for each opening branch, all time.
    func retentionByBranch() -> [(NodeID, TrueRetention)] {
        guard let document, let graphs else { return [] }
        return branches.compactMap { id in
            let retention = graphs.retentionTable(positions: Array(document.cardEPDs(under: id)))[.allTime] ?? TrueRetention()
            return retention.count > 0 ? (id, retention) : nil
        }
    }
}
