//! Snapshots of the scheduler's building blocks on the inputs in
//! tests/data/scheduler/vectors.json: fuzz, learning steps, interval kinds, leeches, FSRS.
//! After an intended change, review the new snapshots with `cargo insta review`.

use std::fmt::Write;

use serde_json::Value;

use super::fuzz::{
    constrained_fuzz_bounds, fuzz_factor, fuzz_seed, learning_interval_with_fuzz,
    minimum_review_fuzz_interval, with_review_fuzz,
};
use super::interval_kind::IntervalKind;
use super::states::leech_threshold_met;
use super::{Card, LearningSteps, MemoryState, Scheduler};

fn vectors() -> Value {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/tests/data/scheduler/vectors.json"
    );
    serde_json::from_slice(&std::fs::read(path).expect("vectors.json")).expect("JSON")
}

fn list<'a>(v: &'a Value, key: &str) -> &'a Vec<Value> {
    v[key].as_array().unwrap_or_else(|| panic!("{key}"))
}

fn kind(v: &Value) -> IntervalKind {
    match (v.get("secs"), v.get("days")) {
        (Some(s), _) => IntervalKind::Secs(s.as_i64().unwrap()),
        (_, Some(d)) => IntervalKind::Days(d.as_i64().unwrap()),
        _ => panic!("interval kind {v}"),
    }
}

#[test]
fn fuzz() {
    let v = vectors();
    let mut out = String::new();
    writeln!(out, "fuzz factor and learning delays by seed:").unwrap();
    for seed in list(&v, "seeds") {
        let seed: u64 = seed.as_str().unwrap().parse().unwrap();
        let delays: Vec<i64> = list(&v, "learningIntervalSecs")
            .iter()
            .map(|s| learning_interval_with_fuzz(Some(seed), s.as_i64().unwrap()))
            .collect();
        let factor = fuzz_factor(Some(seed)).unwrap();
        writeln!(out, "  {seed}: {factor:.6} {delays:?}").unwrap();
    }
    writeln!(out, "seeds:").unwrap();
    for case in list(&v, "fuzzSeed") {
        let (id, reps) = (
            case["cardID"].as_i64().unwrap(),
            case["reps"].as_i64().unwrap(),
        );
        writeln!(out, "  card {id} reps {reps}: {}", fuzz_seed(id, reps)).unwrap();
    }
    let factors: Vec<f64> = list(&v, "fuzzFactors")
        .iter()
        .map(|f| f.as_f64().unwrap())
        .collect();
    writeln!(
        out,
        "review intervals (bounds, no fuzz, fuzzed at {factors:?}):"
    )
    .unwrap();
    for case in list(&v, "review") {
        let interval = case["interval"].as_f64().unwrap();
        let maximum = case["maximum"].as_i64().unwrap();
        if let Some(previous) = case.get("previous") {
            let previous = previous.as_i64().unwrap();
            let m = minimum_review_fuzz_interval(interval, previous, maximum);
            writeln!(
                out,
                "  {interval} after {previous} max {maximum}: minimum {m}"
            )
            .unwrap();
            continue;
        }
        let minimum = case["minimum"].as_i64().unwrap();
        let bounds = constrained_fuzz_bounds(interval, minimum, maximum);
        let fuzzed: Vec<i64> = factors
            .iter()
            .map(|&f| with_review_fuzz(Some(f), interval, minimum, maximum))
            .collect();
        writeln!(
            out,
            "  {interval} in {minimum}..{maximum}: {bounds:?} {} {fuzzed:?}",
            with_review_fuzz(None, interval, minimum, maximum)
        )
        .unwrap();
    }
    insta::assert_snapshot!(out);
}

#[test]
fn steps_intervals_and_leeches() {
    let v = vectors();
    let mut out = String::new();
    writeln!(
        out,
        "learning steps (again, hard, good, current, left after good, after again):"
    )
    .unwrap();
    for case in list(&v, "learningSteps") {
        let steps: Vec<f64> = list(case, "steps")
            .iter()
            .map(|s| s.as_f64().unwrap())
            .collect();
        let s = LearningSteps::new(&steps);
        let r = case["remaining"].as_i64().unwrap();
        writeln!(
            out,
            "  {steps:?} remaining {r}: {:?} {:?} {:?} {} {} {}",
            s.again_delay_secs_learn(),
            s.hard_delay_secs(r),
            s.good_delay_secs(r),
            s.current_delay_secs(r),
            s.remaining_for_good(r),
            s.remaining_for_failed()
        )
        .unwrap();
    }
    writeln!(out, "interval kinds (as days, revlog):").unwrap();
    for case in list(&v, "intervalKind") {
        let k = kind(&case["kind"]);
        let rollover = case["secsUntilRollover"].as_i64().unwrap();
        let converted = k.maybe_as_days(rollover);
        writeln!(
            out,
            "  {k:?} rollover in {rollover}s: {converted:?} {}",
            converted.as_revlog_interval()
        )
        .unwrap();
    }
    writeln!(out, "leech threshold met:").unwrap();
    for case in list(&v, "leechThreshold") {
        let (lapses, threshold) = (
            case["lapses"].as_i64().unwrap(),
            case["threshold"].as_i64().unwrap(),
        );
        writeln!(
            out,
            "  {lapses} lapses, threshold {threshold}: {}",
            leech_threshold_met(lapses, threshold)
        )
        .unwrap();
    }
    insta::assert_snapshot!(out);
}

/// FSRS runs in f32 with the platform's math functions: 4 decimals are stable everywhere.
#[test]
fn fsrs() {
    let v = vectors();
    let mut out = String::new();
    writeln!(
        out,
        "next states (interval, stability, difficulty) for again | hard | good | easy:"
    )
    .unwrap();
    for case in list(&v, "fsrsNextStates") {
        let memory = (!case["memory"].is_null()).then(|| MemoryState {
            stability: case["memory"]["stability"].as_f64().unwrap(),
            difficulty: case["memory"]["difficulty"].as_f64().unwrap(),
        });
        let retention = case["desiredRetention"].as_f64().unwrap();
        let days = case["daysElapsed"].as_i64().unwrap();
        let next = Scheduler::default().fsrs_next_states_for_test(memory, retention, days);
        let items: Vec<String> = [next.again, next.hard, next.good, next.easy]
            .iter()
            .map(|i| {
                format!(
                    "{:.4} {:.4} {:.4}",
                    i.interval, i.memory.stability, i.memory.difficulty
                )
            })
            .collect();
        let m = memory.map_or("new".into(), |m| {
            format!("s {} d {}", m.stability, m.difficulty)
        });
        writeln!(
            out,
            "  {m}, retention {retention}, {days} days: {}",
            items.join(" | ")
        )
        .unwrap();
    }
    writeln!(out, "retrievability:").unwrap();
    for case in list(&v, "retrievability") {
        let stability = case["stability"].as_f64().unwrap();
        let days = case["days"].as_f64().unwrap();
        let card = Card {
            memory: Some(MemoryState {
                stability,
                difficulty: 5.0,
            }),
            last_review_time: Some(0),
            ..Card::new(1, 0, 0)
        };
        let r = card.retrievability(days * 86_400.0).unwrap();
        writeln!(out, "  stability {stability} after {days} days: {r:.6}").unwrap();
    }
    insta::assert_snapshot!(out);
}
