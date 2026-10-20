import Foundation
import Testing
@testable import OpeningCore

/// Timing check on a real large PGN. Set OT_LARGE_PGN to run it.
struct LargeRepertoireTests {
    @Test func fullRecomputeIsCheap() throws {
        guard let path = ProcessInfo.processInfo.environment["OT_LARGE_PGN"],
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        var clock = ContinuousClock.now
        let tree = RepertoireTree(pgn: text)
        let parse = clock.duration(to: .now)
        // Stats for every position: worst case for the engine.
        var stats: [EPD: ExplorerStats] = [:]
        for node in tree.nodes.values {
            let moves = node.children.compactMap { tree[$0]?.move }.enumerated().map { i, m in
                ExplorerMove(uci: m.uci, san: m.san, white: 1000 / (i + 1), draws: 0, black: 0)
            }
            let total = moves.reduce(0) { $0 + $1.games } + 200
            stats[node.epd] = ExplorerStats(white: total, draws: 0, black: 0, moves: moves)
        }
        var engine = CoverageEngine(settings: CoverageSettings(color: .white, targetGames: 500))
        clock = .now
        engine.recomputeAll(tree: tree, stats: { stats[$0] })
        let full = clock.duration(to: .now)
        var t = tree
        let leaf = tree.leaves(under: RepertoireTree.rootID)[0]
        let parent = tree[leaf]!.parent!
        clock = .now
        let added = t.addMove(tree[parent]!.position.legalMoves().first { tree.child(of: parent, uci: $0.uci) == nil }!.uci, after: parent)!
        engine.update(changedAt: parent, epds: [t[added]!.epd], tree: t, stats: { stats[$0] })
        let incremental = clock.duration(to: .now)
        print("LARGE nodes=\(tree.count) opponentNodes=\(tree.nodes.values.filter { $0.sideToMove == .black }.count) parse=\(parse) full=\(full) incremental=\(incremental) warnings=\(tree.loadWarnings.count)")
    }
}
