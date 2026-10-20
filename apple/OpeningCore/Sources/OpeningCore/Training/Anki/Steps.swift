// Ported from Anki, rslib/src/scheduler/states/steps.rs (https://github.com/ankitects/anki).
// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

import Foundation

let secsPerDay = 86_400

/// Learning or relearning steps, in minutes.
public struct LearningSteps: Sendable, Equatable {
    public let steps: [Double]

    public init(_ steps: [Double]) { self.steps = steps }

    private static func toSecs(_ minutes: Double) -> Int { max(0, Int(minutes * 60)) }

    /// Strips off "learning today" and keeps the index in bounds.
    private func index(_ remaining: Int) -> Int {
        let total = steps.count
        return min(max(0, total - remaining % 1000), max(0, total - 1))
    }

    private func secs(at index: Int) -> Int? {
        steps.indices.contains(index) ? Self.toSecs(steps[index]) : nil
    }

    func againDelaySecsLearn() -> Int? { secs(at: 0) }

    func hardDelaySecs(_ remaining: Int) -> Int? {
        let idx = index(remaining)
        // If the current step is invalid, try the first step.
        guard let current = secs(at: idx) ?? steps.first.map(Self.toSecs) else { return nil }
        return idx == 0 ? hardDelaySecsForFirstStep(current) : current
    }

    /// Avoids equality with the again interval, and keeps it below the good interval.
    private func hardDelaySecsForFirstStep(_ againSecs: Int) -> Int {
        if let next = secs(at: 1) {
            // average of first (again) and second (good) steps
            return maybeRoundInDays((againSecs + next) / 2)
        }
        // 50% more than the again secs, but at most one day more
        return maybeRoundInDays(min(againSecs * 3 / 2, againSecs + secsPerDay))
    }

    func goodDelaySecs(_ remaining: Int) -> Int? { secs(at: index(remaining) + 1) }

    func currentDelaySecs(_ remaining: Int) -> Int { secs(at: index(remaining)) ?? 0 }

    func remainingForGood(_ remaining: Int) -> Int { max(0, steps.count - (index(remaining) + 1)) }

    func remainingForFailed() -> Int { steps.count }

    var isEmpty: Bool { steps.isEmpty }
}

/// Above one day, rounds to whole days, so results are the same earlier and later in the day.
private func maybeRoundInDays(_ secs: Int) -> Int {
    secs > secsPerDay ? Int((Double(secs) / Double(secsPerDay)).rounded()) * secsPerDay : secs
}
