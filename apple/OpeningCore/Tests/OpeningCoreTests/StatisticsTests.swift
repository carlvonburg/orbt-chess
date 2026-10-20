import Foundation
import Testing
@testable import OpeningCore

struct StatisticsTests {
    let timing = SchedTiming(daysElapsed: 100, nextDayAt: 1_000_000 + 16 * 3600, now: 1_000_000)
    let e4 = ChessPosition.start.epd

    func entry(_ secsAgo: Int64, ease: Int, lastIvl: Int, type: RevlogReviewKind) -> RevlogEntry {
        RevlogEntry(id: (timing.now - secsAgo) * 1000, cid: e4, ease: ease, ivl: 1, lastIvl: lastIvl,
                    factor: 500, time: 4000, type: type)
    }

    @Test func todayAndRetention() {
        let revlog = [
            entry(60, ease: 3, lastIvl: 0, type: .learning),
            entry(120, ease: 1, lastIvl: 30, type: .review),
            entry(180, ease: 3, lastIvl: 5, type: .review),
            entry(2 * 86_400, ease: 3, lastIvl: 30, type: .review),
        ]
        let graphs = GraphsContext(cards: [], newCount: 0, revlog: revlog, timing: timing, localOffsetSecs: 0)
        let today = graphs.today()
        #expect(today.answerCount == 3)
        #expect(today.correctCount == 2)
        #expect(today.matureCount == 1 && today.matureCorrect == 0)
        #expect(today.learnCount == 1 && today.reviewCount == 2)
        let retention = graphs.trueRetention()
        // learning answers (interval below a day) are not counted
        #expect(retention[.today]?.count == 2)
        #expect(retention[.today]?.youngPassed == 1 && retention[.today]?.matureFailed == 1)
        #expect(retention[.week]?.maturePassed == 1)
        #expect(graphs.reviews().count[0]?.total == 3)
        #expect(graphs.reviews().count[-2]?.mature == 1)
    }

    @Test func cardCountsAndExpectedRecall() {
        var review = Card(id: 1, position: 0, added: 0)
        review.ctype = .review
        review.queue = .review
        review.interval = 30
        review.memory = MemoryState(stability: 30, difficulty: 5)
        review.lastReviewTime = timing.now
        let graphs = GraphsContext(cards: [review], newCount: 2, revlog: [], timing: timing)
        #expect(graphs.cardCounts() == GraphsContext.CardCounts(new: 2, mature: 1))
        let other = ChessPosition.start.play(san: "d4")!.1.epd
        let recall = ChessStats.expectedRecall(cards: [e4: review], reach: [e4: 1, other: 1],
                                               now: Date(timeIntervalSince1970: TimeInterval(timing.now)))
        // the studied move is known (R = 1), the other is new (R = 0)
        #expect(recall == 0.5)
    }
}

struct StreakTests {
    @Test func currentAndLongest() {
        #expect(Streak(days: [0, -1, -2, -5, -6, -7, -8]) == Streak(current: 3, longest: 4, studiedToday: true))
        // Not studied yet today: yesterday's streak still counts.
        #expect(Streak(days: [-1, -2]) == Streak(current: 2, longest: 2, studiedToday: false))
        #expect(Streak(days: [-2, -3]).current == 0)
        #expect(Streak(days: []) == Streak())
    }
}
