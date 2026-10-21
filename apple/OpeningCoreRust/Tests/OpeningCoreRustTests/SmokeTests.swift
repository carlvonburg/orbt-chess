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
