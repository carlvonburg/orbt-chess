import Foundation
import Testing
@testable import OpeningCore

struct TrainingTests {
    let day: TimeInterval = 86400

    @Test func sidecarRoundTripAndMerge() throws {
        var a = Sidecar(color: .white)
        let epd1 = ChessPosition.start.epd
        let epd2 = ChessPosition.start.play(san: "e4")!.1.epd
        let scheduler = Scheduler()
        func at(_ now: Int64) -> SchedTiming { SchedTiming(daysElapsed: 0, nextDayAt: 86_400, now: now) }
        a.studyCards[epd1] = scheduler.answer(nil, epd: epd1, position: 0, rating: .good, timing: at(100)).card
        var b = a
        b.studyCards[epd1] = scheduler.answer(nil, epd: epd1, position: 0, rating: .again, timing: at(200)).card
        b.studyCards[epd2] = scheduler.answer(nil, epd: epd2, position: 1, rating: .good, timing: at(50)).card
        var stats = DeckStudyStats()
        stats.recordAnswer(fromQueue: .new, millis: 10, today: 0)
        b.studyStats = stats
        let merged = a.merged(with: b)
        #expect(merged.studyCards[epd1]?.lastReviewTime == 200)
        #expect(merged.studyCards.count == 2)
        #expect(merged.studyStats?.newStudied == 1)
        let decoded = try Sidecar.decode(merged.encoded())
        #expect(decoded.studyCards == merged.studyCards)
        #expect(abs(decoded.settingsModified.timeIntervalSince(merged.settingsModified)) < 0.01)
        #expect(String(data: try merged.encoded(), encoding: .utf8)!.contains("\"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -\""))
    }

    @Test func legacyCardsAreMigrated() throws {
        let json = """
        {"version":1,"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","color":"white",
         "database":{"masters":{}},"targetGames":500,"minGames":25,
         "settingsModified":"2026-01-01T00:00:00Z",
         "cards":{"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -":
           {"stability":12,"difficulty":4,"due":"2099-01-11T12:00:00Z","lastReview":"2099-01-01T12:00:00Z",
            "reps":3,"lapses":1,"phase":"review"}}}
        """
        let sidecar = try Sidecar.decode(Data(json.utf8))
        let card = try #require(sidecar.studyCards[ChessPosition.start.epd])
        #expect(card.ctype == .review && card.queue == .review)
        #expect(card.interval == 10)
        #expect(card.memory == MemoryState(stability: 12, difficulty: 4))
        #expect(card.reps == 3 && card.lapses == 1)
        #expect(sidecar.version == 2)
    }

    func whiteTree() -> RepertoireTree {
        var tree = RepertoireTree()
        tree.add("e4 c5 Nf3 d6 d4")
        tree.add("e4 c5 Nf3 Nc6 d4")
        tree.add("e4 e5 Nf3")
        tree.add("e4 e5 Bc4")  // alternative of yours: not trained
        return tree
    }

    @Test func cardsAndLines() throws {
        let tree = whiteTree()
        let trainer = Trainer(tree: tree, color: .white)
        // root, after c5, after c5 Nf3 d6, after Nc6, after e5
        #expect(trainer.cardNodes().count == 5)
        #expect(trainer.allLines(under: RepertoireTree.rootID).count == 3)
        let branch = tree.find("e4 c5")!
        #expect(trainer.allLines(under: branch).count == 2)
    }

    @Test func newCardOrderIsALineAtATime() {
        var tree = RepertoireTree()
        let najdorf = tree.add("e4 c5 Nf3 d6 d4")
        tree.add("e4 c5 Nf3 Nc6 d4")
        tree.add("e4 e5 Nf3")
        let trainer = Trainer(tree: tree, color: .white)
        // e5 reached more often than c5: its line comes first
        var reach: [NodeID: Double] = [:]
        reach[tree.find("e4 e5")!] = 0.5
        reach[tree.find("e4 c5")!] = 0.3
        reach[tree.find("e4 c5 Nf3 d6")!] = 0.2
        reach[tree.find("e4 c5 Nf3 Nc6")!] = 0.1
        let order = trainer.newCardOrder(reach: reach)
        func epd(_ line: String) -> EPD { tree[tree.find(line)!]!.epd }
        #expect(order == [ChessPosition.start.epd, epd("e4 e5"), epd("e4 c5"), epd("e4 c5 Nf3 d6"), epd("e4 c5 Nf3 Nc6")])
        _ = najdorf
    }

    func timing() -> SchedTiming { SchedTiming(daysElapsed: 100, nextDayAt: 1_000_000 + 16 * 3600, now: 1_000_000) }

    @Test func newLineIntroducesEveryNewMove() throws {
        var tree = RepertoireTree()
        tree.add("e4 c5 Nf3 d6 d4")
        tree.add("e4 e5 Nf3")
        let trainer = Trainer(tree: tree, color: .white)
        let limits = RemainingLimits(review: 200, new: 1, capNewToReview: true)
        var session = StudySession(trainer: trainer, mode: .completeLinesOncePerSession, cards: [:], limits: limits, timing: timing())
        #expect(session.queue.counts.new == 1)
        let next = session.nextLine(cards: [:])
        let line = try #require(next)
        // the limit allows one new card, but the line it starts is finished: e4, Nf3, d4
        #expect(line.roles.values.filter { $0 == .answer(.introduce) }.count == 3)
        #expect(tree[line.nodes.last!]?.move?.san == "d4")
    }

    @Test func reviewLineRolesByPracticeMode() throws {
        var tree = RepertoireTree()
        tree.add("e4 c5 Nf3 d6 d4")
        let trainer = Trainer(tree: tree, color: .white)
        let t = timing()
        let scheduler = Scheduler()
        func reviewCard(_ epd: EPD, due: Int64) -> Card {
            var card = scheduler.answer(nil, epd: epd, position: 0, rating: .easy, timing: t).card
            card.due = due
            return card
        }
        let e4 = ChessPosition.start.epd
        let nf3 = tree[tree.find("e4 c5")!]!.epd
        let d4 = tree[tree.find("e4 c5 Nf3 d6")!]!.epd
        // only the last move is due
        let cards = [e4: reviewCard(e4, due: 150), nf3: reviewCard(nf3, due: 150), d4: reviewCard(d4, due: 90)]
        let limits = RemainingLimits(review: 200, new: 20, capNewToReview: true)

        var individual = StudySession(trainer: trainer, mode: .individualMoves, cards: cards, limits: limits, timing: t)
        let aNext = individual.nextLine(cards: cards)
        let a = try #require(aNext)
        #expect(a.roles[0] == .auto && a.roles[2] == .auto && a.roles[4] == .answer(.queued))

        var everyTime = StudySession(trainer: trainer, mode: .completeLinesEveryTime, cards: cards, limits: limits, timing: t)
        let bNext = everyTime.nextLine(cards: cards)
        let b = try #require(bNext)
        #expect(b.roles[0] == .answer(.reviewAhead) && b.roles[4] == .answer(.queued))

        var once = StudySession(trainer: trainer, mode: .completeLinesOncePerSession, cards: cards, limits: limits, timing: t)
        once.didPlay(e4)
        let cNext = once.nextLine(cards: cards)
        let c = try #require(cNext)
        #expect(c.roles[0] == .auto && c.roles[2] == .answer(.reviewAhead))
    }

    @Test func lineRunAndAlternatives() throws {
        let tree = whiteTree()
        let trainer = Trainer(tree: tree, color: .white)
        let lines = trainer.allLines(under: RepertoireTree.rootID)
        var run = LineRun(trainer: trainer, nodes: lines[0].nodes)
        #expect(run.isOwnTurn)
        #expect(run.userPlayed(uci: "d2d4") == .wrong(expected: run.expected!))
        #expect(run.userPlayed(uci: "e2e4") == .correct)
        #expect(run.advance() != nil)

        let afterE5 = tree.find("e4 e5")!
        var alt = LineRun(trainer: trainer, nodes: tree.path(to: afterE5) + [tree[afterE5]!.children[0]])
        while alt.currentNode != afterE5 { alt.advance() }
        #expect(alt.userPlayed(uci: "f1c4") == .alternative)
    }
}
