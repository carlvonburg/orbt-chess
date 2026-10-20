// Ported from Anki, rslib/src/scheduler/states/{mod,normal,new,learning,review,relearning}.rs
// (https://github.com/ankitects/anki).
// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// Not ported: preview filtered decks and the rescheduling-filter wrapper. A card studied in a
// branch session keeps its normal state; only its revlog kind shows it was reviewed early.

import Foundation

let initialEaseFactor = 2.5
let minimumEaseFactor = 1.3
private let easeFactorAgainDelta = -0.2
private let easeFactorHardDelta = -0.15
private let easeFactorEasyDelta = 0.15

/// Anki's answer buttons.
public enum Rating: Int, Codable, Sendable {
    case again = 1, hard, good, easy
}

public enum RevlogReviewKind: Int, Codable, Sendable {
    case learning = 0, review, relearning, filtered, manual, rescheduled
}

public struct NewState: Equatable, Sendable {
    public var position: Int
}

public struct LearnState: Equatable, Sendable {
    public var remainingSteps: Int
    public var scheduledSecs: Int
    public var elapsedSecs: Int
    public var memory: MemoryState?
}

public struct ReviewState: Equatable, Sendable {
    public var scheduledDays: Int
    public var elapsedDays: Int
    public var easeFactor: Double = initialEaseFactor
    public var lapses: Int = 0
    public var leeched = false
    public var memory: MemoryState?

    var daysLate: Int { elapsedDays - scheduledDays }
}

public struct RelearnState: Equatable, Sendable {
    public var learning: LearnState
    public var review: ReviewState
}

public enum CardState: Equatable, Sendable {
    case new(NewState)
    case learning(LearnState)
    case review(ReviewState)
    case relearning(RelearnState)

    var intervalKind: IntervalKind {
        switch self {
        case .new: .secs(0)
        case .learning(let s): .secs(s.scheduledSecs)
        case .review(let s): .days(s.scheduledDays)
        case .relearning(let s): .secs(s.learning.scheduledSecs)
        }
    }

    var revlogKind: RevlogReviewKind {
        switch self {
        case .new, .learning: .learning
        case .review(let s): s.daysLate < 0 ? .filtered : .review
        case .relearning: .relearning
        }
    }

    var reviewState: ReviewState? {
        switch self {
        case .review(let s): s
        case .relearning(let s): s.review
        default: nil
        }
    }

    var leeched: Bool { reviewState?.leeched ?? false }

    var newPosition: Int? {
        if case .new(let s) = self { return s.position }
        return nil
    }

    func nextStates(_ ctx: StateContext) -> SchedulingStates {
        switch self {
        case .new:
            // A new card is answered like a failed learning card, but stays New as current.
            let next = LearnState(remainingSteps: ctx.steps.remainingForFailed(), scheduledSecs: 0,
                                  elapsedSecs: 0, memory: nil).nextStates(ctx)
            return SchedulingStates(current: self, again: next.again, hard: next.hard, good: next.good, easy: next.easy)
        case .learning(let s): return s.nextStates(ctx)
        case .review(let s): return s.nextStates(ctx)
        case .relearning(let s): return s.nextStates(ctx)
        }
    }
}

public struct SchedulingStates: Equatable, Sendable {
    public var current, again, hard, good, easy: CardState

    public subscript(rating: Rating) -> CardState {
        switch rating {
        case .again: again
        case .hard: hard
        case .good: good
        case .easy: easy
        }
    }
}

/// Info required during state transitions.
struct StateContext {
    /// In `0..<1`; picks the final interval from the fuzz range.
    var fuzzFactor: Double?
    var fsrsNextStates: FSRS6.NextStates?
    var fsrsShortTermWithStepsEnabled = false
    var fsrsAllowShortTerm = false
    // learning
    var steps: LearningSteps
    var graduatingIntervalGood = 1
    var graduatingIntervalEasy = 4
    var initialEase = initialEaseFactor
    // reviewing
    var hardMultiplier = 1.2
    var easyMultiplier = 1.3
    var intervalMultiplier = 1.0
    var maximumReviewInterval = 36500
    var leechThreshold = 8
    // relearning
    var relearnSteps: LearningSteps
    var lapseMultiplier = 0.0
    var minimumLapseInterval = 1

    func minAndMaxReviewIntervals(_ minimum: Int) -> (Int, Int) {
        let maximum = max(maximumReviewInterval, 1)
        return (min(max(minimum, 1), maximum), maximum)
    }

    func withReviewFuzz(_ interval: Double, minimum: Int, maximum: Int) -> Int {
        OpeningCore.withReviewFuzz(fuzzFactor, interval, minimum: minimum, maximum: maximum)
    }

    /// FSRS may schedule below half a day itself only when allowed and no steps are set.
    func shortTerm(_ interval: Double, steps: LearningSteps) -> Bool {
        fsrsAllowShortTerm && (fsrsShortTermWithStepsEnabled || steps.isEmpty) && interval < 0.5
    }
}

// MARK: Learning

extension LearnState {
    func nextStates(_ ctx: StateContext) -> SchedulingStates {
        SchedulingStates(current: .learning(self), again: answerAgain(ctx), hard: answerHard(ctx),
                         good: answerGood(ctx), easy: .review(answerEasy(ctx)))
    }

    /// Shared fallback when no step applies: graduate, or a short-term FSRS step.
    private func graduated(_ ctx: StateContext, fsrs: FSRS6.ItemState?, memory: MemoryState?,
                           remaining: Int) -> CardState {
        let (minimum, maximum) = ctx.minAndMaxReviewIntervals(1)
        let interval = fsrs?.interval ?? Double(ctx.graduatingIntervalGood)
        if fsrs != nil, ctx.shortTerm(interval, steps: ctx.steps) {
            return .learning(LearnState(remainingSteps: remaining, scheduledSecs: Int(interval * 86_400),
                                        elapsedSecs: 0, memory: memory))
        }
        return .review(ReviewState(
            scheduledDays: ctx.withReviewFuzz(max(interval.rounded(), 1), minimum: minimum, maximum: maximum),
            elapsedDays: 0, easeFactor: ctx.initialEase, memory: memory))
    }

    func answerAgain(_ ctx: StateContext) -> CardState {
        let memory = ctx.fsrsNextStates?.again.memory
        if let delay = ctx.steps.againDelaySecsLearn() {
            return .learning(LearnState(remainingSteps: ctx.steps.remainingForFailed(), scheduledSecs: delay,
                                        elapsedSecs: 0, memory: memory))
        }
        return graduated(ctx, fsrs: ctx.fsrsNextStates?.again, memory: memory, remaining: ctx.steps.remainingForFailed())
    }

    func answerHard(_ ctx: StateContext) -> CardState {
        let memory = ctx.fsrsNextStates?.hard.memory
        if let delay = ctx.steps.hardDelaySecs(remainingSteps) {
            return .learning(LearnState(remainingSteps: remainingSteps, scheduledSecs: delay, elapsedSecs: 0, memory: memory))
        }
        return graduated(ctx, fsrs: ctx.fsrsNextStates?.hard, memory: memory, remaining: remainingSteps)
    }

    func answerGood(_ ctx: StateContext) -> CardState {
        let memory = ctx.fsrsNextStates?.good.memory
        if let delay = ctx.steps.goodDelaySecs(remainingSteps) {
            return .learning(LearnState(remainingSteps: ctx.steps.remainingForGood(remainingSteps),
                                        scheduledSecs: delay, elapsedSecs: 0, memory: memory))
        }
        return graduated(ctx, fsrs: ctx.fsrsNextStates?.good, memory: memory, remaining: remainingSteps)
    }

    func answerEasy(_ ctx: StateContext) -> ReviewState {
        var (minimum, maximum) = ctx.minAndMaxReviewIntervals(1)
        let interval: Int
        if let states = ctx.fsrsNextStates {
            let good = ctx.withReviewFuzz(states.good.interval, minimum: minimum, maximum: maximum)
            minimum = good + 1
            interval = roundedInt(max(states.easy.interval.rounded(), 1))
        } else {
            interval = ctx.graduatingIntervalEasy
        }
        return ReviewState(scheduledDays: ctx.withReviewFuzz(Double(interval), minimum: minimum, maximum: maximum),
                           elapsedDays: 0, easeFactor: ctx.initialEase, memory: ctx.fsrsNextStates?.easy.memory)
    }
}

// MARK: Review

extension ReviewState {
    func nextStates(_ ctx: StateContext) -> SchedulingStates {
        let (hard, good, easy) = passingReviewIntervals(ctx)
        var hardState = self, goodState = self, easyState = self
        hardState.scheduledDays = hard
        hardState.elapsedDays = 0
        hardState.easeFactor = max(easeFactor + easeFactorHardDelta, minimumEaseFactor)
        hardState.memory = ctx.fsrsNextStates?.hard.memory
        goodState.scheduledDays = good
        goodState.elapsedDays = 0
        goodState.memory = ctx.fsrsNextStates?.good.memory
        easyState.scheduledDays = easy
        easyState.elapsedDays = 0
        easyState.easeFactor = easeFactor + easeFactorEasyDelta
        easyState.memory = ctx.fsrsNextStates?.easy.memory
        return SchedulingStates(current: .review(self), again: answerAgain(ctx), hard: .review(hardState),
                                good: .review(goodState), easy: .review(easyState))
    }

    func failingReviewInterval(_ ctx: StateContext) -> (Double, MemoryState?) {
        if let states = ctx.fsrsNextStates {
            // In FSRS, fuzz is applied when the card leaves the relearning stage.
            return (states.again.interval, states.again.memory)
        }
        let (minimum, maximum) = ctx.minAndMaxReviewIntervals(ctx.minimumLapseInterval)
        let interval = ctx.withReviewFuzz(max(Double(scheduledDays), 1) * ctx.lapseMultiplier, minimum: minimum, maximum: maximum)
        return (Double(interval), nil)
    }

    func answerAgain(_ ctx: StateContext) -> CardState {
        let lapses = self.lapses + 1
        let (days, memory) = failingReviewInterval(ctx)
        let againReview = ReviewState(
            scheduledDays: roundedInt(max(days.rounded(), 1)), elapsedDays: 0,
            easeFactor: max(easeFactor + easeFactorAgainDelta, minimumEaseFactor),
            lapses: lapses, leeched: leechThresholdMet(lapses: lapses, threshold: ctx.leechThreshold), memory: memory)
        if let delay = ctx.relearnSteps.againDelaySecsLearn() {
            return .relearning(RelearnState(
                learning: LearnState(remainingSteps: ctx.relearnSteps.remainingForFailed(), scheduledSecs: delay,
                                     elapsedSecs: 0, memory: memory),
                review: againReview))
        }
        if ctx.shortTerm(days, steps: ctx.relearnSteps) {
            return .relearning(RelearnState(
                learning: LearnState(remainingSteps: ctx.relearnSteps.remainingForFailed(), scheduledSecs: Int(days * 86_400),
                                     elapsedSecs: 0, memory: memory),
                review: againReview))
        }
        return .review(againReview)
    }

    /// Hard, good and easy intervals; each depends on the previous.
    func passingReviewIntervals(_ ctx: StateContext) -> (Int, Int, Int) {
        if let states = ctx.fsrsNextStates {
            let maxIvl = ctx.maximumReviewInterval
            let hard = constrainPassingInterval(ctx, states.hard.interval,
                minimum: max(minimumReviewFuzzInterval(states.hard.interval, previous: scheduledDays, maximum: maxIvl), 1), fuzz: true)
            let good = constrainPassingInterval(ctx, states.good.interval,
                minimum: max(minimumReviewFuzzInterval(states.good.interval, previous: scheduledDays, maximum: maxIvl), hard + 1), fuzz: true)
            let easy = constrainPassingInterval(ctx, states.easy.interval,
                minimum: max(minimumReviewFuzzInterval(states.easy.interval, previous: scheduledDays, maximum: maxIvl), good + 1), fuzz: true)
            return (hard, good, easy)
        }
        return daysLate < 0 ? passingEarlyReviewIntervals(ctx) : passingNonEarlyReviewIntervals(ctx)
    }

    private func passingNonEarlyReviewIntervals(_ ctx: StateContext) -> (Int, Int, Int) {
        let current = max(Double(scheduledDays), 1)
        let late = Double(max(daysLate, 0))
        let hardFactor = ctx.hardMultiplier
        let hardMinimum = hardFactor <= 1 ? 0 : scheduledDays + 1
        let hard = constrainPassingInterval(ctx, current * hardFactor, minimum: hardMinimum, fuzz: true)
        let goodMinimum = hardFactor <= 1 ? scheduledDays + 1 : hard + 1
        let good = constrainPassingInterval(ctx, (current + late / 2) * easeFactor, minimum: goodMinimum, fuzz: true)
        let easy = constrainPassingInterval(ctx, (current + late) * easeFactor * ctx.easyMultiplier, minimum: good + 1, fuzz: true)
        return (hard, good, easy)
    }

    private func passingEarlyReviewIntervals(_ ctx: StateContext) -> (Int, Int, Int) {
        let scheduled = max(Double(scheduledDays), 1)
        let elapsed = Double(elapsedDays)
        let hard = constrainPassingInterval(ctx, max(elapsed * ctx.hardMultiplier, scheduled * ctx.hardMultiplier / 2),
                                            minimum: 0, fuzz: false)
        let good = constrainPassingInterval(ctx, max(elapsed * easeFactor, scheduled), minimum: 0, fuzz: false)
        let reducedBonus = ctx.easyMultiplier - (ctx.easyMultiplier - 1) / 2
        let easy = constrainPassingInterval(ctx, max(elapsed * easeFactor, scheduled) * reducedBonus, minimum: 0, fuzz: false)
        return (hard, good, easy)
    }
}

/// True at the threshold, and every half threshold (rounded up) after that.
func leechThresholdMet(lapses: Int, threshold: Int) -> Bool {
    guard threshold > 0 else { return false }
    let half = max(Int((Double(threshold) / 2).rounded(.up)), 1)
    return lapses >= threshold && (lapses - threshold) % half == 0
}

/// Applies the interval multiplier (not with FSRS), fuzz, and the minimum and maximum.
private func constrainPassingInterval(_ ctx: StateContext, _ interval: Double, minimum: Int, fuzz: Bool) -> Int {
    let interval = ctx.fsrsNextStates != nil ? interval : interval * ctx.intervalMultiplier
    let (minimum, maximum) = ctx.minAndMaxReviewIntervals(minimum)
    if fuzz { return ctx.withReviewFuzz(interval, minimum: minimum, maximum: maximum) }
    return min(max(roundedInt(interval), minimum), maximum)
}

// MARK: Relearning

extension RelearnState {
    func nextStates(_ ctx: StateContext) -> SchedulingStates {
        SchedulingStates(current: .relearning(self), again: answerAgain(ctx), hard: answerHard(ctx),
                         good: answerGood(ctx), easy: .review(answerEasy(ctx)))
    }

    /// FSRS fallback once the relearning steps are used up.
    private func fsrsExit(_ ctx: StateContext, _ item: FSRS6.ItemState, memory: MemoryState?,
                          remaining: Int, resetElapsed: Bool) -> CardState {
        let (minimum, maximum) = ctx.minAndMaxReviewIntervals(1)
        var exitReview = review
        exitReview.scheduledDays = ctx.withReviewFuzz(max(item.interval.rounded(), 1), minimum: minimum, maximum: maximum)
        exitReview.memory = memory
        if ctx.shortTerm(item.interval, steps: ctx.relearnSteps) {
            var stay = learning
            stay.scheduledSecs = Int(item.interval * 86_400)
            stay.remainingSteps = remaining
            stay.memory = memory
            if resetElapsed { stay.elapsedSecs = 0 }
            return .relearning(RelearnState(learning: stay, review: exitReview))
        }
        return .review(exitReview)
    }

    func answerAgain(_ ctx: StateContext) -> CardState {
        let (days, memory) = review.failingReviewInterval(ctx)
        if let delay = ctx.relearnSteps.againDelaySecsLearn() {
            var againReview = review
            againReview.scheduledDays = roundedInt(max(days.rounded(), 1))
            againReview.elapsedDays = 0
            againReview.memory = memory
            return .relearning(RelearnState(
                learning: LearnState(remainingSteps: ctx.relearnSteps.remainingForFailed(), scheduledSecs: delay,
                                     elapsedSecs: 0, memory: memory),
                review: againReview))
        }
        if let states = ctx.fsrsNextStates {
            return fsrsExit(ctx, states.again, memory: memory, remaining: ctx.relearnSteps.remainingForFailed(), resetElapsed: true)
        }
        return .review(review)
    }

    func answerHard(_ ctx: StateContext) -> CardState {
        let memory = ctx.fsrsNextStates?.hard.memory
        if let delay = ctx.relearnSteps.hardDelaySecs(learning.remainingSteps) {
            var stay = learning
            stay.scheduledSecs = delay
            stay.memory = memory
            var r = review
            r.elapsedDays = 0
            r.memory = memory
            return .relearning(RelearnState(learning: stay, review: r))
        }
        if let states = ctx.fsrsNextStates {
            return fsrsExit(ctx, states.hard, memory: memory, remaining: learning.remainingSteps, resetElapsed: false)
        }
        return .review(review)
    }

    func answerGood(_ ctx: StateContext) -> CardState {
        let memory = ctx.fsrsNextStates?.good.memory
        if let delay = ctx.relearnSteps.goodDelaySecs(learning.remainingSteps) {
            var r = review
            r.elapsedDays = 0
            r.memory = memory
            return .relearning(RelearnState(
                learning: LearnState(remainingSteps: ctx.relearnSteps.remainingForGood(learning.remainingSteps),
                                     scheduledSecs: delay, elapsedSecs: 0, memory: memory),
                review: r))
        }
        if let states = ctx.fsrsNextStates {
            return fsrsExit(ctx, states.good, memory: memory,
                            remaining: ctx.relearnSteps.remainingForGood(learning.remainingSteps), resetElapsed: false)
        }
        return .review(review)
    }

    func answerEasy(_ ctx: StateContext) -> ReviewState {
        var r = review
        if let states = ctx.fsrsNextStates {
            var (minimum, maximum) = ctx.minAndMaxReviewIntervals(1)
            let good = ctx.withReviewFuzz(states.good.interval, minimum: minimum, maximum: maximum)
            minimum = good + 1
            r.scheduledDays = ctx.withReviewFuzz(max(states.easy.interval.rounded(), 1), minimum: minimum, maximum: maximum)
        } else {
            r.scheduledDays = review.scheduledDays + 1
        }
        r.elapsedDays = 0
        r.memory = ctx.fsrsNextStates?.easy.memory
        return r
    }
}
