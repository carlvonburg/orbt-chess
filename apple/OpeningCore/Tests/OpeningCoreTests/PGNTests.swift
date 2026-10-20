import Testing
@testable import OpeningCore

struct PGNTests {
    static let sample = """
    [Event "Sicilian: Chapter 1"]
    [Site "https://lichess.org/study/abc"]
    [Result "*"]

    { Intro comment } 1. e4 c5 2. Nf3 { [%cal Gd2d4] Main move } (2. c3!? { Alapin } d5 3. exd5 Qxd5 4. d4) (2. d4 cxd4 3. c3) 2... d6 $1 3. d4 cxd4 4. Nxd4 Nf6 5. Nc3 a6 *

    [Event "Sicilian: Chapter 2"]
    [Result "*"]

    1. e4 c5 2. Nf3 Nc6 ; line comment
    3. Bb5 *
    """

    @Test func parsesGamesVariationsCommentsAndNAGs() throws {
        let games = PGNParser.parse(Self.sample)
        #expect(games.count == 2)
        let g = games[0]
        #expect(g.tag("Event") == "Sicilian: Chapter 1")
        #expect(g.comments == ["Intro comment"])
        let nf3 = g.moves[0].children[0].children[0]
        #expect(nf3.san == "Nf3")
        #expect(nf3.comments == ["[%cal Gd2d4] Main move"])
        let alternatives = g.moves[0].children[0].children
        #expect(alternatives.map(\.san) == ["Nf3", "c3", "d4"])
        #expect(alternatives[1].nags == [5])
        #expect(alternatives[1].comments == ["Alapin"])
        #expect(nf3.children[0].san == "d6")
        #expect(nf3.children[0].nags == [1])
        #expect(games[1].moves[0].children[0].children[0].children[0].comments == ["line comment"])
    }

    @Test func roundTripsThroughTree() throws {
        let tree = RepertoireTree(pgn: Self.sample)
        #expect(tree.loadWarnings.isEmpty)
        #expect(tree.chapters.count == 2)
        let text = tree.pgnText()
        let reparsed = RepertoireTree(pgn: text)
        #expect(reparsed.count == tree.count)
        #expect(reparsed.pgnText() == text)
        // chapter 2 only contains its own line
        let games = PGNParser.parse(text)
        #expect(games[1].moves[0].children[0].children[0].children.map(\.san) == ["Nc6"])
        #expect(text.contains("2. c3!? { Alapin }"))
        #expect(text.contains("[%cal Gd2d4] Main move"))
    }

    @Test func writerNumbersBlackMovesAfterVariations() {
        let text = PGNWriter.write(PGNParser.parse("1. e4 e5 (1... c5) 2. Nf3 *")[0])
        #expect(text == "1. e4 e5 (1... c5) 2. Nf3 *")
        let afterComment = PGNWriter.write(PGNParser.parse("1. e4 {best} e5 *")[0])
        #expect(afterComment == "1. e4 { best } 1... e5 *")
    }

    @Test func illegalMovesAreReportedNotFatal() {
        let tree = RepertoireTree(pgn: "1. e4 e5 2. Ke3 Nc6 (2... Nf6 3. Nc3) *")
        #expect(tree.loadWarnings.count == 1)
        #expect(tree.count == 3)  // root, e4, e5
    }

    @Test func nonStandardStartIsKeptVerbatim() {
        let pgn = """
        [Event "Endgame"]
        [SetUp "1"]
        [FEN "8/8/8/4k3/8/8/4P3/4K3 w - - 0 1"]

        1. Kd2 *
        """
        let tree = RepertoireTree(pgn: pgn)
        #expect(tree.count == 1)
        #expect(tree.pgnText().contains("1. Kd2"))
    }
}
