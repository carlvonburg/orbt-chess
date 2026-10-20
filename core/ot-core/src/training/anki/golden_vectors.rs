//! core/fixtures/scheduler/vectors.json: unit vectors recorded from the Swift scheduler.

use serde_json::Value;

use super::fuzz::{
    constrained_fuzz_bounds, fuzz_factor, fuzz_seed, learning_interval_with_fuzz,
    minimum_review_fuzz_interval, with_review_fuzz,
};
use super::interval_kind::IntervalKind;
use super::states::leech_threshold_met;
use super::{LearningSteps, Scheduler};

fn vectors() -> Value {
    // At run time, so the tests still find the fixtures after the checkout moved.
    let crate_dir =
        std::env::var("CARGO_MANIFEST_DIR").unwrap_or_else(|_| env!("CARGO_MANIFEST_DIR").into());
    let path = format!("{crate_dir}/../fixtures/scheduler/vectors.json");
    serde_json::from_slice(&std::fs::read(path).expect("fixture")).expect("JSON")
}

fn list<'a>(v: &'a Value, key: &str) -> &'a Vec<Value> {
    v[key].as_array().unwrap_or_else(|| panic!("{key}"))
}

fn seed(v: &Value) -> u64 {
    v.as_str().unwrap().parse().unwrap()
}

fn opt(v: &Value) -> Option<i64> {
    v.as_i64()
}

fn kind(v: &Value) -> IntervalKind {
    match (v.get("secs"), v.get("days")) {
        (Some(s), _) => IntervalKind::Secs(s.as_i64().unwrap()),
        (_, Some(d)) => IntervalKind::Days(d.as_i64().unwrap()),
        _ => panic!("interval kind {v}"),
    }
}

#[test]
fn fuzz_vectors_match_swift_given_the_draws() {
    let v = vectors();
    // The random draws come from Anki's StdRng, not the Swift build's generator: only check
    // that they stay in range.
    for case in list(&v, "fuzzFactor") {
        let f = fuzz_factor(Some(seed(&case["seed"]))).unwrap();
        assert!((0.0..1.0).contains(&f), "{case}");
    }
    for case in list(&v, "fuzzSeed") {
        let s = fuzz_seed(
            case["cardID"].as_i64().unwrap(),
            case["reps"].as_i64().unwrap(),
        );
        assert_eq!(s, seed(&case["seed"]), "{case}");
    }
    for case in list(&v, "learningIntervalWithFuzz") {
        let secs = case["secs"].as_i64().unwrap();
        let r = learning_interval_with_fuzz(Some(seed(&case["seed"])), secs);
        let upper = secs + (secs as f64 * 0.25).min(300.0).floor() as i64;
        assert!(r == secs || (secs..upper).contains(&r), "{case}");
    }
    for case in list(&v, "review") {
        let interval = case["interval"].as_f64().unwrap();
        if let Some(previous) = case.get("previous") {
            let r = minimum_review_fuzz_interval(
                interval,
                previous.as_i64().unwrap(),
                case["maximum"].as_i64().unwrap(),
            );
            assert_eq!(
                r,
                case["minimumReviewFuzzInterval"].as_i64().unwrap(),
                "{case}"
            );
            continue;
        }
        let (min, max) = (
            case["minimum"].as_i64().unwrap(),
            case["maximum"].as_i64().unwrap(),
        );
        let (lo, hi) = constrained_fuzz_bounds(interval, min, max);
        assert_eq!(serde_json::json!([lo, hi]), case["bounds"], "{case}");
        assert_eq!(
            with_review_fuzz(None, interval, min, max),
            case["noFuzz"].as_i64().unwrap()
        );
        for f in list(case, "fuzz") {
            let r = with_review_fuzz(f["factor"].as_f64(), interval, min, max);
            assert_eq!(r, f["result"].as_i64().unwrap(), "{case} {f}");
        }
    }
}

#[test]
fn steps_intervals_and_leeches_match_swift() {
    let v = vectors();
    for case in list(&v, "learningSteps") {
        let steps: Vec<f64> = list(case, "steps")
            .iter()
            .map(|s| s.as_f64().unwrap())
            .collect();
        let s = LearningSteps::new(&steps);
        let r = case["remaining"].as_i64().unwrap();
        assert_eq!(s.again_delay_secs_learn(), opt(&case["again"]), "{case}");
        assert_eq!(s.hard_delay_secs(r), opt(&case["hard"]), "{case}");
        assert_eq!(s.good_delay_secs(r), opt(&case["good"]), "{case}");
        assert_eq!(
            s.current_delay_secs(r),
            case["current"].as_i64().unwrap(),
            "{case}"
        );
        assert_eq!(
            s.remaining_for_good(r),
            case["remainingForGood"].as_i64().unwrap()
        );
        assert_eq!(
            s.remaining_for_failed(),
            case["remainingForFailed"].as_i64().unwrap()
        );
    }
    for case in list(&v, "intervalKind") {
        let converted =
            kind(&case["kind"]).maybe_as_days(case["secsUntilRollover"].as_i64().unwrap());
        assert_eq!(converted, kind(&case["converted"]), "{case}");
        assert_eq!(
            converted.as_revlog_interval(),
            case["revlog"].as_i64().unwrap(),
            "{case}"
        );
    }
    for case in list(&v, "leechThreshold") {
        let met = leech_threshold_met(
            case["lapses"].as_i64().unwrap(),
            case["threshold"].as_i64().unwrap(),
        );
        assert_eq!(serde_json::json!(met), case["met"], "{case}");
    }
}

/// FSRS: the fsrs crate computes in f32, the Swift copy in f64 (core/fixtures/README.md).
#[test]
fn fsrs_matches_swift_within_f32() {
    let v = vectors();
    let close = |a: f64, b: f64| (a - b).abs() <= 2e-5 * a.abs().max(b.abs()).max(1.0);
    for case in list(&v, "fsrsNextStates") {
        let memory = (!case["memory"].is_null()).then(|| super::MemoryState {
            stability: case["memory"]["stability"].as_f64().unwrap(),
            difficulty: case["memory"]["difficulty"].as_f64().unwrap(),
        });
        let next = Scheduler::default().fsrs_next_states_for_test(
            memory,
            case["desiredRetention"].as_f64().unwrap(),
            case["daysElapsed"].as_i64().unwrap(),
        );
        for (name, item) in [
            ("again", next.again),
            ("hard", next.hard),
            ("good", next.good),
            ("easy", next.easy),
        ] {
            let e = &case[name];
            assert!(
                close(item.interval, e["interval"].as_f64().unwrap()),
                "{name} interval {case}"
            );
            assert!(
                close(
                    item.memory.stability,
                    e["memory"]["stability"].as_f64().unwrap()
                ),
                "{name} {case}"
            );
            assert!(
                close(
                    item.memory.difficulty,
                    e["memory"]["difficulty"].as_f64().unwrap()
                ),
                "{name} {case}"
            );
        }
    }
    for case in list(&v, "retrievability") {
        let card = super::Card {
            memory: Some(super::MemoryState {
                stability: case["stability"].as_f64().unwrap(),
                difficulty: 5.0,
            }),
            last_review_time: Some(0),
            ..super::Card::new(1, 0, 0)
        };
        let r = card
            .retrievability(case["days"].as_f64().unwrap() * 86_400.0)
            .unwrap();
        assert!(close(r, case["r"].as_f64().unwrap()), "{case}");
    }
}
