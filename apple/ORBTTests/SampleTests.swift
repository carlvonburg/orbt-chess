import Foundation
import OpeningCoreRust
import Testing
@testable import ORBT

/// The bundled sample repertoire (`RepertoireLibrary.addSample`): written by hand, so a typo
/// would only show as missing moves.
@Suite struct SampleTests {
    @Test func sampleLoadsWithEveryMove() throws {
        let url = try #require(Bundle.main.url(forResource: RepertoireLibrary.sampleName, withExtension: "pgn"))
        let text = try String(contentsOf: url, encoding: .utf8)
        let sidecar = newSidecar(id: "sample", color: .white, database: .lichess(ratings: [1600], speeds: [.blitz]),
                                 targetGames: 20, now: .of(.now))
        let opened = try openRepertoire(pgnText: text, sidecar: sidecar,
                                        defaults: StudyDefaults(newPerDay: 20, reviewsPerDay: 200, practiceMode: .default, newMoveOrder: .default),
                                        explorer: Explorer(store: EmptyStore(), bannedUntil: nil, baseIntervalMs: nil))
        #expect(opened.document.loadWarnings().isEmpty)
        #expect(opened.document.savedMoveCount() == 57)
    }
}

/// No stats: the test only reads the moves.
private final class EmptyStore: StatsStore {
    func load(databaseKey: String) -> [StoredStats] { [] }
    func save(databaseKey: String, epd: Epd, json: Data) {}
}
