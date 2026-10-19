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

    @Test func summaryRoundTrip() throws {
        var sidecar = Sidecar(color: .black)
        sidecar.summary = Sidecar.Summary(completion: 0.5, gapCount: 2, cardCount: 10, matureCount: 1, savedMoveCount: 25, dueCount: 4, configKey: "k", computedAt: .now)
        let decoded = try Sidecar.decode(sidecar.encoded())
        #expect(decoded.summary?.savedMoveCount == 25)
        // Summaries written before the counts were added still decode.
        var old = try JSONSerialization.jsonObject(with: sidecar.encoded()) as! [String: Any]
        var summary = old["summary"] as! [String: Any]
        summary["savedMoveCount"] = nil
        old["summary"] = summary
        let legacy = try Sidecar.decode(JSONSerialization.data(withJSONObject: old))
        #expect(legacy.summary?.savedMoveCount == nil && legacy.summary?.cardCount == 10)
    }

    @Test func progressGroups() {
        let tree = whiteTree()
        let trainer = Trainer(tree: tree, color: .white)
        let epds = trainer.cardNodes().compactMap { tree[$0]?.epd }
        var cards: [EPD: Card] = [:]
        var learning = Card(id: 1, position: 0, added: 0)
        learning.ctype = .learn
        cards[epds[0]] = learning
        var young = Card(id: 2, position: 1, added: 0)
        young.ctype = .review
        young.interval = 5
        cards[epds[1]] = young
        var mature = Card(id: 3, position: 2, added: 0)
        mature.ctype = .review
        mature.interval = 30
        cards[epds[2]] = mature
        let p = trainer.progress(cards: cards)
        #expect(p == Trainer.Progress(cards: 5, learning: 1, young: 1, mature: 1))
        #expect(p.notStudied == 2)
    }

    @Test func nextDueAfterToday() {
        let timing = SchedTiming(daysElapsed: 10, nextDayAt: 100_000, now: 50_000)
        var sidecar = Sidecar(color: .white)
        var review = Card(id: 1, position: 0, added: 0)
        review.ctype = .review
        review.queue = .review
        review.due = 12
        sidecar.studyCards[ChessPosition.start.epd] = review
        #expect(sidecar.nextDue(timing: timing) == Date(timeIntervalSince1970: 186_400))
        var learning = Card(id: 2, position: 1, added: 0)
        learning.ctype = .learn
        learning.queue = .learn
        learning.due = 60_000
        sidecar.studyCards[ChessPosition.start.play(san: "e4")!.1.epd] = learning
        #expect(sidecar.nextDue(timing: timing) == Date(timeIntervalSince1970: 60_000))
        #expect(sidecar.estimatedProgress.learning == 1 && sidecar.estimatedProgress.young == 1)
        #expect(sidecar.laterLearningDues(timing: timing) == [Date(timeIntervalSince1970: 60_000)])
        #expect(sidecar.dueTomorrow(timing: timing) == 0)
        review.due = 11
        sidecar.studyCards[ChessPosition.start.epd] = review
        #expect(sidecar.dueTomorrow(timing: timing) == 1)
    }

    @Test func alternativesAreSuspendedAndKeepProgress() {
        var tree = whiteTree()
        // whiteTree: after 1.e4 e5 the main move is Nf3, Bc4 is an alternative.
        tree.add("e4 e5 Bc4 Nf6 d3")
        let trainer = Trainer(tree: tree, color: .white)
        let afterNf6 = tree.find("e4 e5 Bc4 Nf6")!
        let epd = tree[afterNf6]!.epd
        #expect(trainer.suspendedCardEPDs() == [epd])
        #expect(trainer.progress(cards: [:]).suspended == 1)

        // A studied card on the main line, then the line becomes an alternative and back.
        var sidecar = Sidecar(color: .white)
        var review = Card(id: 1, position: 0, added: 0)
        review.ctype = .review
        review.queue = .review
        review.interval = 30
        review.due = 100
        sidecar.studyCards[epd] = review
        let suspended = sidecar.syncSuspension(active: trainer.cardEPDs())
        #expect(suspended && sidecar.studyCards[epd]?.queue == .suspended)
        #expect(sidecar.estimatedProgress.mature == 0)
        let restored = sidecar.syncSuspension(active: [epd])
        #expect(restored && sidecar.studyCards[epd] == review)
        let unchanged = sidecar.syncSuspension(active: [epd])
        #expect(!unchanged)
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

    @Test func nextLineTakesBackWhenShorter() throws {
        var tree = RepertoireTree()
        tree.add("e4 c5 Nf3 d6 d4 cxd4 Nxd4 Nf6 Nc3 a6 Be3")
        tree.add("e4 c5 Nf3 d6 d4 cxd4 Nxd4 Nf6 Nc3 g6 Be3")
        tree.add("e4 e5 Nf3")
        let previous = tree.path(to: tree.find("e4 c5 Nf3 d6 d4 cxd4 Nxd4 Nf6 Nc3 a6 Be3")!)
        let dragon = tree.path(to: tree.find("e4 c5 Nf3 d6 d4 cxd4 Nxd4 Nf6 Nc3 g6 Be3")!)
        let e5 = tree.path(to: tree.find("e4 e5 Nf3")!)
        func line(_ nodes: [NodeID], asked: Int) -> StudyLine {
            var roles: [Int: MoveRole] = [:]
            for i in stride(from: 0, to: nodes.count - 1, by: 2) { roles[i] = i == asked ? .answer(.queued) : .auto }
            return StudyLine(nodes: nodes, roles: roles, target: tree[nodes[asked]]!.epd)
        }
        // parts after 9 moves, 2 to take back: take back to move 9
        #expect(line(dragon, asked: 10).resumeIndex(from: previous, shown: 11) == 9)
        // parts after 1 move: replay from move 1
        #expect(line(e5, asked: 2).resumeIndex(from: previous, shown: 11) == nil)
        // a move you play before the split must be replayed: to move 4 is 7 back, 4 forward
        #expect(line(dragon, asked: 4).resumeIndex(from: previous, shown: 11) == nil)
        #expect(line(dragon, asked: 8).resumeIndex(from: previous, shown: 11) == 8)
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
