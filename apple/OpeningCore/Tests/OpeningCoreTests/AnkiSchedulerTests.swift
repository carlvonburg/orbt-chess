// Test vectors from Anki (rslib/src/scheduler/states/*, queue/builder/intersperser.rs) and
// fsrs-rs (src/model.rs), ported with the scheduler.
// Copyright: Ankitects Pty Ltd and contributors; Open Spaced Repetition.
// License: GNU AGPL, version 3 or later (Anki parts); BSD 3-Clause (fsrs-rs parts).

import Foundation
import Testing
@testable import OpeningCore

struct AnkiSchedulerTests {
    /// Anki's `StateContext::defaults_for_testing()`: FSRS off, no fuzz.
    func testingContext() -> StateContext {
        StateContext(fuzzFactor: nil, steps: LearningSteps([1, 10]), relearnSteps: LearningSteps([10]))
    }

    // MARK: steps.rs

    @Test func delaySecs() {
        func check(_ steps: [Double], _ remaining: Int, _ again: Int?, _ hard: Int?, _ good: Int?) {
            let s = LearningSteps(steps)
            #expect(s.againDelaySecsLearn() == again)
            #expect(s.hardDelaySecs(remaining) == hard)
            #expect(s.goodDelaySecs(remaining) == good)
        }
        let day = 86_400
        check([10], 1, 600, 900, nil)
        check([Double(3 * day / 60)], 1, 3 * day, 4 * day, nil)
        check([1, 10], 2, 60, 330, 600)
        check([1, 10], 1, 60, 600, nil)
        check([1, 10, 100], 3, 60, 330, 600)
        check([1, 10, 100], 2, 60, 600, 6000)
        check([1, 10, 100], 1, 60, 6000, nil)
    }

    // MARK: learning.rs

    @Test func learningAgainResetsToFirstStep() {
        let ctx = testingContext()
        for remaining in [1, 2] {
            let state = LearnState(remainingSteps: remaining, scheduledSecs: 60, elapsedSecs: 0)
            #expect(state.nextStates(ctx).again == .learning(LearnState(remainingSteps: 2, scheduledSecs: 60, elapsedSecs: 0)))
        }
    }

    @Test func learningHardStaysOnStep() {
        let ctx = testingContext()
        let first = LearnState(remainingSteps: 2, scheduledSecs: 60, elapsedSecs: 0).nextStates(ctx).hard
        #expect(first == .learning(LearnState(remainingSteps: 2, scheduledSecs: 330, elapsedSecs: 0)))
        let last = LearnState(remainingSteps: 1, scheduledSecs: 60, elapsedSecs: 0).nextStates(ctx).hard
        #expect(last == .learning(LearnState(remainingSteps: 1, scheduledSecs: 600, elapsedSecs: 0)))
    }

    @Test func learningGoodAdvancesThenGraduates() {
        let ctx = testingContext()
        let first = LearnState(remainingSteps: 2, scheduledSecs: 60, elapsedSecs: 0).nextStates(ctx).good
        #expect(first == .learning(LearnState(remainingSteps: 1, scheduledSecs: 600, elapsedSecs: 0)))
        let last = LearnState(remainingSteps: 1, scheduledSecs: 60, elapsedSecs: 0).nextStates(ctx).good
        guard case .review(let review) = last else { Issue.record("expected review"); return }
        #expect(review.scheduledDays == 1)
    }

    @Test func learningEasyGraduatesLongerThanGood() {
        let ctx = testingContext()
        let states = LearnState(remainingSteps: 1, scheduledSecs: 60, elapsedSecs: 0).nextStates(ctx)
        guard case .review(let easy) = states.easy, case .review(let good) = states.good else {
            Issue.record("expected review states"); return
        }
        #expect(easy.scheduledDays > good.scheduledDays)
    }

    // MARK: fuzz.rs

    @Test func withReviewFuzzVectors() {
        #expect(withReviewFuzz(nil, 1.5, minimum: 1, maximum: 100) == 2)
        #expect(withReviewFuzz(nil, 0.1, minimum: 1, maximum: 100) == 1)
        #expect(withReviewFuzz(nil, 101, minimum: 1, maximum: 100) == 100)
        func check(_ interval: Double, _ minimum: Int, _ maximum: Int, _ lower: Int, _ middle: Int, _ upper: Int,
                   sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(withReviewFuzz(0, interval, minimum: minimum, maximum: maximum) == lower, sourceLocation: sourceLocation)
            #expect(withReviewFuzz(0.5, interval, minimum: minimum, maximum: maximum) == middle, sourceLocation: sourceLocation)
            #expect(withReviewFuzz(0.99, interval, minimum: minimum, maximum: maximum) == upper, sourceLocation: sourceLocation)
        }
        check(1.0, 1, 1000, 1, 1, 1)
        check(2.49, 1, 1000, 2, 2, 2)
        check(2.5, 1, 1000, 2, 3, 4)
        check(7.0, 1, 1000, 5, 7, 9)
        check(17.0, 1, 1000, 14, 17, 20)
        check(37.0, 1, 1000, 33, 37, 41)
        check(2.0, 2, 1000, 2, 2, 2)
        check(2.0, 3, 1000, 3, 4, 4)
        check(2.0, 3, 3, 3, 3, 3)
        check(6.9, 3, 1000, 5, 7, 9)
        check(7.0, 3, 1000, 5, 7, 9)
        check(7.1, 3, 1000, 5, 7, 9)
        check(19.9, 3, 1000, 17, 20, 23)
        check(20.0, 3, 1000, 17, 20, 23)
        check(20.1, 3, 1000, 17, 20, 23)
        check(100.0, 101, 1000, 101, 105, 108)
        check(100.0, 1, 99, 92, 96, 99)
        check(100.0, 97, 103, 97, 100, 103)
        _ = constrainedFuzzBounds(1.0, minimum: 3, maximum: 2)  // must not trap
    }

    @Test func minimumReviewFuzzIntervalVectors() {
        #expect(minimumReviewFuzzInterval(2.7269483, previous: 4, maximum: 36500) == 4)
        #expect(minimumReviewFuzzInterval(2.7269483, previous: 5, maximum: 36500) == 0)
        #expect(minimumReviewFuzzInterval(4.591988, previous: 4, maximum: 36500) == 5)
    }

    // MARK: review.rs

    @Test func leechThreshold() {
        let threshold3 = (0...7).map { leechThresholdMet(lapses: $0, threshold: 3) }
        #expect(threshold3 == [false, false, false, true, false, true, false, true])
        let threshold8 = (7...13).map { leechThresholdMet(lapses: $0, threshold: 8) }
        #expect(threshold8 == [false, true, false, false, false, true, false])
        #expect(!leechThresholdMet(lapses: 0, threshold: 0))
        #expect((0...3).map { leechThresholdMet(lapses: $0, threshold: 1) } == [false, true, true, true])
    }

    @Test func extremeMultiplierFuzz() {
        var ctx = testingContext()
        let state = ReviewState(scheduledDays: 1, elapsedDays: 1, easeFactor: 1.3)
        ctx.fuzzFactor = 0
        #expect(state.passingReviewIntervals(ctx) == (2, 3, 4))
        ctx.intervalMultiplier = 0.1
        #expect(state.passingReviewIntervals(ctx) == (2, 3, 4))
        ctx.fuzzFactor = 0.99
        #expect(state.passingReviewIntervals(ctx) == (2, 4, 6))
        ctx.intervalMultiplier = 10
        ctx.maximumReviewInterval = 5
        #expect(state.passingReviewIntervals(ctx) == (5, 5, 5))
    }

    // MARK: intersperser.rs

    @Test func interspersing() {
        let a = [1, 2, 3]
        #expect(CardQueues.intersperse(a, [11, 22, 33]) == [1, 11, 2, 22, 3, 33])
        #expect(CardQueues.intersperse(a, [11, 22]) == [1, 11, 2, 22, 3])
        #expect(CardQueues.intersperse(a, [11, 22, 33, 44, 55, 66]) == [11, 1, 22, 33, 2, 44, 55, 3, 66])
        #expect(CardQueues.intersperse(a, [11, 22, 33, 44, 55, 66, 77, 88]) == [11, 22, 1, 33, 44, 2, 55, 66, 3, 77, 88])
        #expect(CardQueues.intersperse(a, []) == [1, 2, 3])
    }

    // MARK: fsrs-rs model.rs

    @Test func fsrsForgettingCurve() {
        let fsrs = FSRS6()
        let r = zip([0.0, 1, 2, 3, 4, 5], [1.0, 2, 3, 4, 4, 2]).map { fsrs.retrievability(daysElapsed: $0, stability: $1) }
        for (a, b) in zip(r, [1.0, 0.9403443, 0.9253786, 0.9185229, 0.9, 0.8261359]) { #expect(abs(a - b) < 1e-5) }
    }

    @Test func fsrsNextDifficultyAndStability() {
        let fsrs = FSRS6()
        let d = [1.0, 2, 3, 4].map { fsrs.nextDifficulty(5, rating: $0) }
        for (a, b) in zip(d, [8.354889, 6.6774445, 5.0, 3.3225555]) { #expect(abs(a - b) < 1e-4) }
        let recall = zip([1.0, 2, 3, 4], [0.9, 0.8, 0.7, 0.6]).map {
            fsrs.stabilityAfterSuccess(lastS: 5, lastD: $0, r: $1, rating: $0)
        }
        for (a, b) in zip(recall, [25.602541, 28.226582, 58.656002, 127.226685]) { #expect(abs(a - b) / b < 1e-4) }
        let forget = zip([1.0, 2, 3, 4], [0.9, 0.8, 0.7, 0.6]).map { fsrs.stabilityAfterFailure(lastS: 5, lastD: $0, r: $1) }
        for (a, b) in zip(forget, [1.0525396, 1.1894329, 1.3680838, 1.584989]) { #expect(abs(a - b) < 1e-4) }
        let short = [1.0, 2, 3, 4].map { fsrs.stabilityShortTerm(lastS: 5, rating: $0) }
        for (a, b) in zip(short, [1.596818, 5.0, 5.0, 8.12961]) { #expect(abs(a - b) < 1e-4) }
    }

    @Test func fsrsInitialStates() {
        let fsrs = FSRS6()
        let next = fsrs.nextStates(nil, desiredRetention: 0.9, daysElapsed: 0)
        #expect(next.again.memory.stability == FSRS6.defaultParameters[0])
        #expect(next.good.memory.stability == FSRS6.defaultParameters[2])
        // at 90% retention the interval equals the stability
        #expect(abs(next.good.interval - next.good.memory.stability) < 1e-6)
    }

    // MARK: Answering

    /// 12:00 on day 100; the day rolls over at 04:00 tomorrow.
    func noon() -> SchedTiming { SchedTiming(daysElapsed: 100, nextDayAt: 1_000_000 + 16 * 3600, now: 1_000_000) }

    @Test func newCardGoesThroughStepsThenGraduates() {
        let scheduler = Scheduler()
        let epd = ChessPosition.start.epd
        var timing = noon()
        let first = scheduler.answer(nil, epd: epd, position: 0, rating: .good, timing: timing)
        #expect(first.card.queue == .learn && first.card.ctype == .learn)
        #expect(first.card.remainingSteps == 1)
        // the 10 minute step, plus up to 25% fuzz
        #expect((600...750).contains(first.card.due - timing.now))
        #expect(first.revlog.type == .learning && first.revlog.ivl == -600 && first.revlog.lastIvl == 0)
        #expect(first.fromQueue == .new)

        timing = SchedTiming(daysElapsed: 100, nextDayAt: timing.nextDayAt, now: first.card.due)
        let second = scheduler.answer(first.card, epd: epd, position: 0, rating: .good, timing: timing)
        #expect(second.card.queue == .review && second.card.ctype == .review)
        #expect(second.card.interval >= 1)
        #expect(second.card.due == Int64(100 + second.card.interval))
        #expect(second.card.originalPosition == 0)
    }

    @Test func againOnNewCardIsOneMinute() {
        let answer = Scheduler().answer(nil, epd: ChessPosition.start.epd, position: 3, rating: .again, timing: noon())
        #expect(answer.card.remainingSteps == 2)
        #expect((60...75).contains(answer.card.due - noon().now))
    }

    @Test func lapseGoesToRelearningAndBack() {
        let scheduler = Scheduler()
        let epd = ChessPosition.start.epd
        var card = Card(id: 1, position: 0, added: 0)
        card.ctype = .review
        card.queue = .review
        card.interval = 10
        card.due = 100
        card.easeFactor = 2500
        card.memory = MemoryState(stability: 10, difficulty: 5)
        card.lastReviewTime = noon().now - 10 * 86_400
        let lapse = scheduler.answer(card, epd: epd, position: 0, rating: .again, timing: noon())
        #expect(lapse.card.ctype == .relearn && lapse.card.queue == .learn)
        #expect(lapse.card.lapses == 1)
        #expect((600...750).contains(lapse.card.due - noon().now))
        #expect(lapse.revlog.type == .review && lapse.revlog.ease == 1 && lapse.revlog.lastIvl == 10)
        #expect(lapse.fromQueue == .review)

        let later = SchedTiming(daysElapsed: 100, nextDayAt: noon().nextDayAt, now: lapse.card.due)
        let back = scheduler.answer(lapse.card, epd: epd, position: 0, rating: .good, timing: later)
        #expect(back.card.ctype == .review && back.card.queue == .review)
        #expect(back.revlog.type == .relearning)
    }

    @Test func learningStepAcrossRolloverBecomesDays() {
        // 5 minutes before the rollover, a 10 minute step crosses into tomorrow
        let timing = SchedTiming(daysElapsed: 100, nextDayAt: 2_000_000, now: 2_000_000 - 300)
        let answer = Scheduler().answer(nil, epd: ChessPosition.start.epd, position: 0, rating: .good, timing: timing)
        #expect(answer.card.queue == .dayLearn)
        #expect(answer.card.due == 101)
        #expect(answer.revlog.ivl == 1)
    }

    @Test func earlyReviewIsFiltered() {
        var card = Card(id: 1, position: 0, added: 0)
        card.ctype = .review
        card.queue = .review
        card.interval = 10
        card.due = 105
        card.easeFactor = 2500
        card.memory = MemoryState(stability: 10, difficulty: 5)
        card.lastReviewTime = noon().now - 5 * 86_400
        let answer = Scheduler().answer(card, epd: ChessPosition.start.epd, position: 0, rating: .good,
                                        timing: noon(), filtered: true)
        #expect(answer.revlog.type == .filtered)
        #expect(answer.card.interval >= 10)
    }

    @Test func leechTagAtEightLapses() {
        var card = Card(id: 1, position: 0, added: 0)
        card.ctype = .review
        card.queue = .review
        card.interval = 1
        card.due = 100
        card.easeFactor = 2500
        card.lapses = 7
        card.memory = MemoryState(stability: 1, difficulty: 9)
        card.lastReviewTime = noon().now - 86_400
        let answer = Scheduler().answer(card, epd: ChessPosition.start.epd, position: 0, rating: .again, timing: noon())
        #expect(answer.leeched)
        #expect(answer.card.leech == true)
        #expect(answer.card.queue != .suspended)  // Anki's default action: tag only
    }

    // MARK: Queue

    func epd(_ san: String) -> EPD {
        var position = ChessPosition.start
        for move in san.split(separator: " ") { position = position.play(san: String(move))!.1 }
        return position.epd
    }

    @Test func queueOrderAndCounts() {
        let timing = noon()
        var cards: [EPD: Card] = [:]
        func card(_ queue: Card.Queue, due: Int64, reps: Int = 1) -> Card {
            var c = Card(id: Int64(cards.count + 1), position: 0, added: 0)
            c.queue = queue
            c.ctype = queue == .review ? .review : .learn
            c.due = due
            c.reps = reps
            return c
        }
        let learnNow = epd("e4"), learnLater = epd("d4"), learnTonight = epd("c4"), review = epd("Nf3"), newCard = epd("g3")
        cards[learnNow] = card(.learn, due: timing.now - 10)
        cards[learnLater] = card(.learn, due: timing.now + 600)
        cards[learnTonight] = card(.learn, due: timing.now + 3 * 3600)
        cards[review] = card(.review, due: 100)
        let limits = RemainingLimits(config: DeckConfig(), limits: DeckLimits(), stats: DeckStudyStats(), today: 100)
        var queue = CardQueues(cards: cards, newCards: [newCard], limits: limits, timing: timing)
        // learning within 20 minutes counts; the one in 3 hours not yet
        #expect(queue.counts == CardQueues.Counts(new: 1, learning: 2, review: 1))
        #expect(queue.ordered.map(\.0) == [learnNow, review, newCard, learnLater])
        queue.remove(learnNow)
        queue.remove(review)
        queue.remove(newCard)
        #expect(queue.next?.0 == learnLater)  // shown early: nothing else left
        #expect(queue.nextLearningDue == Date(timeIntervalSince1970: TimeInterval(timing.now + 3 * 3600)))
    }

    @Test func dailyLimits() {
        var stats = DeckStudyStats()
        stats.recordAnswer(fromQueue: .new, millis: 0, today: 100)
        stats.recordAnswer(fromQueue: .review, millis: 0, today: 100)
        stats.recordAnswer(fromQueue: .learn, millis: 0, today: 100)
        var config = DeckConfig()
        config.newPerDay = 5
        config.reviewsPerDay = 10
        let limits = RemainingLimits(config: config, limits: DeckLimits(), stats: stats, today: 100)
        #expect(limits.new == 4)
        #expect(limits.review == 8)  // new cards count against the review limit
        var deck = DeckLimits()
        deck.newLimitToday = DayLimit(limit: 7, today: 100)
        #expect(RemainingLimits(config: config, limits: deck, stats: stats, today: 100).new == 6)
        // a different day: the counts and the today-only limit no longer apply
        #expect(RemainingLimits(config: config, limits: deck, stats: stats, today: 101).new == 5)
        stats.extendLimits(today: 100, new: 3, review: 0)
        #expect(RemainingLimits(config: config, limits: DeckLimits(), stats: stats, today: 100).new == 7)
    }

    @Test func timingRollsOverAtFour() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!
        let before = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 3, minute: 59))!
        let after = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 4, minute: 0))!
        let a = SchedTiming(now: before, calendar: calendar)
        let b = SchedTiming(now: after, calendar: calendar)
        #expect(b.daysElapsed == a.daysElapsed + 1)
        #expect(a.nextDayAt == Int64(after.timeIntervalSince1970))
    }
}
