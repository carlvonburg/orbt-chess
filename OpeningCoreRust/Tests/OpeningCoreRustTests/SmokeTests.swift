import Testing
import OpeningCoreRust

@Test func callsIntoRust() throws {
    #expect(!coreVersion().isEmpty)
    #expect(try legalMoveCount(fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1") == 20)
    #expect(throws: CoreError.self) { try legalMoveCount(fen: "nonsense") }
}
