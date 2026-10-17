import Testing
@testable import OpeningCore

/// PGNs that repeat a transposed position's subtree under every move order (Chessbook
/// exports do) are stored with each position's lines once.
struct TranspositionTests {
    // After 1. d4 d5 2. c4 c6 3. Nf3 Nf6 and 1. d4 d5 2. Nf3 Nf6 3. c4 c6 the same position
    // is reached; the second subtree adds 4. e3 Bf5 to the shared lines.
    let pgn = """
    1. d4 d5 2. c4 (2. Nf3 Nf6 3. c4 c6 4. Nc3 (4. e3 Bf5) e6) c6 3. Nf3 Nf6 4. Nc3 e6 *
    """

    @Test func duplicateSubtreeIsStoredOnce() throws {
        let tree = RepertoireTree(pgn: pgn)
        let main = try #require(tree.find("d4 d5 c4 c6 Nf3 Nf6"))
        let other = try #require(tree.find("d4 d5 Nf3 Nf6 c4 c6"))
        #expect(tree[other]!.children.isEmpty)
        #expect(tree.transpositionTarget(of: other) == main)
        // Lines from both copies end up at the main node.
        #expect(tree.find("d4 d5 c4 c6 Nf3 Nf6 Nc3 e6") != nil)
        #expect(tree.find("d4 d5 c4 c6 Nf3 Nf6 e3 Bf5") != nil)
        #expect(tree.loadWarnings.isEmpty)
    }

    @Test func writingKeepsEveryMoveOrderAndLine() throws {
        let tree = RepertoireTree(pgn: pgn)
        let reread = RepertoireTree(pgn: tree.pgnText())
        #expect(reread.count == tree.count)
        #expect(reread.find("d4 d5 Nf3 Nf6 c4 c6") != nil)
        #expect(reread.find("d4 d5 c4 c6 Nf3 Nf6 e3 Bf5") != nil)
    }

    @Test func linesStayInTheirChapter() throws {
        let text = "[Event \"A\"]\n\n1. d4 d5 2. c4 c6 3. Nf3 Nf6 4. Nc3 *\n\n[Event \"B\"]\n\n1. d4 d5 2. Nf3 Nf6 3. c4 c6 4. e3 *"
        let tree = RepertoireTree(pgn: text)
        let other = try #require(tree.find("d4 d5 Nf3 Nf6 c4 c6"))
        // Chapter B's node keeps its own move, so writing chapter B loses nothing.
        #expect(tree[other]!.children.count == 1)
        let games = PGNParser.parse(tree.pgnText())
        #expect(games.count == 2)
        #expect(RepertoireTree(games: [games[1]]).find("d4 d5 Nf3 Nf6 c4 c6 e3") != nil)
    }

    @Test func opponentToMoveLeafCountsAsCovered() throws {
        // Black repertoire: after 1. d4 d5 2. c4 c6 3. Nf3 Nf6 it is White's move.
        let tree = RepertoireTree(pgn: pgn)
        let other = try #require(tree.find("d4 d5 Nf3 Nf6 c4 c6"))
        let main = try #require(tree.find("d4 d5 c4 c6 Nf3 Nf6"))
        var stats = FixtureStats()
        stats.set("", [("d4", 100)])
        stats.set("d4 d5", [("c4", 50), ("Nf3", 50)])
        stats.set("d4 d5 Nf3 Nf6", [("c4", 100)])
        var engine = CoverageEngine(settings: CoverageSettings(color: .black, targetGames: 10, minGames: 1))
        engine.recomputeAll(tree: tree, stats: stats.lookup)
        #expect(engine[other]!.status == .transposition(main))
        #expect(engine[other]!.pendingCount == 0)
    }

    @Test func trainingContinuesThroughTransposition() throws {
        let tree = RepertoireTree(pgn: pgn)
        let trainer = Trainer(tree: tree, color: .black)
        let nf3 = try #require(tree.find("d4 d5 Nf3"))
        let lines = trainer.allLines(under: nf3)
        let moves = lines.map { line in line.nodes.compactMap { tree[$0]?.move?.san } }
        #expect(moves.contains(["d4", "d5", "Nf3", "Nf6", "c4", "c6", "Nc3", "e6"]))
        #expect(moves.contains(["d4", "d5", "Nf3", "Nf6", "c4", "c6", "e3", "Bf5"]))
        // The transposed continuation's cards count toward the branch.
        let afterNc3 = try #require(tree.find("d4 d5 c4 c6 Nf3 Nf6 e3"))
        #expect(trainer.cardNodes(under: nf3).contains(afterNc3))
        // A drill along the transposed line expects the stored move.
        let line = try #require(lines.first { $0.nodes.contains(afterNc3) })
        var drill = DrillSession(trainer: trainer, line: line)
        while !drill.isFinished {
            if drill.isUserTurn { #expect(drill.userPlayed(uci: drill.expected!.uci) == .correct) } else { _ = drill.playOpponent() }
        }
    }

    @Test func eachTransposedContinuationIsDrilledOnce() throws {
        // Three move orders into the same position: the continuation is drilled once.
        let text = "1. d4 d5 2. c4 (2. Nf3 Nf6 3. c4 c6 4. Nc3) (2. Bf4 Nf6 3. Nf3 c6 4. c4) c6 3. Nf3 Nf6 4. Nc3 *"
        let tree = RepertoireTree(pgn: text)
        let lines = Trainer(tree: tree, color: .black).allLines(under: RepertoireTree.rootID)
        let throughNc3 = lines.filter { line in line.nodes.contains { tree[$0]?.move?.san == "Nc3" } }
        #expect(throughNc3.count == 1)
        #expect(lines.count == 3)
    }
}
