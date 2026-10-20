// Test vectors from Anki (rslib/src/scheduler/states/*, queue/builder/intersperser.rs) and
// fsrs-rs, ported from AnkiSchedulerTests.swift. FSRS internals are the fsrs crate's own tests.
// Copyright: Ankitects Pty Ltd and contributors; Open Spaced Repetition.
// License: GNU AGPL, version 3 or later (Anki parts); BSD 3-Clause (fsrs-rs parts).

use std::collections::HashMap;

use super::fuzz::{constrained_fuzz_bounds, minimum_review_fuzz_interval, with_review_fuzz};
use super::queue::intersperse;
use super::states::{StateContext, leech_threshold_met};
use super::*;
use crate::chess::{ChessPosition, Epd};

fn learn(remaining: i64) -> LearnState {
    LearnState {
        remaining_steps: remaining,
        scheduled_secs: 60,
        elapsed_secs: 0,
        memory: None,
    }
}

// steps.rs

#[test]
fn delay_secs() {
    fn check(
        steps: &[f64],
        remaining: i64,
        again: Option<i64>,
        hard: Option<i64>,
        good: Option<i64>,
    ) {
        let s = LearningSteps::new(steps);
        assert_eq!(s.again_delay_secs_learn(), again);
        assert_eq!(s.hard_delay_secs(remaining), hard);
        assert_eq!(s.good_delay_secs(remaining), good);
    }
    let day = 86_400;
    check(&[10.0], 1, Some(600), Some(900), None);
    check(
        &[(3 * day / 60) as f64],
        1,
        Some(3 * day),
        Some(4 * day),
        None,
    );
    check(&[1.0, 10.0], 2, Some(60), Some(330), Some(600));
    check(&[1.0, 10.0], 1, Some(60), Some(600), None);
    check(&[1.0, 10.0, 100.0], 3, Some(60), Some(330), Some(600));
    check(&[1.0, 10.0, 100.0], 2, Some(60), Some(600), Some(6000));
    check(&[1.0, 10.0, 100.0], 1, Some(60), Some(6000), None);
}

// learning.rs

#[test]
fn learning_again_resets_to_first_step() {
    let ctx = StateContext::defaults_for_testing();
    for remaining in [1, 2] {
        let again = learn(remaining).next_states(&ctx).again;
        assert_eq!(
            again,
            CardState::Learning(LearnState {
                remaining_steps: 2,
                ..learn(2)
            })
        );
    }
}

#[test]
fn learning_hard_stays_on_step() {
    let ctx = StateContext::defaults_for_testing();
    let first = learn(2).next_states(&ctx).hard;
    assert_eq!(
        first,
        CardState::Learning(LearnState {
            scheduled_secs: 330,
            ..learn(2)
        })
    );
    let last = learn(1).next_states(&ctx).hard;
    assert_eq!(
        last,
        CardState::Learning(LearnState {
            scheduled_secs: 600,
            ..learn(1)
        })
    );
}

#[test]
fn learning_good_advances_then_graduates() {
    let ctx = StateContext::defaults_for_testing();
    let first = learn(2).next_states(&ctx).good;
    assert_eq!(
        first,
        CardState::Learning(LearnState {
            scheduled_secs: 600,
            ..learn(1)
        })
    );
    let CardState::Review(review) = learn(1).next_states(&ctx).good else {
        panic!("expected review")
    };
    assert_eq!(review.scheduled_days, 1);
}

#[test]
fn learning_easy_graduates_longer_than_good() {
    let ctx = StateContext::defaults_for_testing();
    let states = learn(1).next_states(&ctx);
    let (CardState::Review(easy), CardState::Review(good)) = (states.easy, states.good) else {
        panic!("expected review states")
    };
    assert!(easy.scheduled_days > good.scheduled_days);
}

// fuzz.rs

#[test]
fn with_review_fuzz_vectors() {
    assert_eq!(with_review_fuzz(None, 1.5, 1, 100), 2);
    assert_eq!(with_review_fuzz(None, 0.1, 1, 100), 1);
    assert_eq!(with_review_fuzz(None, 101.0, 1, 100), 100);
    let check = |interval: f64, minimum: i64, maximum: i64, lower: i64, middle: i64, upper: i64| {
        assert_eq!(
            with_review_fuzz(Some(0.0), interval, minimum, maximum),
            lower,
            "{interval}"
        );
        assert_eq!(
            with_review_fuzz(Some(0.5), interval, minimum, maximum),
            middle,
            "{interval}"
        );
        assert_eq!(
            with_review_fuzz(Some(0.99), interval, minimum, maximum),
            upper,
            "{interval}"
        );
    };
    check(1.0, 1, 1000, 1, 1, 1);
    check(2.49, 1, 1000, 2, 2, 2);
    check(2.5, 1, 1000, 2, 3, 4);
    check(7.0, 1, 1000, 5, 7, 9);
    check(17.0, 1, 1000, 14, 17, 20);
    check(37.0, 1, 1000, 33, 37, 41);
    check(2.0, 2, 1000, 2, 2, 2);
    check(2.0, 3, 1000, 3, 4, 4);
    check(2.0, 3, 3, 3, 3, 3);
    check(6.9, 3, 1000, 5, 7, 9);
    check(7.0, 3, 1000, 5, 7, 9);
    check(7.1, 3, 1000, 5, 7, 9);
    check(19.9, 3, 1000, 17, 20, 23);
    check(20.0, 3, 1000, 17, 20, 23);
    check(20.1, 3, 1000, 17, 20, 23);
    check(100.0, 101, 1000, 101, 105, 108);
    check(100.0, 1, 99, 92, 96, 99);
    check(100.0, 97, 103, 97, 100, 103);
    let _ = constrained_fuzz_bounds(1.0, 3, 2); // must not panic
}

#[test]
fn minimum_review_fuzz_interval_vectors() {
    assert_eq!(minimum_review_fuzz_interval(2.7269483, 4, 36500), 4);
    assert_eq!(minimum_review_fuzz_interval(2.7269483, 5, 36500), 0);
    assert_eq!(minimum_review_fuzz_interval(4.591988, 4, 36500), 5);
}

// review.rs

#[test]
fn leech_threshold() {
    let t3: Vec<bool> = (0..=7).map(|l| leech_threshold_met(l, 3)).collect();
    assert_eq!(t3, [false, false, false, true, false, true, false, true]);
    let t8: Vec<bool> = (7..=13).map(|l| leech_threshold_met(l, 8)).collect();
    assert_eq!(t8, [false, true, false, false, false, true, false]);
    assert!(!leech_threshold_met(0, 0));
    let t1: Vec<bool> = (0..=3).map(|l| leech_threshold_met(l, 1)).collect();
    assert_eq!(t1, [false, true, true, true]);
}

#[test]
fn extreme_multiplier_fuzz() {
    let mut ctx = StateContext::defaults_for_testing();
    let state = ReviewState {
        scheduled_days: 1,
        elapsed_days: 1,
        ease_factor: 1.3,
        lapses: 0,
        leeched: false,
        memory: None,
    };
    ctx.fuzz_factor = Some(0.0);
    assert_eq!(state.passing_review_intervals(&ctx), (2, 3, 4));
    ctx.interval_multiplier = 0.1;
    assert_eq!(state.passing_review_intervals(&ctx), (2, 3, 4));
    ctx.fuzz_factor = Some(0.99);
    assert_eq!(state.passing_review_intervals(&ctx), (2, 4, 6));
    ctx.interval_multiplier = 10.0;
    ctx.maximum_review_interval = 5;
    assert_eq!(state.passing_review_intervals(&ctx), (5, 5, 5));
}

// intersperser.rs

#[test]
fn interspersing() {
    let a = || vec![1, 2, 3];
    assert_eq!(intersperse(a(), vec![11, 22, 33]), [1, 11, 2, 22, 3, 33]);
    assert_eq!(intersperse(a(), vec![11, 22]), [1, 11, 2, 22, 3]);
    assert_eq!(
        intersperse(a(), vec![11, 22, 33, 44, 55, 66]),
        [11, 1, 22, 33, 2, 44, 55, 3, 66]
    );
    assert_eq!(
        intersperse(a(), vec![11, 22, 33, 44, 55, 66, 77, 88]),
        [11, 22, 1, 33, 44, 2, 55, 66, 3, 77, 88]
    );
    assert_eq!(intersperse(a(), vec![]), [1, 2, 3]);
}

// fsrs-rs

#[test]
fn fsrs_forgetting_curve() {
    let expected = [1.0, 0.9403443, 0.9253786, 0.9185229, 0.9, 0.8261359];
    let days = [0.0, 1.0, 2.0, 3.0, 4.0, 5.0];
    let stability = [1.0, 2.0, 3.0, 4.0, 4.0, 2.0];
    for i in 0..6 {
        let card = Card {
            memory: Some(MemoryState {
                stability: stability[i],
                difficulty: 5.0,
            }),
            last_review_time: Some(0),
            ..Card::new(1, 0, 0)
        };
        let r = card.retrievability(days[i] * 86_400.0).unwrap();
        assert!((r - expected[i]).abs() < 1e-5, "{r} vs {}", expected[i]);
    }
}

#[test]
fn fsrs_initial_states() {
    let s = Scheduler::default();
    let states = s.next_states(None, 1, 0, &noon(), false);
    let CardState::Learning(again) = states.again else {
        panic!()
    };
    // fsrs w[0], read back as the shortest decimal (as written to the sidecar)
    assert_eq!(again.memory.unwrap().stability, 0.212);
}

// Answering

/// 12:00 on day 100; the day rolls over at 04:00 tomorrow.
fn noon() -> SchedTiming {
    SchedTiming::new(100, 1_000_000 + 16 * 3600, 1_000_000)
}

fn start() -> Epd {
    ChessPosition::start().epd()
}

fn answer(
    card: Option<&Card>,
    position: i64,
    rating: Rating,
    timing: &SchedTiming,
    filtered: bool,
) -> Answer {
    Scheduler::default().answer(card, &start(), position, rating, timing, filtered, 0, None)
}

#[test]
fn new_card_goes_through_steps_then_graduates() {
    let mut timing = noon();
    let first = answer(None, 0, Rating::Good, &timing, false);
    assert!(first.card.queue == CardQueue::Learn && first.card.ctype == CardType::Learn);
    assert_eq!(first.card.remaining_steps, 1);
    // the 10 minute step, plus up to 25% fuzz
    assert!((600..=750).contains(&(first.card.due - timing.now)));
    assert_eq!(first.revlog.kind, RevlogReviewKind::Learning);
    assert_eq!((first.revlog.ivl, first.revlog.last_ivl), (-600, 0));
    assert_eq!(first.from_queue, CardQueue::New);

    timing = SchedTiming::new(100, timing.next_day_at, first.card.due);
    let second = answer(Some(&first.card), 0, Rating::Good, &timing, false);
    assert!(second.card.queue == CardQueue::Review && second.card.ctype == CardType::Review);
    assert!(second.card.interval >= 1);
    assert_eq!(second.card.due, 100 + second.card.interval);
    assert_eq!(second.card.original_position, Some(0));
}

#[test]
fn again_on_new_card_is_one_minute() {
    let a = answer(None, 3, Rating::Again, &noon(), false);
    assert_eq!(a.card.remaining_steps, 2);
    assert!((60..=75).contains(&(a.card.due - noon().now)));
}

fn review_card(interval: i64, due: i64, stability: f64, difficulty: f64, days_ago: i64) -> Card {
    Card {
        ctype: CardType::Review,
        queue: CardQueue::Review,
        interval,
        due,
        ease_factor: 2500,
        memory: Some(MemoryState {
            stability,
            difficulty,
        }),
        last_review_time: Some(noon().now - days_ago * 86_400),
        ..Card::new(1, 0, 0)
    }
}

#[test]
fn lapse_goes_to_relearning_and_back() {
    let card = review_card(10, 100, 10.0, 5.0, 10);
    let lapse = answer(Some(&card), 0, Rating::Again, &noon(), false);
    assert!(lapse.card.ctype == CardType::Relearn && lapse.card.queue == CardQueue::Learn);
    assert_eq!(lapse.card.lapses, 1);
    assert!((600..=750).contains(&(lapse.card.due - noon().now)));
    assert_eq!(lapse.revlog.kind, RevlogReviewKind::Review);
    assert_eq!((lapse.revlog.ease, lapse.revlog.last_ivl), (1, 10));
    assert_eq!(lapse.from_queue, CardQueue::Review);

    let later = SchedTiming::new(100, noon().next_day_at, lapse.card.due);
    let back = answer(Some(&lapse.card), 0, Rating::Good, &later, false);
    assert!(back.card.ctype == CardType::Review && back.card.queue == CardQueue::Review);
    assert_eq!(back.revlog.kind, RevlogReviewKind::Relearning);
}

#[test]
fn learning_step_across_rollover_becomes_days() {
    // 5 minutes before the rollover, a 10 minute step crosses into tomorrow
    let timing = SchedTiming::new(100, 2_000_000, 2_000_000 - 300);
    let a = answer(None, 0, Rating::Good, &timing, false);
    assert_eq!(a.card.queue, CardQueue::DayLearn);
    assert_eq!(a.card.due, 101);
    assert_eq!(a.revlog.ivl, 1);
}

#[test]
fn early_review_is_filtered() {
    let card = review_card(10, 105, 10.0, 5.0, 5);
    let a = answer(Some(&card), 0, Rating::Good, &noon(), true);
    assert_eq!(a.revlog.kind, RevlogReviewKind::Filtered);
    assert!(a.card.interval >= 10);
}

#[test]
fn leech_tag_at_eight_lapses() {
    let card = Card {
        lapses: 7,
        ..review_card(1, 100, 1.0, 9.0, 1)
    };
    let a = answer(Some(&card), 0, Rating::Again, &noon(), false);
    assert!(a.leeched);
    assert_eq!(a.card.leech, Some(true));
    assert_ne!(a.card.queue, CardQueue::Suspended); // Anki's default action: tag only
}

// Queue

fn epd(line: &str) -> Epd {
    let mut p = ChessPosition::start();
    for m in line.split_whitespace() {
        p = p.play_san(m).unwrap().1;
    }
    p.epd()
}

#[test]
fn queue_order_and_counts() {
    let timing = noon();
    let mut cards: HashMap<Epd, Card> = HashMap::new();
    let card = |queue: CardQueue, due: i64| {
        let mut c = Card::new(cards.len() as i64 + 1, 0, 0);
        c.queue = queue;
        c.ctype = if queue == CardQueue::Review {
            CardType::Review
        } else {
            CardType::Learn
        };
        c.due = due;
        c.reps = 1;
        c
    };
    let (learn_now, learn_later, learn_tonight, review, new_card) =
        (epd("e4"), epd("d4"), epd("c4"), epd("Nf3"), epd("g3"));
    let c1 = card(CardQueue::Learn, timing.now - 10);
    let c2 = card(CardQueue::Learn, timing.now + 600);
    let c3 = card(CardQueue::Learn, timing.now + 3 * 3600);
    let c4 = card(CardQueue::Review, 100);
    cards.insert(learn_now.clone(), Card { id: 1, ..c1 });
    cards.insert(learn_later.clone(), Card { id: 2, ..c2 });
    cards.insert(learn_tonight.clone(), Card { id: 3, ..c3 });
    cards.insert(review.clone(), Card { id: 4, ..c4 });
    let limits = RemainingLimits::new(
        &DeckConfig::default(),
        &DeckLimits::default(),
        &DeckStudyStats::default(),
        100,
    );
    let mut queue = CardQueues::new(
        &cards,
        std::slice::from_ref(&new_card),
        limits,
        &timing,
        1200,
        &|_| 0.0,
    );
    // learning within 20 minutes counts; the one in 3 hours not yet
    assert_eq!(
        queue.counts,
        Counts {
            new: 1,
            learning: 2,
            review: 1
        }
    );
    let order: Vec<&Epd> = queue.ordered().map(|(e, _)| e).collect();
    assert_eq!(order, [&learn_now, &review, &new_card, &learn_later]);
    queue.remove(&learn_now);
    queue.remove(&review);
    queue.remove(&new_card);
    assert_eq!(queue.next().map(|(e, _)| e.clone()), Some(learn_later)); // shown early
    assert_eq!(queue.next_learning_due(), Some(timing.now + 3 * 3600));
}

#[test]
fn daily_limits() {
    let mut stats = DeckStudyStats::default();
    stats.record_answer(CardQueue::New, 0, 100);
    stats.record_answer(CardQueue::Review, 0, 100);
    stats.record_answer(CardQueue::Learn, 0, 100);
    let config = DeckConfig {
        new_per_day: 5,
        reviews_per_day: 10,
        ..DeckConfig::default()
    };
    let limits = RemainingLimits::new(&config, &DeckLimits::default(), &stats, 100);
    assert_eq!(limits.new, 4);
    assert_eq!(limits.review, 8); // new cards count against the review limit
    let deck = DeckLimits {
        new_limit_today: Some(DayLimit {
            limit: 7,
            today: 100,
        }),
        ..DeckLimits::default()
    };
    assert_eq!(RemainingLimits::new(&config, &deck, &stats, 100).new, 6);
    // a different day: the counts and the today-only limit no longer apply
    assert_eq!(RemainingLimits::new(&config, &deck, &stats, 101).new, 5);
    stats.extend_limits(100, 3, 0);
    assert_eq!(
        RemainingLimits::new(&config, &DeckLimits::default(), &stats, 100).new,
        7
    );
}

#[test]
fn card_id_is_fnv_of_the_epd() {
    // FNV-1a 64 of the start EPD, masked to 63 bits; must never change (sidecars store it).
    let id = Card::id_for(&start());
    let mut h: u64 = 0xcbf29ce484222325;
    for b in start().as_str().bytes() {
        h = (h ^ u64::from(b)).wrapping_mul(0x100000001b3);
    }
    assert_eq!(id, (h & 0x7fff_ffff_ffff_ffff) as i64);
}

#[test]
fn splitmix64_and_swift_shuffle_match_the_swift_build() {
    // core/fixtures/queue/queues.json: splitmix64 and shuffle_0_to_19_day100
    let mut rng = SplitMix64::new(12345);
    let first: Vec<u64> = (0..3).map(|_| rng.next_u64()).collect();
    assert_eq!(
        first,
        [
            2454886589211414944,
            3778200017661327597,
            2205171434679333405
        ]
    );
    let mut items: Vec<i64> = (0..20).collect();
    let mut rng = SplitMix64::new(100u64.wrapping_mul(2_654_435_761));
    super::queue::swift_shuffle(&mut items, &mut rng);
    assert_eq!(
        items,
        [
            18, 14, 8, 4, 5, 0, 10, 13, 12, 7, 9, 16, 11, 1, 3, 6, 19, 15, 17, 2
        ]
    );
}
