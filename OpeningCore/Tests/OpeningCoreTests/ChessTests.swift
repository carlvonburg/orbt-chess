import Testing
@testable import OpeningCore

struct ChessTests {
    @Test func playsSANAndUCI() throws {
        let (e4, p1) = try #require(ChessPosition.start.play(san: "e4"))
        #expect(e4.uci == "e2e4")
        #expect(p1.sideToMove == .black)
        let (nf6, _) = try #require(p1.play(uci: "g8f6"))
        #expect(nf6.san == "Nf6")
    }

    @Test func tolerantSAN() throws {
        let p = try #require(ChessPosition(fen: "r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3"))
        #expect(p.play(san: "Bb5!?")?.0.san == "Bb5")
        #expect(p.play(san: "Bf1b5")?.0.san == "Bb5")
        #expect(p.play(san: "0-0") == nil)  // not legal yet
        let castle = try #require(ChessPosition(fen: "r1bqk1nr/pppp1ppp/2n5/2b1p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4"))
        #expect(castle.play(san: "0-0")?.0.uci == "e1g1")
        #expect(castle.play(uci: "e1h1")?.0.san == "O-O")
    }

    @Test func checkSuffix() throws {
        let p = try #require(ChessPosition(fen: "rnbqkbnr/ppppp2p/5p2/6p1/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 3"))
        #expect(p.play(san: "Qh5")?.0.san == "Qh5#")
        #expect(p.play(san: "Qh5#")?.1.isCheckmate == true)
    }

    @Test func promotion() throws {
        let p = try #require(ChessPosition(fen: "8/4P3/8/8/8/8/k7/4K3 w - - 0 1"))
        #expect(p.play(uci: "e7e8n")?.0.san == "e8=N")
        #expect(p.play(san: "e8=Q+")?.0.uci == "e7e8q")
    }

    @Test func epdDropsCountersAndIrrelevantEnPassant() throws {
        let (_, afterE4) = try #require(ChessPosition.start.play(san: "e4"))
        #expect(afterE4.fen.contains(" e3 "))
        #expect(afterE4.epd.rawValue == "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq -")
        // ep capture possible: white pawn e5, black plays d7d5
        let p = try #require(ChessPosition(fen: "rnbqkbnr/pppppppp/8/4P3/8/8/PPPP1PPP/RNBQKBNR b KQkq - 0 2"))
        let (_, afterD5) = try #require(p.play(san: "d5"))
        #expect(afterD5.epd.rawValue.hasSuffix(" w KQkq d6"))
    }

    @Test func transpositionsShareEPD() throws {
        func play(_ moves: [String]) -> EPD {
            var p = ChessPosition.start
            for m in moves { p = p.play(san: m)!.1 }
            return p.epd
        }
        #expect(play(["d4", "Nf6", "c4", "e6"]) == play(["c4", "e6", "d4", "Nf6"]))
    }
}
