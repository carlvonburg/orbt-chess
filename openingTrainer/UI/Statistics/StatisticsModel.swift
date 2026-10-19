import Foundation
import Observation
import OpeningCore

/// Loads cards and review logs for the Statistics tab: all repertoires (Anki's whole
/// collection) or one repertoire.
@Observable
final class StatisticsModel {
    enum Scope: Hashable {
        case all
        case repertoire(String)
    }

    var scope = Scope.all
    var range = GraphsContext.Range.month

    private(set) var graphs: GraphsContext?
    private(set) var cards: [EPD: Card] = [:]
    /// The open repertoire, for reach, opening branches and move names.
    private(set) var document: RepertoireDocument?
    private(set) var isLoading = false

    func load(_ app: AppModel) async {
        isLoading = true
        defer { isLoading = false }
        let timing = SchedTiming()
        switch scope {
        case .all:
            document = nil
            var allCards: [Card] = []
            var newCount = 0
            var suspendedNew = 0
            var revlog: [RevlogEntry] = []
            for entry in app.library.entries where !entry.needsSetup {
                if let doc = app.documents[entry.id] {
                    let cards = doc.sidecar.studyCards
                    allCards += cards.values
                    newCount += doc.learningProgress().notStudied
                    suspendedNew += doc.trainer.suspendedCardEPDs().filter { cards[$0] == nil }.count
                    revlog += doc.reviewLog()
                } else if let sidecar = entry.sidecar {
                    allCards += sidecar.studyCards.values
                    let progress = sidecar.estimatedProgress
                    newCount += progress.notStudied
                    let storedSuspended = sidecar.studyCards.values.filter { $0.queue == .suspended }.count
                    suspendedNew += max(0, progress.suspended - storedSuspended)
                    revlog += await StudyLog.read(RepertoireLibrary.revlogURL(for: entry.pgnURL))
                }
            }
            cards = [:]
            graphs = GraphsContext(cards: allCards, newCount: newCount, suspendedNewCount: suspendedNew, revlog: revlog, timing: timing)
        case .repertoire(let id):
            guard let entry = app.library.entry(id: id), let doc = await app.open(entry) else {
                graphs = nil
                return
            }
            document = doc
            let root = RepertoireTree.rootID
            let epds = doc.trainer.cardEPDs(under: root)
            let suspended = doc.trainer.suspendedCardEPDs(under: root)
            let studied = doc.sidecar.studyCards.filter { epds.contains($0.key) }
            let studiedSuspended = doc.sidecar.studyCards.filter { suspended.contains($0.key) }
            cards = studied
            let revlog = doc.reviewLog().filter { epds.contains($0.cid) || suspended.contains($0.cid) }
            graphs = GraphsContext(cards: Array(studied.values) + Array(studiedSuspended.values),
                                   newCount: epds.count - studied.count,
                                   suspendedNewCount: suspended.count - studiedSuspended.count,
                                   revlog: revlog, timing: timing)
        }
    }

    // MARK: Chess statistics

    /// Reach of each card position in the repertoire.
    private var reachByEPD: [EPD: Double] {
        guard let document else { return [:] }
        var result: [EPD: Double] = [:]
        for id in document.trainer.cardNodes() {
            guard let node = document.tree[id], let reach = document.coverage[id]?.reach else { continue }
            result[node.epd] = max(result[node.epd] ?? 0, reach)
        }
        return result
    }

    var expectedRecall: Double? {
        guard document != nil else { return nil }
        return ChessStats.expectedRecall(cards: cards, reach: reachByEPD, now: .now)
    }

    var weakestMoves: [ChessStats.WeakMove] {
        ChessStats.weakestMoves(cards: cards, now: .now)
    }

    /// The first node with a position, for naming and opening it.
    func node(for epd: EPD) -> NodeID? {
        document?.tree.epdIndex[epd]?.first
    }

    func lineText(_ epd: EPD) -> String {
        guard let document, let id = node(for: epd) else { return "" }
        let text = document.tree.lineText(to: id)
        return text.isEmpty ? "Starting position" : text
    }

    var branches: [NodeID] { document?.trainer.openingBranches() ?? [] }

    /// True retention for each opening branch, all time.
    func retentionByBranch() -> [(NodeID, GraphsContext.TrueRetention)] {
        guard let document, let graphs else { return [] }
        return branches.compactMap { id in
            let epds = document.trainer.cardEPDs(under: id)
            let retention = graphs.trueRetention(cardsMatching: { epds.contains($0) })[.allTime] ?? .init()
            return retention.count > 0 ? (id, retention) : nil
        }
    }
}
