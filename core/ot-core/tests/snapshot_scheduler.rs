//! Snapshots of Anki's scheduler on the scenarios in tests/data/scheduler/scenarios.json: each
//! step answers the card the previous step left, at a time relative to its due. After an
//! intended change, review the new snapshots with `cargo insta review`.

mod common;

use std::fmt::Write;

use ot_core::chess::Epd;
use ot_core::training::anki::{
    Card, CardQueue, CardState, DeckConfig, IntervalKind, LeechAction, MemoryState, Rating,
    SchedTiming, Scheduler,
};
use serde_json::Value;

const DAY: i64 = 86_400;

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

/// FSRS runs in f32 with the platform's math functions: 4 decimals are stable everywhere.
fn memory(m: Option<MemoryState>) -> String {
    m.map_or("-".into(), |m| {
        format!("s {:.4} d {:.4}", m.stability, m.difficulty)
    })
}

fn interval(k: IntervalKind) -> String {
    match k {
        IntervalKind::Secs(s) if s % 60 == 0 => format!("{}m", s / 60),
        IntervalKind::Secs(s) => format!("{s}s"),
        IntervalKind::Days(d) => format!("{d}d"),
    }
}

fn state(s: &CardState) -> String {
    let kind = match s {
        CardState::New(_) => "new",
        CardState::Learning(_) => "learning",
        CardState::Review(_) => "review",
        CardState::Relearning(_) => "relearning",
    };
    let leech = if s.leeched() { " leech" } else { "" };
    format!("{kind} {}{leech}", interval(s.interval_kind()))
}

fn card(c: &Card) -> String {
    format!(
        "{:?}/{:?} due {} ivl {} ease {} reps {} lapses {} left {} {}{}",
        c.ctype,
        c.queue,
        c.due,
        c.interval,
        c.ease_factor,
        c.reps,
        c.lapses,
        c.remaining_steps,
        memory(c.memory),
        if c.leech == Some(true) { " leech" } else { "" },
    )
}

/// When the step answers: at a fixed day and time, or relative to the card's due (seconds
/// for the learn queue, days at a time of day otherwise).
fn timing(step: &Value, before: Option<&Card>, t0: i64) -> SchedTiming {
    let now = if let Some(at) = step.get("at") {
        t0 + at["day"].as_i64().unwrap() * DAY + at["secs"].as_i64().unwrap()
    } else {
        let card = before.expect("a card to answer after its due");
        let after = &step["afterDue"];
        let secs = after["secs"].as_i64().unwrap();
        if card.queue == CardQueue::Learn {
            card.due + secs
        } else {
            t0 + (card.due + after["days"].as_i64().unwrap()) * DAY + secs
        }
    };
    let day = (now - t0).div_euclid(DAY);
    SchedTiming::new(day, t0 + (day + 1) * DAY, now)
}

#[test]
fn scenarios() {
    let data = common::data_json("scheduler/scenarios.json");
    let t0 = data["t0"].as_i64().unwrap();
    for scenario in data["scenarios"].as_array().unwrap() {
        let mut config_json = data["baseConfig"].clone();
        if let Some(overrides) = scenario["config"].as_object() {
            for (k, v) in overrides {
                config_json[k] = v.clone();
            }
        }
        let scheduler = Scheduler::new(config(&config_json));
        let epd = Epd::new(scenario["epd"].as_str().unwrap());
        let id = scenario["cardId"].as_i64().unwrap();
        let mut current: Option<Card> = scenario
            .get("start")
            .map(|c| serde_json::from_value(c.clone()).unwrap());
        let mut out = String::new();
        if let Some(c) = &current {
            writeln!(out, "start: {}", card(c)).unwrap();
        }
        for (i, step) in scenario["steps"].as_array().unwrap().iter().enumerate() {
            let t = timing(step, current.as_ref(), t0);
            let filtered = step["filtered"] == true;
            let position = step["position"].as_i64().unwrap_or(0);
            let rating = if step["rating"] == "again" {
                Rating::Again
            } else {
                Rating::Good
            };
            let next = scheduler.next_states(current.as_ref(), id, position, &t, filtered);
            let answer = scheduler.answer(
                current.as_ref(),
                &epd,
                position,
                rating,
                &t,
                filtered,
                step["takenMillis"].as_i64().unwrap_or(4000),
                None,
            );
            let r = &answer.revlog;
            writeln!(
                out,
                "{i}: day {} +{}s {rating:?}{} from {:?}\n   next: again {} | hard {} | good {} | easy {}\n   card: {}\n   revlog: {:?} ease {} ivl {} last {} factor {} time {}{}",
                t.days_elapsed,
                t.now - t0 - t.days_elapsed * DAY,
                if filtered { " filtered" } else { "" },
                answer.from_queue,
                state(&next.again),
                state(&next.hard),
                state(&next.good),
                state(&next.easy),
                card(&answer.card),
                r.kind,
                r.ease,
                r.ivl,
                r.last_ivl,
                r.factor,
                r.time,
                if answer.leeched { "\n   leeched" } else { "" },
            )
            .unwrap();
            current = Some(answer.card);
        }
        insta::assert_snapshot!(scenario["name"].as_str().unwrap(), out);
    }
}
