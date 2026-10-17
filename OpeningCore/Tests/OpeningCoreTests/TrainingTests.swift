import Foundation
import Testing
@testable import OpeningCore

struct TrainingTests {
    let day: TimeInterval = 86400

    @Test func fsrsIntervalsGrowAndLapse() {
        let fsrs = FSRS()
        let t0 = Date(timeIntervalSince1970: 0)
        let first = fsrs.review(nil, grade: .good, now: t0)
        #expect(first.phase == .review)
        #expect(abs(first.due.timeIntervalSince(t0) / day - 3) < 0.01)  // S0(good) ≈ 3.17 days
        let second = fsrs.review(first, grade: .good, now: first.due)
        #expect(second.stability > first.stability * 2)
        let lapse = fsrs.review(second, grade: .again, now: second.due)
        #expect(lapse.stability < second.stability)
        #expect(lapse.lapses == 1)
        #expect(lapse.due.timeIntervalSince(second.due) == fsrs.relearnDelay)
        let easy = fsrs.review(nil, grade: .easy, now: t0)
        #expect(easy.due > first.due)
    }

    @Test func sidecarRoundTripAndMerge() throws {
        var a = Sidecar(color: .white)
        let epd1 = ChessPosition.start.epd
        let epd2 = ChessPosition.start.play(san: "e4")!.1.epd
        let fsrs = FSRS()
        a.cards[epd1] = fsrs.review(nil, grade: .good, now: Date(timeIntervalSince1970: 100))
        var b = a
        b.cards[epd1] = fsrs.review(nil, grade: .again, now: Date(timeIntervalSince1970: 200))
        b.cards[epd2] = fsrs.review(nil, grade: .good, now: Date(timeIntervalSince1970: 50))
        let merged = a.merged(with: b)
        #expect(merged.cards[epd1]?.lapses == 1)
        #expect(merged.cards.count == 2)
        let decoded = try Sidecar.decode(merged.encoded())
        #expect(decoded.cards == merged.cards)
        #expect(abs(decoded.settingsModified.timeIntervalSince(merged.settingsModified)) < 0.01)
        #expect(String(data: try merged.encoded(), encoding: .utf8)!.contains("\"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -\""))
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
        let line = try #require(trainer.nextNewLine(cards: [:]))
        #expect(line.nodes.first == RepertoireTree.rootID)
    }

    @Test func drillGrades() throws {
        let tree = whiteTree()
        let trainer = Trainer(tree: tree, color: .white)
        let lines = trainer.allLines(under: RepertoireTree.rootID)
        var session = DrillSession(trainer: trainer, line: lines[0])
        #expect(session.isUserTurn)
        #expect(session.userPlayed(uci: "d2d4") == .wrong(expected: session.expected!))
        #expect(session.userPlayed(uci: "e2e4") == .correct)
        #expect(session.playOpponent() != nil)
        // play the rest correctly
        while !session.isFinished {
            if session.isUserTurn { _ = session.userPlayed(uci: session.expected!.uci) } else { _ = session.playOpponent() }
        }
        let grades = session.grades()
        #expect(grades[ChessPosition.start.epd] == .again)
        #expect(grades.values.filter { $0 == .good }.count == 2)

        var cards: [EPD: CardState] = [:]
        DrillSession.apply(grades, to: &cards)
        #expect(cards.count == 3)
        // a not-due card answered correctly is left alone
        let before = cards
        DrillSession.apply(grades.filter { $0.value == .good }, to: &cards)
        #expect(cards == before)
    }

    @Test func alternativeMoveIsNoPenalty() throws {
        let tree = whiteTree()
        let trainer = Trainer(tree: tree, color: .white)
        let afterE5 = tree.find("e4 e5")!
        let line = trainer.line(through: afterE5)
        var session = DrillSession(trainer: trainer, line: line, startAt: afterE5)
        #expect(session.userPlayed(uci: "f1c4") == .alternative)
        #expect(session.mistakes.isEmpty)
    }
}
