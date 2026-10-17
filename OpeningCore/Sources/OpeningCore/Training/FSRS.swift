import Foundation

public enum Grade: Int, Codable, Sendable {
    case again = 1, hard, good, easy
}

/// Spaced-repetition state of one card (one position where it's your move).
public struct CardState: Codable, Sendable, Hashable {
    public enum Phase: String, Codable, Sendable {
        case learning, review, relearning
    }

    public var stability: Double
    public var difficulty: Double
    public var due: Date
    public var lastReview: Date
    public var reps: Int
    public var lapses: Int
    public var phase: Phase

    public func isDue(at now: Date) -> Bool { due <= now }
    /// Mastered: the memory is expected to last at least three weeks.
    public var isMature: Bool { phase == .review && stability >= 21 }
}

/// FSRS-5 scheduler (https://github.com/open-spaced-repetition), default parameters.
public struct FSRS: Sendable {
    public var weights: [Double] = [
        0.40255, 1.18385, 3.173, 15.69105, 7.1949, 0.5345, 1.4604, 0.0046, 1.54575, 0.1192,
        1.01925, 1.9395, 0.11, 0.29605, 2.2698, 0.2315, 2.9898, 0.51655, 0.6621,
    ]
    public var desiredRetention = 0.9
    public var maximumInterval: Double = 36500
    /// Delay before a failed card comes back.
    public var relearnDelay: TimeInterval = 10 * 60

    private let decay = -0.5
    private var factor: Double { pow(0.9, 1 / decay) - 1 }  // 19/81

    public init() {}

    public func review(_ card: CardState?, grade: Grade, now: Date = .now) -> CardState {
        let g = Double(grade.rawValue)
        guard var card else {
            let s = initialStability(grade)
            let d = initialDifficulty(grade)
            return schedule(CardState(stability: s, difficulty: d, due: now, lastReview: now, reps: 1,
                                      lapses: grade == .again ? 1 : 0, phase: grade == .again ? .learning : .review),
                            grade: grade, now: now)
        }
        let elapsedDays = max(0, now.timeIntervalSince(card.lastReview) / 86400)
        let r = retrievability(elapsedDays: elapsedDays, stability: card.stability)

        if elapsedDays < 1 {
            card.stability = max(0.01, card.stability * exp(weights[17] * (g - 3 + weights[18])))
        } else if grade == .again {
            let forget = weights[11] * pow(card.difficulty, -weights[12])
                * (pow(card.stability + 1, weights[13]) - 1) * exp(weights[14] * (1 - r))
            card.stability = max(0.01, min(forget, card.stability))
        } else {
            let hardPenalty = grade == .hard ? weights[15] : 1
            let easyBonus = grade == .easy ? weights[16] : 1
            let growth = exp(weights[8]) * (11 - card.difficulty) * pow(card.stability, -weights[9])
                * (exp(weights[10] * (1 - r)) - 1) * hardPenalty * easyBonus
            card.stability *= growth + 1
        }
        card.difficulty = nextDifficulty(card.difficulty, grade: grade)
        card.reps += 1
        if grade == .again {
            card.lapses += 1
            card.phase = .relearning
        } else {
            card.phase = .review
        }
        card.lastReview = now
        return schedule(card, grade: grade, now: now)
    }

    public func retrievability(elapsedDays: Double, stability: Double) -> Double {
        pow(1 + factor * elapsedDays / stability, decay)
    }

    public func interval(stability: Double) -> Double {
        let days = stability / factor * (pow(desiredRetention, 1 / decay) - 1)
        return min(max(1, days.rounded()), maximumInterval)
    }

    private func schedule(_ card: CardState, grade: Grade, now: Date) -> CardState {
        var c = card
        c.due = grade == .again ? now.addingTimeInterval(relearnDelay)
            : now.addingTimeInterval(interval(stability: c.stability) * 86400)
        return c
    }

    private func initialStability(_ grade: Grade) -> Double {
        max(weights[grade.rawValue - 1], 0.1)
    }

    private func initialDifficulty(_ grade: Grade) -> Double {
        clampD(weights[4] - exp(weights[5] * Double(grade.rawValue - 1)) + 1)
    }

    private func nextDifficulty(_ d: Double, grade: Grade) -> Double {
        let delta = -weights[6] * (Double(grade.rawValue) - 3)
        let damped = d + delta * (10 - d) / 9
        let reverted = weights[7] * initialDifficulty(.easy) + (1 - weights[7]) * damped
        return clampD(reverted)
    }

    private func clampD(_ d: Double) -> Double { min(max(d, 1), 10) }
}
