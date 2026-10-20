// Ported from Anki, rslib/src/scheduler/states/fuzz.rs and the fuzz parts of
// rslib/src/scheduler/answering/{mod,learning}.rs (https://github.com/ankitects/anki).
// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// Differences: Anki's load balancer is not ported; Anki falls back to this plain fuzz without it.

use rand::prelude::*;
use rand::rngs::StdRng;

struct FuzzRange {
    start: f64,
    end: f64,
    factor: f64,
}

const FUZZ_RANGES: [FuzzRange; 3] = [
    FuzzRange {
        start: 2.5,
        end: 7.0,
        factor: 0.15,
    },
    FuzzRange {
        start: 7.0,
        end: 20.0,
        factor: 0.1,
    },
    FuzzRange {
        start: 20.0,
        end: f64::MAX,
        factor: 0.05,
    },
];

pub(crate) fn with_review_fuzz(
    fuzz_factor: Option<f64>,
    interval: f64,
    minimum: i64,
    maximum: i64,
) -> i64 {
    match fuzz_factor {
        Some(factor) => {
            let (lower, upper) = constrained_fuzz_bounds(interval, minimum, maximum);
            // f32 as in Anki, so the floor lands on the same day.
            (lower as f32 + factor as f32 * (1 + upper - lower) as f32).floor() as i64
        }
        None => rounded_int(interval).max(minimum).min(maximum),
    }
}

/// The minimum interval when fuzzing a review interval, based on the previous interval.
pub(crate) fn minimum_review_fuzz_interval(interval: f64, previous: i64, maximum: i64) -> i64 {
    let rounded = rounded_int(interval);
    let (_, upper) = constrained_fuzz_bounds(interval, 1, maximum);
    if rounded > previous {
        previous + 1
    } else if previous <= upper {
        // the interval may not have grown much, but fuzz must not reduce it
        previous
    } else {
        // interval shrunk, possibly due to changed FSRS params or desired retention
        0
    }
}

/// Bounds of the fuzz range within `minimum..=maximum`; upper > lower when possible.
pub(crate) fn constrained_fuzz_bounds(interval: f64, minimum: i64, maximum: i64) -> (i64, i64) {
    let minimum = minimum.min(maximum);
    let interval = interval.max(minimum as f64).min(maximum as f64);
    let (lower, upper) = fuzz_bounds(interval);
    let lower = lower.max(minimum).min(maximum);
    let mut upper = upper.max(minimum).min(maximum);
    if upper == lower && upper > 2 && upper < maximum {
        upper = lower + 1;
    }
    (lower, upper)
}

pub(crate) fn fuzz_bounds(interval: f64) -> (i64, i64) {
    let delta = fuzz_delta(interval);
    (rounded_int(interval - delta), rounded_int(interval + delta))
}

/// Short intervals are not fuzzed; others by 1 day plus a share of their days in each range.
fn fuzz_delta(interval: f64) -> f64 {
    if interval < 2.5 {
        return 0.0;
    }
    FUZZ_RANGES.iter().fold(1.0, |delta, range| {
        delta + range.factor * (interval.min(range.end) - range.start).max(0.0)
    })
}

/// Rust `f32 as u32` in Anki: rounds half away from zero, saturates at 0.
pub(crate) fn rounded_int(value: f64) -> i64 {
    if !value.is_finite() {
        return 0;
    }
    (value.round() as i64).max(0)
}

// Seeds

/// Anki: card id + reps, so a card gets the same fuzz for the same answer.
pub(crate) fn fuzz_seed(card_id: i64, reps: i64) -> u64 {
    (card_id as u64).wrapping_add(reps.max(0) as u64)
}

/// A fuzz factor in `0..1` from a seed.
pub(crate) fn fuzz_factor(seed: Option<u64>) -> Option<f64> {
    seed.map(|s| f64::from(StdRng::seed_from_u64(s).random_range(0.0f32..1.0)))
}

/// Adds up to 25% to a learning delay, but no more than 5 minutes.
pub(crate) fn learning_interval_with_fuzz(seed: Option<u64>, secs: i64) -> i64 {
    let Some(seed) = seed else { return secs };
    let upper_exclusive = secs + (secs as f64 * 0.25).min(300.0).floor() as i64;
    if secs >= upper_exclusive {
        return secs;
    }
    StdRng::seed_from_u64(seed).random_range(secs..upper_exclusive)
}
