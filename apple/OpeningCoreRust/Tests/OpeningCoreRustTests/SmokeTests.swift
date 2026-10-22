import Foundation
import Testing
import OpeningCoreRust

/// A stats store that keeps nothing: the tests never fetch.
final class NoStats: StatsStore {
    func load(databaseKey: String) -> [StoredStats] { [] }
    func save(databaseKey: String, epd: Epd, json: Data) {}
}

@Test func callsIntoRust() {
    #expect(!coreVersion().isEmpty)
    #expect(Position.start().legalMoves().count == 20)
    #expect(positionFromFen(fen: "nonsense") == nil)
}

@Test func opensARepertoire() throws {
    let sidecar = newSidecar(id: "smoke", color: .white, database: .masters, targetGames: 100,
                             now: .of(.now))
    let explorer = Explorer(store: NoStats(), bannedUntil: nil, baseIntervalMs: nil)
    let opened = try openRepertoire(pgnText: "1. e4 e5 2. Nf3 Nc6 (2... Nf6) *", sidecar: sidecar,
                                    defaults: defaultStudyDefaults(), explorer: explorer)
    let doc = opened.document
    let e4 = try #require(doc.childBySan(id: doc.root().id, san: "e4"))
    let e5 = try #require(doc.childBySan(id: e4, san: "e5"))
    let nf3 = try #require(doc.childBySan(id: e5, san: "Nf3"))
    #expect(doc.childBySan(id: nf3, san: "Nc6") != nil)
    #expect(doc.childBySan(id: nf3, san: "Nf6") != nil)
}

/// Counts the engine's change notices.
final class EngineNotices: EngineListener, @unchecked Sendable {
    func changed() {}
}

@Test func stockfishAnalysesThroughTheBindings() async throws {
    let engine = Engine(kind: .stockfish)
    engine.setListener(listener: EngineNotices())
    try engine.start(netPath: nil)
    var settings = defaultEngineSettings()
    settings.cloud = false
    settings.movetimeMs = 500
    settings.threads = 1
    _ = engine.analyse(startFen: Position.start().fen(), moves: ["e2e4"], settings: settings,
                       nowMs: UInt64(Date.now.timeIntervalSince1970 * 1000))
    for _ in 0..<40 where engine.lines().lines.count < 3 || engine.lines().searching {
        try await Task.sleep(for: .milliseconds(100))
    }
    let shown = engine.lines()
    #expect(shown.lines.count == 3)
    #expect(shown.source == .local)
    #expect(engine.name() == "Stockfish 19 · 1 MB net")
    engine.quit()
}

@Test func analysisBoardVariations() {
    let analysis = AnalysisSession(startFen: nil, moves: ["e2e4", "e7e5"], orientation: .white)
    #expect(analysis.back())
    #expect(analysis.playUci(uci: "c7c5"))
    #expect(analysis.lines().count == 2)
    #expect(analysis.pgn() == "1. e4 e5 (1... c5) *")
}
