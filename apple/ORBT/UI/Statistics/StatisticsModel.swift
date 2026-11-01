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
    var range = GraphRange.month

    private(set) var graphs: Graphs?
    private(set) var cards: [EPD: Card] = [:]
    /// The open repertoire, for reach, opening branches and move names.
    private(set) var document: RepertoireDocument?
    /// True retention, all time, of each repertoire (all repertoires only).
    private(set) var repertoireRetention: [(String, TrueRetention)] = []
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
            var retention: [(String, TrueRetention)] = []
            for entry in app.library.entries where !entry.needsSetup {
                let revlogURL = RepertoireLibrary.revlogURL(for: entry.pgnURL)
                let part: GraphParts
                if let doc = app.documents[entry.id] {
                    part = await doc.graphParts(wholeCollection: true)
                } else if let sidecar = entry.sidecar {
                    part = sidecar.graphParts(revlog: await StudyLog.readData(revlogURL))
                } else {
                    continue
                }
                parts.append(part)
                let r = Graphs.fromParts(parts: [part], timing: timing, localOffsetSecs: offset).retentionTable()[.allTime] ?? TrueRetention()
                if r.count > 0 { retention.append((entry.name, r)) }
            }
            cards = [:]
            repertoireRetention = retention
            graphs = Graphs.fromParts(parts: parts, timing: timing, localOffsetSecs: offset)
        case .repertoire(let id):
            guard let entry = app.library.entry(id: id), let doc = await app.open(entry) else {
                graphs = nil
                return
            }
            document = doc
            repertoireRetention = []
            cards = doc.core.repertoireCards()
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

    /// A reply where the line branches: its moves by Anki's groups and their true retention,
    /// all time.
    struct BranchRow: Identifiable {
        let id: NodeID
        let text: String
        let progress: Progress
        let retention: TrueRetention
        /// The line branches again below it.
        let branches: Bool
    }

    /// Where the line from `node` branches (the core follows a single line until the opponent
    /// has more than one reply), and each reply's progress.
    func branches(from node: NodeID) -> (point: NodeID, rows: [BranchRow]) {
        guard let document, let graphs else { return (node, []) }
        let point = document.branchPoint(from: node)
        let rows = point.branches.map { branch in
            BranchRow(id: branch.id, text: branch.text,
                      progress: document.learningProgress(under: branch.id),
                      retention: graphs.retentionTable(positions: Array(document.cardEPDs(under: branch.id)))[.allTime] ?? TrueRetention(),
                      branches: !document.branchPoint(from: branch.id).branches.isEmpty)
        }
        return (point.point, rows)
    }
}
