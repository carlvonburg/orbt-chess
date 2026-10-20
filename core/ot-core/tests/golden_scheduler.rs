//! Anki's scheduler in Rust against core/fixtures/scheduler/answers.json from the Swift core.
//!
//! Each step starts from the Swift card before the answer, so a difference does not carry
//! into later steps. FSRS runs in f32 in the fsrs crate and in f64 in the Swift copy, so
//! memory states and the revlog factor are compared with a tolerance (core/fixtures/README.md).

mod golden;

use ot_core::chess::Epd;
use ot_core::training::anki::{
    Card, CardState, DeckConfig, IntervalKind, LeechAction, Rating, SchedTiming, Scheduler,
};
use serde_json::{Value, json};

fn config(v: &Value) -> DeckConfig {
    let f = |k: &str| v[k].as_f64().unwrap();
    let i = |k: &str| v[k].as_i64().unwrap();
    let steps = |k: &str| -> Vec<f64> {
        v[k].as_array()
            .unwrap()
            .iter()
            .map(|s| s.as_f64().unwrap())
            .collect()
    };
    DeckConfig {
        new_per_day: i("newPerDay"),
        reviews_per_day: i("reviewsPerDay"),
        new_cards_ignore_review_limit: v["newCardsIgnoreReviewLimit"] == true,
        learn_steps: steps("learnSteps"),
        relearn_steps: steps("relearnSteps"),
        graduating_interval_good: i("graduatingIntervalGood"),
        graduating_interval_easy: i("graduatingIntervalEasy"),
        initial_ease: f("initialEase"),
        easy_multiplier: f("easyMultiplier"),
        hard_multiplier: f("hardMultiplier"),
        lapse_multiplier: f("lapseMultiplier"),
        interval_multiplier: f("intervalMultiplier"),
        maximum_review_interval: i("maximumReviewInterval"),
        minimum_lapse_interval: i("minimumLapseInterval"),
        leech_threshold: i("leechThreshold"),
        leech_action: if v["leechAction"] == "suspend" {
            LeechAction::Suspend
        } else {
            LeechAction::TagOnly
        },
        desired_retention: f("desiredRetention"),
        cap_answer_time_to_secs: i("capAnswerTimeToSecs"),
        learn_ahead_secs: i("learnAheadSecs"),
        fsrs_short_term_with_steps_enabled: v["fsrsShortTermWithStepsEnabled"] == true,
    }
}

fn memory_json(m: Option<ot_core::training::anki::MemoryState>) -> Value {
    m.map_or(
        Value::Null,
        |m| json!({"stability": m.stability, "difficulty": m.difficulty}),
    )
}

fn state_json(s: &CardState) -> Value {
    let kind = match s.interval_kind() {
        IntervalKind::Secs(secs) => json!({"secs": secs}),
        IntervalKind::Days(days) => json!({"days": days}),
    };
    let mut v = json!({
        "intervalKind": kind,
        "revlogKind": i64::from(s.revlog_kind()),
        "leeched": s.leeched(),
    });
    let learning = |l: &ot_core::training::anki::LearnState| {
        json!({"remainingSteps": l.remaining_steps, "scheduledSecs": l.scheduled_secs,
               "elapsedSecs": l.elapsed_secs, "memory": memory_json(l.memory)})
    };
    let review = |r: &ot_core::training::anki::ReviewState| {
        json!({"scheduledDays": r.scheduled_days, "elapsedDays": r.elapsed_days,
               "easeFactor": r.ease_factor, "lapses": r.lapses, "leeched": r.leeched,
               "memory": memory_json(r.memory)})
    };
    let o = v.as_object_mut().unwrap();
    match s {
        CardState::New(n) => {
            o.insert("kind".into(), json!("new"));
            o.insert("position".into(), json!(n.position));
        }
        CardState::Learning(l) => {
            o.insert("kind".into(), json!("learning"));
            o.insert("learning".into(), learning(l));
        }
        CardState::Review(r) => {
            o.insert("kind".into(), json!("review"));
            o.insert("review".into(), review(r));
        }
        CardState::Relearning(r) => {
            o.insert("kind".into(), json!("relearning"));
            o.insert("learning".into(), learning(&r.learning));
            o.insert("review".into(), review(&r.review));
        }
    }
    v
}

/// Tolerance for values that pass through FSRS (f32 in Rust, f64 in Swift).
const FSRS_TOL: f64 = 2e-5;

/// Splits a value into what FSRS touches (memory, revlog factor) and the rest; the rest
/// must match exactly.
fn without_fsrs(v: &Value) -> Value {
    match v {
        Value::Object(map) => Value::Object(
            map.iter()
                .map(|(k, x)| {
                    let x = if k == "memory" && !x.is_null() {
                        json!("<memory>")
                    } else {
                        without_fsrs(x)
                    };
                    (k.clone(), x)
                })
                .collect(),
        ),
        Value::Array(a) => Value::Array(a.iter().map(without_fsrs).collect()),
        other => other.clone(),
    }
}

#[test]
fn answers_match_swift() {
    let fixture = golden::json("scheduler/answers.json");
    let mut rebased = fixture.clone();
    let mut steps_checked = 0;
    let mut factor_diffs = 0;
    for (si, scenario) in fixture["scenarios"].as_array().unwrap().iter().enumerate() {
        let name = scenario["name"].as_str().unwrap();
        let scheduler = Scheduler::new(config(&scenario["config"]));
        let epd = Epd::new(scenario["epd"].as_str().unwrap());
        let id = scenario["cardID"].as_i64().unwrap();
        for (i, step) in scenario["steps"].as_array().unwrap().iter().enumerate() {
            let label = format!("{name} step {i}");
            let before: Option<Card> = (!step["before"].is_null())
                .then(|| serde_json::from_value(step["before"].clone()).unwrap());
            let t = &step["timing"];
            let timing = SchedTiming::new(
                t["daysElapsed"].as_i64().unwrap(),
                t["nextDayAt"].as_i64().unwrap(),
                t["now"].as_i64().unwrap(),
            );
            let filtered = step["filtered"] == true;
            let position = step["position"].as_i64().unwrap();
            let rating = Rating::try_from(step["rating"].as_i64().unwrap()).unwrap();

            let states = scheduler.next_states(before.as_ref(), id, position, &timing, filtered);
            let actual_states = json!({
                "current": state_json(&states.current), "again": state_json(&states.again),
                "hard": state_json(&states.hard), "good": state_json(&states.good),
                "easy": state_json(&states.easy),
            });
            let answer = scheduler.answer(
                before.as_ref(),
                &epd,
                position,
                rating,
                &timing,
                filtered,
                step["takenMillis"].as_i64().unwrap(),
                None,
            );
            let actual = json!({
                "nextStates": actual_states,
                "card": serde_json::to_value(&answer.card).unwrap(),
                "revlog": serde_json::to_value(&answer.revlog).unwrap(),
                "fromQueue": i64::from(answer.from_queue),
                "leeched": answer.leeched,
            });
            let mut expected = json!({
                "nextStates": step["nextStates"], "card": step["card"], "revlog": step["revlog"],
                "fromQueue": step["fromQueue"], "leeched": step["leeched"],
            });
            if golden::rebasing() {
                for (k, v) in actual.as_object().unwrap() {
                    rebased["scenarios"][si]["steps"][i][k] = v.clone();
                }
                continue;
            }
            // The revlog factor is the FSRS difficulty ×1000, rounded: allow ±1.
            let (ef, af) = (&expected["revlog"]["factor"], &actual["revlog"]["factor"]);
            if ef != af {
                assert!(
                    (ef.as_i64().unwrap() - af.as_i64().unwrap()).abs() <= 1,
                    "{label} factor"
                );
                factor_diffs += 1;
                expected["revlog"]["factor"] = af.clone();
            }
            golden::assert_same(
                &label,
                &without_fsrs(&expected),
                &without_fsrs(&actual),
                0.0,
            );
            golden::assert_same(&label, &expected, &actual, FSRS_TOL);
            steps_checked += 1;
        }
    }
    if golden::rebasing() {
        golden::write_json("scheduler/answers.json", &rebased);
        return;
    }
    println!("{steps_checked} steps; revlog factor off by one in {factor_diffs}");
    assert!(steps_checked > 100);
}
