// Ported from fsrs-rs v6.6.2, src/model.rs and src/inference.rs, the FSRS version Anki uses
// (https://github.com/open-spaced-repetition/fsrs-rs).
// Copyright (c) 2023, Open Spaced Repetition. BSD 3-Clause License:
// Redistribution and use in source and binary forms, with or without modification, are
// permitted provided that the following conditions are met: (1) redistributions of source code
// must retain the above copyright notice, this list of conditions and the following disclaimer;
// (2) redistributions in binary form must reproduce the above copyright notice, this list of
// conditions and the following disclaimer in the documentation and/or other materials provided
// with the distribution; (3) neither the name of the copyright holder nor the names of its
// contributors may be used to endorse or promote products derived from this software without
// specific prior written permission. THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND
// CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES ARE DISCLAIMED.

import Foundation

/// FSRS memory state: stability in days, difficulty 1...10.
public struct MemoryState: Codable, Sendable, Hashable {
    public var stability: Double
    public var difficulty: Double

    public init(stability: Double, difficulty: Double) {
        self.stability = stability
        self.difficulty = difficulty
    }

    /// Anki's revlog "factor" under FSRS: (D - 1) / 9 + 0.1.
    var difficultyShifted: Double { (difficulty - 1) / 9 + 0.1 }
}

public struct FSRS6: Sendable {
    public static let defaultParameters: [Double] = [
        0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194, 0.001, 1.8722, 0.1666, 0.796,
        1.4835, 0.0614, 0.2629, 1.6483, 0.6014, 1.8729, 0.5425, 0.0912, 0.0658, 0.1542,
    ]
    static let sMin = 0.001, sMax = 36500.0, dMin = 1.0, dMax = 10.0

    public let w: [Double]

    public init(parameters: [Double] = FSRS6.defaultParameters) {
        precondition(parameters.count == 21, "FSRS-6 needs 21 parameters")
        w = parameters
    }

    public struct ItemState: Sendable, Equatable {
        public var memory: MemoryState
        /// Days, not rounded.
        public var interval: Double
    }

    public struct NextStates: Sendable, Equatable {
        public var again, hard, good, easy: ItemState
    }

    public func nextStates(_ current: MemoryState?, desiredRetention: Double, daysElapsed: Int) -> NextStates {
        let state = current ?? MemoryState(stability: 0, difficulty: 0)
        let nth = current == nil ? 0 : 1
        func item(_ rating: Double) -> ItemState {
            let memory = step(deltaT: Double(daysElapsed), rating: rating, state: state, nth: nth)
            return ItemState(memory: memory, interval: nextInterval(stability: memory.stability, desiredRetention: desiredRetention))
        }
        return NextStates(again: item(1), hard: item(2), good: item(3), easy: item(4))
    }

    private var decay: Double { -w[20] }
    private var factor: Double { exp(log(0.9) / decay) - 1 }

    public func retrievability(daysElapsed t: Double, stability s: Double) -> Double {
        pow(t / s * factor + 1, decay)
    }

    public func nextInterval(stability: Double, desiredRetention: Double) -> Double {
        stability / factor * (pow(desiredRetention, 1 / decay) - 1)
    }

    func initStability(_ rating: Int) -> Double { w[min(max(rating - 1, 0), 3)] }

    func initDifficulty(_ rating: Int) -> Double { w[4] - exp(w[5] * Double(max(rating - 1, 0))) + 1 }

    private func meanReversion(_ newD: Double) -> Double { w[7] * (initDifficulty(4) - newD) + newD }

    func nextDifficulty(_ d: Double, rating: Double) -> Double {
        let deltaD = -w[6] * (rating - 3)
        return d + (10 - d) * deltaD / 9
    }

    func stabilityAfterSuccess(lastS: Double, lastD: Double, r: Double, rating: Double) -> Double {
        let hardPenalty = rating == 2 ? w[15] : 1
        let easyBonus = rating == 4 ? w[16] : 1
        return lastS * (exp(w[8]) * (11 - lastD) * pow(lastS, -w[9]) * (exp((1 - r) * w[10]) - 1)
            * hardPenalty * easyBonus + 1)
    }

    func stabilityAfterFailure(lastS: Double, lastD: Double, r: Double) -> Double {
        let newS = w[11] * pow(lastD, -w[12]) * (pow(lastS + 1, w[13]) - 1) * exp((1 - r) * w[14])
        return min(newS, lastS / exp(w[17] * w[18]))
    }

    func stabilityShortTerm(lastS: Double, rating: Double) -> Double {
        let sinc = exp(w[17] * (rating - 3 + w[18])) * pow(lastS, -w[19])
        return lastS * (rating >= 2 ? max(sinc, 1) : sinc)
    }

    func step(deltaT: Double, rating: Double, state: MemoryState, nth: Int) -> MemoryState {
        let lastS = min(max(state.stability, Self.sMin), Self.sMax)
        let lastD = min(max(state.difficulty, Self.dMin), Self.dMax)
        let r = retrievability(daysElapsed: deltaT, stability: lastS)
        var newS = rating == 1
            ? stabilityAfterFailure(lastS: lastS, lastD: lastD, r: r)
            : stabilityAfterSuccess(lastS: lastS, lastD: lastD, r: r, rating: rating)
        if deltaT == 0 {
            newS = stabilityShortTerm(lastS: lastS, rating: rating)
        }
        var newD = min(max(meanReversion(nextDifficulty(lastD, rating: rating)), Self.dMin), Self.dMax)
        if nth == 0 && state.stability == 0 {
            let initRating = min(max(Int(rating), 1), 4)
            newS = initStability(initRating)
            newD = min(max(initDifficulty(initRating), Self.dMin), Self.dMax)
        }
        if rating == 0 {
            newS = lastS
            newD = lastD
        }
        return MemoryState(stability: min(max(newS, Self.sMin), Self.sMax), difficulty: newD)
    }
}
