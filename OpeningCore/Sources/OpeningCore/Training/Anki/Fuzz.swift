// Ported from Anki, rslib/src/scheduler/states/fuzz.rs and the fuzz parts of
// rslib/src/scheduler/answering/{mod,learning}.rs (https://github.com/ankitects/anki).
// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// Differences: Anki draws the fuzz factor from ChaCha12 (`StdRng`); this uses SplitMix64 with
// the same seed (card id + reps), so the ranges match but the chosen day can differ. Anki's
// load balancer is not ported; Anki falls back to this plain fuzz without it.

import Foundation

private struct FuzzRange {
    let start: Double
    let end: Double
    let factor: Double
}

private let fuzzRanges = [
    FuzzRange(start: 2.5, end: 7.0, factor: 0.15),
    FuzzRange(start: 7.0, end: 20.0, factor: 0.1),
    FuzzRange(start: 20.0, end: .greatestFiniteMagnitude, factor: 0.05),
]

func withReviewFuzz(_ fuzzFactor: Double?, _ interval: Double, minimum: Int, maximum: Int) -> Int {
    if let fuzzFactor {
        let (lower, upper) = constrainedFuzzBounds(interval, minimum: minimum, maximum: maximum)
        return Int((Double(lower) + fuzzFactor * Double(1 + upper - lower)).rounded(.down))
    }
    return min(max(roundedInt(interval), minimum), maximum)
}

/// The minimum interval when fuzzing a review interval, based on the previous interval.
func minimumReviewFuzzInterval(_ interval: Double, previous: Int, maximum: Int) -> Int {
    let rounded = roundedInt(interval)
    let (_, upper) = constrainedFuzzBounds(interval, minimum: 1, maximum: maximum)
    if rounded > previous {
        return previous + 1
    } else if previous <= upper {
        // the interval may not have grown much, but fuzz must not reduce it
        return previous
    }
    // interval shrunk, possibly due to changed FSRS params or desired retention
    return 0
}

/// Bounds of the fuzz range within `minimum...maximum`; upper > lower when possible.
func constrainedFuzzBounds(_ interval: Double, minimum: Int, maximum: Int) -> (Int, Int) {
    let minimum = min(minimum, maximum)
    let interval = min(max(interval, Double(minimum)), Double(maximum))
    var (lower, upper) = fuzzBounds(interval)
    lower = min(max(lower, minimum), maximum)
    upper = min(max(upper, minimum), maximum)
    if upper == lower && upper > 2 && upper < maximum {
        upper = lower + 1
    }
    return (lower, upper)
}

func fuzzBounds(_ interval: Double) -> (Int, Int) {
    let delta = fuzzDelta(interval)
    return (roundedInt(interval - delta), roundedInt(interval + delta))
}

/// Short intervals are not fuzzed; others by 1 day plus a share of their days in each range.
private func fuzzDelta(_ interval: Double) -> Double {
    guard interval >= 2.5 else { return 0 }
    return fuzzRanges.reduce(1.0) { delta, range in
        delta + range.factor * max(min(interval, range.end) - range.start, 0)
    }
}

/// Rust `f32 as u32`: rounds half away from zero, saturates at 0.
func roundedInt(_ value: Double) -> Int {
    guard value.isFinite else { return 0 }
    return max(0, Int(value.rounded()))
}

// MARK: Seeds

/// Anki: card id + reps, so a card gets the same fuzz for the same answer.
func fuzzSeed(cardID: Int64, reps: Int) -> UInt64 {
    UInt64(bitPattern: cardID) &+ UInt64(max(0, reps))
}

/// A fuzz factor in `0..<1` from a seed.
func fuzzFactor(seed: UInt64?) -> Double? {
    guard let seed else { return nil }
    var rng = SplitMix64(seed: seed)
    return rng.nextUnit()
}

/// Adds up to 25% to a learning delay, but no more than 5 minutes.
func learningIntervalWithFuzz(seed: UInt64?, _ secs: Int) -> Int {
    guard let seed else { return secs }
    let upperExclusive = secs + Int(min(Double(secs) * 0.25, 300).rounded(.down))
    guard secs < upperExclusive else { return secs }
    var rng = SplitMix64(seed: seed)
    return secs + Int(rng.next() % UInt64(upperExclusive - secs))
}

struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextUnit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
