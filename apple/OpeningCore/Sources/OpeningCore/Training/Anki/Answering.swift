// Ported from Anki, rslib/src/scheduler/answering/{mod,current,learning,review,relearning,revlog}.rs
// (https://github.com/ankitects/anki).
// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

import Foundation

/// Answers cards: current state → next states → the card and revlog entry after an answer.
public struct Scheduler: Sendable {
    public var config: DeckConfig
    public var fsrs: FSRS6

    public init(config: DeckConfig = DeckConfig(), fsrs: FSRS6 = FSRS6()) {
        self.config = config
        self.fsrs = fsrs
    }

    var learnSteps: LearningSteps { LearningSteps(config.learnSteps) }
    var relearnSteps: LearningSteps { LearningSteps(config.relearnSteps) }

    /// `card` nil means New at `position`. `filtered`: studied outside the normal queue (a branch
    /// session or a review ahead), so a review card keeps its real due day.
    public func currentState(_ card: Card?, position: Int, timing: SchedTiming, filtered: Bool) -> CardState {
        guard let card, card.ctype != .new else { return .new(NewState(position: card.map { Int($0.due) } ?? position)) }
        var due = card.due
        if !filtered, card.ctype == .review { due = min(due, Int64(timing.daysElapsed)) }
        let elapsedSecs = { (lastIvl: Int) -> Int in
            switch card.queue {
            case .learn:
                let lastAnswered = card.lastReviewTime ?? (due - Int64(lastIvl))
                return max(0, Int(timing.now - lastAnswered))
            case .dayLearn:
                let lastIvlDays = max(lastIvl / secsPerDay, 1)
                return max(0, (timing.daysElapsed - Int(due) + lastIvlDays) * secsPerDay)
            default:
                return 0
            }
        }
        let ease = Double(card.easeFactor) / 1000
        switch card.ctype {
        case .new:
            return .new(NewState(position: Int(due)))
        case .learn:
            let lastIvl = learnSteps.currentDelaySecs(card.remainingSteps)
            return .learning(LearnState(remainingSteps: card.remainingSteps, scheduledSecs: lastIvl,
                                        elapsedSecs: elapsedSecs(lastIvl), memory: card.memory))
        case .review:
            return .review(ReviewState(scheduledDays: card.interval,
                                       elapsedDays: max(0, card.interval - (Int(due) - timing.daysElapsed)),
                                       easeFactor: ease, lapses: card.lapses, memory: card.memory))
        case .relearn:
            let lastIvl = relearnSteps.currentDelaySecs(card.remainingSteps)
            return .relearning(RelearnState(
                learning: LearnState(remainingSteps: card.remainingSteps, scheduledSecs: lastIvl,
                                     elapsedSecs: elapsedSecs(lastIvl), memory: card.memory),
                review: ReviewState(scheduledDays: card.interval, elapsedDays: card.interval, easeFactor: ease,
                                    lapses: card.lapses, memory: card.memory)))
        }
    }

    private func context(for card: Card?, id: Int64, timing: SchedTiming) -> StateContext {
        let daysElapsed = card?.lastReviewTime.map { timing.daysSince($0) } ?? 0
        let next = fsrs.nextStates(card?.memory, desiredRetention: config.desiredRetention, daysElapsed: daysElapsed)
        return StateContext(
            fuzzFactor: fuzzFactor(seed: fuzzSeed(cardID: id, reps: card?.reps ?? 0)),
            fsrsNextStates: next,
            fsrsShortTermWithStepsEnabled: config.fsrsShortTermWithStepsEnabled,
            fsrsAllowShortTerm: fsrs.w[17] > 0 && fsrs.w[18] > 0,
            steps: learnSteps,
            graduatingIntervalGood: config.graduatingIntervalGood,
            graduatingIntervalEasy: config.graduatingIntervalEasy,
            initialEase: config.initialEase,
            hardMultiplier: config.hardMultiplier,
            easyMultiplier: config.easyMultiplier,
            intervalMultiplier: config.intervalMultiplier,
            maximumReviewInterval: config.maximumReviewInterval,
            leechThreshold: config.leechThreshold,
            relearnSteps: relearnSteps,
            lapseMultiplier: config.lapseMultiplier,
            minimumLapseInterval: config.minimumLapseInterval)
    }

    public func nextStates(_ card: Card?, id: Int64, position: Int, timing: SchedTiming, filtered: Bool) -> SchedulingStates {
        currentState(card, position: position, timing: timing, filtered: filtered)
            .nextStates(context(for: card, id: id, timing: timing))
    }

    public struct Answer: Sendable {
        public var card: Card
        public var revlog: RevlogEntry
        /// The queue before answering (Anki counts new/review studied by it).
        public var fromQueue: Card.Queue
        public var leeched: Bool
    }

    /// Answers a card. `card` nil means a New card at `position`.
    public func answer(_ card: Card?, epd: EPD, position: Int, rating: Rating, timing: SchedTiming,
                       filtered: Bool = false, takenMillis: Int = 0, answeredAt: Int64? = nil) -> Answer {
        let id = card?.id ?? Card.id(for: epd)
        let states = nextStates(card, id: id, position: position, timing: timing, filtered: filtered)
        let current = states.current
        let next = states[rating]
        var updated = card ?? Card(id: id, position: position, added: timing.now)
        let fromQueue = updated.queue
        let seed = fuzzSeed(cardID: id, reps: updated.reps)

        let factor: Double
        switch next {
        case .new(let s):
            updated.ctype = .new
            updated.queue = .new
            updated.due = Int64(s.position)
            updated.originalPosition = nil
            updated.memory = nil
            factor = 0
        case .learning(let s):
            updated.remainingSteps = s.remainingSteps
            updated.ctype = .learn
            if let position = current.newPosition { updated.originalPosition = position }
            updated.memory = s.memory
            setLearningDue(&updated, next.intervalKind, timing: timing, seed: seed)
            factor = updated.memory?.difficultyShifted ?? 0
        case .review(let s):
            updated.queue = .review
            updated.ctype = .review
            updated.interval = s.scheduledDays
            updated.due = Int64(timing.daysElapsed + s.scheduledDays)
            updated.easeFactor = Int((s.easeFactor * 1000).rounded())
            updated.lapses = s.lapses
            updated.remainingSteps = 0
            if let position = current.newPosition { updated.originalPosition = position }
            updated.memory = s.memory
            factor = updated.memory?.difficultyShifted ?? s.easeFactor
        case .relearning(let s):
            updated.interval = s.review.scheduledDays
            updated.remainingSteps = s.learning.remainingSteps
            updated.ctype = .relearn
            updated.lapses = s.review.lapses
            updated.easeFactor = Int((s.review.easeFactor * 1000).rounded())
            if let position = current.newPosition { updated.originalPosition = position }
            updated.memory = s.learning.memory
            setLearningDue(&updated, next.intervalKind, timing: timing, seed: seed)
            factor = updated.memory?.difficultyShifted ?? s.review.easeFactor
        }
        updated.reps += 1
        updated.lastReviewTime = timing.now
        if next.leeched {
            updated.leech = true
            if config.leechAction == .suspend { updated.queue = .suspended }
        }

        let rollover = timing.secsUntilRollover
        let revlog = RevlogEntry(
            id: answeredAt ?? timing.now * 1000, cid: epd, ease: rating.rawValue,
            ivl: next.intervalKind.maybeAsDays(secsUntilRollover: rollover).asRevlogInterval,
            lastIvl: current.intervalKind.maybeAsDays(secsUntilRollover: rollover).asRevlogInterval,
            factor: Int((factor * 1000).rounded()),
            time: min(max(takenMillis, 0), config.capAnswerTimeToSecs * 1000),
            type: current.revlogKind)
        return Answer(card: updated, revlog: revlog, fromQueue: fromQueue, leeched: next.leeched)
    }

    private func setLearningDue(_ card: inout Card, _ interval: IntervalKind, timing: SchedTiming, seed: UInt64) {
        switch interval.maybeAsDays(secsUntilRollover: timing.secsUntilRollover) {
        case .secs(let secs):
            card.queue = .learn
            card.due = timing.now + Int64(learningIntervalWithFuzz(seed: seed, secs))
        case .days(let days):
            card.queue = .dayLearn
            card.due = Int64(timing.daysElapsed + days)
        }
    }
}
