import Testing
@testable import OpeningCore

struct RepertoireTreeTests {
    @Test func addReusesDeletePromote() throws {
        var tree = RepertoireTree()
        let e4_ = tree.addMove("e2e4", after: RepertoireTree.rootID)
        let e4 = try #require(e4_)
        #expect(tree.addMove(san: "e4", after: RepertoireTree.rootID) == e4)
        let c5_ = tree.addMove(san: "c5", after: e4)
        let c5 = try #require(c5_)
        let e5_ = tree.addMove(san: "e5", after: e4)
        let e5 = try #require(e5_)
        #expect(tree[e4]?.children == [c5, e5])
        tree.promote(e5)
        #expect(tree[e4]?.children == [e5, c5])
        let nf3_ = tree.addMove(san: "Nf3", after: c5)
        let nf3 = try #require(nf3_)
        tree.delete(c5)
        #expect(tree[nf3] == nil)
        #expect(tree.count == 3)
        #expect(tree.epdIndex.values.flatMap { $0 }.count == 3)
    }

    @Test func newMovesGoToParentsChapter() throws {
        var tree = RepertoireTree(pgn: "[Event \"A\"]\n\n1. e4 e5 *\n\n[Event \"B\"]\n\n1. d4 d5 *")
        let d4 = try #require(tree.child(of: RepertoireTree.rootID, san: "d4"))
        let d5 = try #require(tree.child(of: d4, san: "d5"))
        tree.addMove(san: "c4", after: d5)
        let games = PGNParser.parse(tree.pgnText())
        #expect(games[0].moves.map(\.san) == ["e4"])
        #expect(games[1].moves[0].children[0].children.map(\.san) == ["c4"])
    }

    @Test func notesKeepCommands() throws {
        var tree = RepertoireTree(pgn: "1. e4 { [%cal Ge2e4] old } *")
        let e4 = try #require(tree.child(of: RepertoireTree.rootID, san: "e4"))
        #expect(tree[e4]?.note == "old")
        tree.setNote("new idea", for: e4)
        #expect(tree[e4]?.comments == ["[%cal Ge2e4] new idea"])
    }

    @Test func transpositionIndex() throws {
        var tree = RepertoireTree()
        let a_ = tree.addLine(["d2d4", "g8f6", "c2c4", "e7e6"], after: RepertoireTree.rootID)
        let a = try #require(a_)
        let b_ = tree.addLine(["c2c4", "e7e6", "d2d4", "g8f6"], after: RepertoireTree.rootID)
        let b = try #require(b_)
        #expect(tree.epdIndex[tree[a]!.epd]?.sorted() == [a, b].sorted())
    }
}

struct TreeMergeTests {
    @Test func unionOfConcurrentEdits() throws {
        let base = "1. e4 e5 2. Nf3 *"
        var local = RepertoireTree(pgn: base)
        local.add("e4 c5 Nf3")
        var remote = RepertoireTree(pgn: base)
        remote.add("e4 e6 d4")
        local.merge(tree: remote)
        #expect(local.find("e4 c5 Nf3") != nil)
        #expect(local.find("e4 e6 d4") != nil)
        #expect(local.count == 8)
    }
}
