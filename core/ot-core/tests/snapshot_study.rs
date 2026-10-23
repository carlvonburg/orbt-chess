//! Snapshots of training: what the trainer derives from a tree, the daily and filtered queues,
//! and simulated study sessions (answers are Again for one move in four, by hash). Trees are
//! built here, read from tests/data/pgn, or the real repertoires in testData/; reach comes from
//! `common::reach`. After an intended change, review the new snapshots with
//! `cargo insta review`.

mod common;

use std::collections::{HashMap, HashSet};
use std::fmt::Write;
use std::sync::Arc;

use common::{TreeExt, fnv, line_san};
use ot_core::chess::{Epd, Side};
use ot_core::repertoire::{NodeId, RepertoireTree};
use ot_core::training::anki::{
    Card, CardQueue, CardQueues, CardType, MemoryState, QueueKind, Rating, RemainingLimits,
    SchedTiming, Scheduler,
};
use ot_core::training::{MoveRole, PracticeMode, StudySession, Trainer};

const T0: i64 = 1_700_000_000;
const DAY: i64 = 86_400;

/// Day 100 at 08:00.
fn start() -> SchedTiming {
    SchedTiming::new(100, T0 + 101 * DAY, T0 + 100 * DAY + 8 * 3600)
}

fn training_tree(name: &str) -> (RepertoireTree, Side) {
    let built = |lines: &[&str]| {
        let mut t = RepertoireTree::default();
        for line in lines {
            t.add(line);
        }
        t
    };
    match name {
        "white_tree" => (
            built(&[
                "e4 c5 Nf3 d6 d4",
                "e4 c5 Nf3 Nc6 d4",
                "e4 e5 Nf3",
                "e4 e5 Bc4",
            ]),
            Side::White,
        ),
        "takeback_tree" => (
            built(&[
                "e4 c5 Nf3 d6 d4 cxd4 Nxd4 Nf6 Nc3 a6 Be3",
                "e4 c5 Nf3 d6 d4 cxd4 Nxd4 Nf6 Nc3 g6 Be3",
                "e4 e5 Nf3",
                "e4 e5 Bc4 Nf6 d3",
                "d4 d5 c4 e6 Nc3",
                "d4 Nf6 c4 e6 Nc3",
            ]),
            Side::White,
        ),
        "transposition" | "transposition_three_orders" => (
            RepertoireTree::from_pgn(&common::data_text(&format!("pgn/{name}.pgn"))),
            Side::Black,
        ),
        real => (
            RepertoireTree::from_pgn(&common::repertoire(real)),
            Side::Black,
        ),
    }
}

const SMALL: [&str; 4] = [
    "white_tree",
    "takeback_tree",
    "transposition",
    "transposition_three_orders",
];

/// A position by the moves that lead to it (its first node).
fn epd_name(tree: &RepertoireTree, epd: &Epd) -> String {
    let id = tree.epd_index()[epd].iter().min().copied().unwrap();
    format!("[{}]", line_san(tree, &tree.path(id)))
}

fn sorted_names(tree: &RepertoireTree, epds: impl IntoIterator<Item = Epd>) -> Vec<String> {
    let mut v: Vec<String> = epds.into_iter().map(|e| epd_name(tree, &e)).collect();
    v.sort();
    v
}

/// A deterministic mix of new, learning, review, day-learn, relearning and suspended cards
/// over the new-card order, chosen by hash.
fn mixed_cards(order: &[Epd], timing: &SchedTiming) -> HashMap<Epd, Card> {
    let mut cards = HashMap::new();
    let (now, today) = (timing.now, timing.days_elapsed);
    for (i, epd) in order.iter().enumerate() {
        let i64i = i as i64;
        let mut c = Card::new(Card::id_for(epd), i64i, T0);
        c.original_position = Some(i64i);
        c.ease_factor = 2500;
        let m = |s: f64, d: f64| {
            Some(MemoryState {
                stability: s,
                difficulty: d,
            })
        };
        match fnv(epd.as_str()) % 10 {
            0..=3 => continue,
            4 => {
                (c.ctype, c.queue, c.due, c.reps, c.remaining_steps) =
                    (CardType::Learn, CardQueue::Learn, now - 50 - i64i, 1, 1);
                c.memory = m(0.5, 6.0);
                c.last_review_time = Some(c.due - 600);
            }
            5 => {
                (c.ctype, c.queue, c.due, c.reps, c.remaining_steps) = (
                    CardType::Learn,
                    CardQueue::Learn,
                    now + 120 + 37 * i64i % 50_000,
                    2,
                    1,
                );
                c.memory = m(1.2, 5.5);
                c.last_review_time = Some(now - 60);
            }
            6 => {
                let interval = 3 + i64i % 20;
                (c.ctype, c.queue, c.due, c.interval, c.reps) = (
                    CardType::Review,
                    CardQueue::Review,
                    today - i64i % 4,
                    interval,
                    3,
                );
                c.memory = m(interval as f64, 5.0 + (i64i % 4) as f64);
                c.last_review_time = Some(now - (interval + i64i % 4) * DAY);
            }
            7 => {
                let interval = 5 + i64i % 30;
                (c.ctype, c.queue, c.due, c.interval, c.reps) = (
                    CardType::Review,
                    CardQueue::Review,
                    today + 1 + i64i % 9,
                    interval,
                    4,
                );
                c.memory = m(interval as f64, 4.0);
                c.last_review_time = Some(now - (interval - 1 - i64i % 9) * DAY);
            }
            8 => {
                (c.ctype, c.queue, c.due, c.reps, c.remaining_steps) =
                    (CardType::Learn, CardQueue::DayLearn, today - i64i % 2, 1, 1);
                c.memory = m(2.3, 3.0);
                c.last_review_time = Some(now - (1 + i64i % 2) * DAY);
            }
            _ => {
                (c.ctype, c.interval, c.lapses, c.reps, c.remaining_steps) =
                    (CardType::Relearn, 4, 1, 6, 1);
                c.memory = m(1.1, 7.0);
                c.last_review_time = Some(now - 300);
                if i % 2 == 1 {
                    (c.queue, c.due) = (CardQueue::Suspended, now - 1000);
                } else {
                    (c.queue, c.due) = (CardQueue::Learn, now + 413 + 37 * i64i % 50_000);
                }
            }
        }
        cards.insert(epd.clone(), c);
    }
    cards
}

fn progress(p: ot_core::training::Progress) -> String {
    format!(
        "{} cards: {} learning, {} young, {} mature; {} suspended",
        p.cards, p.learning, p.young, p.mature, p.suspended
    )
}

/// The branches: each first move and its first two replies.
fn branches(tree: &RepertoireTree) -> Vec<NodeId> {
    tree[RepertoireTree::ROOT]
        .children
        .iter()
        .flat_map(|&c| std::iter::once(c).chain(tree[c].children.iter().take(2).copied()))
        .collect()
}

#[test]
fn trainers() {
    for name in SMALL.iter().chain(&common::REPERTOIRES) {
        let small = SMALL.contains(name);
        let (tree, color) = training_tree(name);
        let reach = common::reach(&tree, color);
        let t = Trainer::new(Arc::new(tree.clone()), color);
        let root = RepertoireTree::ROOT;
        let card_nodes = t.card_nodes(root);
        let order = t.new_card_order(root, &reach);
        let lines = t.all_lines(root);
        let cards = mixed_cards(&order, &start());
        let limit = if small { usize::MAX } else { 20 };
        let mut out = String::new();
        writeln!(
            out,
            "{} trainable nodes, {} card nodes, {} card positions, {} suspended, {} lines",
            t.trainable.len(),
            card_nodes.len(),
            t.card_epd_set.len(),
            t.suspended_card_epds(root).len(),
            lines.len()
        )
        .unwrap();
        writeln!(
            out,
            "progress with mixed cards: {}",
            progress(t.progress(root, &cards))
        )
        .unwrap();
        writeln!(
            out,
            "progress without cards: {}",
            progress(t.progress(root, &HashMap::new()))
        )
        .unwrap();
        if small {
            let mut trainable: Vec<NodeId> = t.trainable.iter().copied().collect();
            trainable.sort();
            writeln!(out, "trainable: {trainable:?}").unwrap();
            writeln!(
                out,
                "suspended: {:?}",
                sorted_names(&tree, t.suspended_card_epds(root))
            )
            .unwrap();
            writeln!(out, "cards and their expected moves:").unwrap();
            for &id in &card_nodes {
                let expected = t.expected_move(id).map_or("-", |m| m.san.as_str());
                let through = t.line_through(id, &|n| reach.get(&n).copied().unwrap_or(0.0));
                writeln!(
                    out,
                    "  {id} [{}] -> {expected}; line through it: {}",
                    line_san(&tree, &tree.path(id)),
                    line_san(&tree, &through)
                )
                .unwrap();
            }
            writeln!(
                out,
                "new cards in tree order: {:?}",
                t.new_card_order(root, &HashMap::new())
                    .iter()
                    .map(|e| epd_name(&tree, e))
                    .collect::<Vec<_>>()
            )
            .unwrap();
            for b in branches(&tree) {
                writeln!(
                    out,
                    "branch [{}]: {} lines, cards {:?}, new by reach {:?}",
                    line_san(&tree, &tree.path(b)),
                    t.all_lines(b).len(),
                    t.card_nodes(b),
                    t.new_card_order(b, &reach)
                        .iter()
                        .map(|e| epd_name(&tree, e))
                        .collect::<Vec<_>>()
                )
                .unwrap();
            }
        }
        writeln!(out, "new cards by reach:").unwrap();
        for epd in order.iter().take(limit) {
            writeln!(out, "  {}", epd_name(&tree, epd)).unwrap();
        }
        writeln!(out, "lines:").unwrap();
        for line in lines.iter().take(limit) {
            writeln!(out, "  {}", line_san(&tree, line)).unwrap();
        }
        insta::assert_snapshot!(format!("trainer.{name}"), out);
    }
}

fn kind(k: QueueKind) -> &'static str {
    match k {
        QueueKind::New => "new",
        QueueKind::Learning => "learning",
        QueueKind::Review => "review",
    }
}

/// Counts, cutoffs and the first cards the queue would show.
fn queue_text(tree: &RepertoireTree, q: &CardQueues) -> String {
    let mut out = format!(
        "counts {:?}, learning cutoff +{}s, next learning due {:?}, {} intraday learning\n",
        q.counts,
        q.current_learning_cutoff() - start().now,
        q.next_learning_due().map(|d| d - start().now),
        q.intraday_entries().count()
    );
    for (epd, k) in q.ordered().take(15) {
        writeln!(out, "    {} {}", kind(k), epd_name(tree, epd)).unwrap();
    }
    out
}

#[test]
fn queues() {
    let (tree, color) = training_tree("berlin");
    let reach = common::reach(&tree, color);
    let t = Trainer::new(Arc::new(tree.clone()), color);
    let order = t.new_card_order(RepertoireTree::ROOT, &reach);
    let priority = t.reach_by_epd(&reach);
    let cards = mixed_cards(&order, &start());
    let scheduler = Scheduler::default();
    let cases: [(&str, i64, i64, bool, i64); 7] = [
        ("default, no learn-ahead", 200, 20, true, 0),
        ("default", 200, 20, true, 1200),
        ("2 reviews, new capped", 2, 20, true, 1200),
        ("2 reviews, new not capped", 2, 20, false, 1200),
        ("5 reviews, 3 new", 5, 3, true, 1200),
        ("unlimited", 9999, 9999, false, 1200),
        ("zero", 0, 0, true, 1200),
    ];
    let mut out = String::new();
    for (label, review, new, cap, learn_ahead) in cases {
        let limits = RemainingLimits {
            review,
            new,
            cap_new_to_review: cap,
        };
        let mut q = CardQueues::new(&cards, &order, limits, &start(), learn_ahead, &|e| {
            priority.get(e).copied().unwrap_or(0.0)
        });
        writeln!(out, "{label}:\n  built: {}", queue_text(&tree, &q)).unwrap();
        // Answer the first three cards shown: Again, Good, Again, 10 s apart.
        for (i, rating) in [Rating::Again, Rating::Good, Rating::Again]
            .into_iter()
            .enumerate()
        {
            let Some((epd, _)) = q.ordered().next() else {
                break;
            };
            let epd = epd.clone();
            q.remove(&epd);
            let now = start().now + 10 * (i as i64 + 1);
            let timing = SchedTiming::new(start().days_elapsed, start().next_day_at, now);
            let position = order.iter().position(|e| *e == epd).unwrap_or(0) as i64;
            let answer = scheduler.answer(
                cards.get(&epd),
                &epd,
                position,
                rating,
                &timing,
                false,
                7000,
                None,
            );
            q.answered(&answer.card, &epd, &timing);
            writeln!(
                out,
                "  after {rating:?} on {}: {}",
                epd_name(&tree, &epd),
                queue_text(&tree, &q)
            )
            .unwrap();
        }
        q.update_learning_cutoff(start().now + 1500);
        writeln!(out, "  25 minutes later: {}", queue_text(&tree, &q)).unwrap();
    }
    insta::assert_snapshot!("queues.berlin", out);

    // A branch drill (filtered deck): every card under the first reply, shuffled by day.
    let branch = tree[tree[RepertoireTree::ROOT].children[0]].children[0];
    let mut seen = HashSet::new();
    let epds: Vec<Epd> = t
        .card_nodes(branch)
        .into_iter()
        .map(|id| tree[id].epd.clone())
        .filter(|e| seen.insert(e.clone()))
        .collect();
    let mut out = format!(
        "branch [{}], {} cards\n",
        line_san(&tree, &tree.path(branch)),
        epds.len()
    );
    for day in [100, 101, 5000] {
        let timing = SchedTiming::new(day, T0 + (day + 1) * DAY, T0 + day * DAY + 8 * 3600);
        let q = CardQueues::filtered(&epds, &cards, &timing, 1200);
        let first: Vec<String> = q
            .ordered()
            .take(8)
            .map(|(e, k)| format!("{} {}", kind(k), epd_name(&tree, e)))
            .collect();
        writeln!(
            out,
            "day {day}: counts {:?}\n    {}",
            q.counts,
            first.join("\n    ")
        )
        .unwrap();
    }
    insta::assert_snapshot!("queues.berlin_branch", out);
}

fn role(r: MoveRole) -> String {
    match r {
        MoveRole::Auto => "auto".into(),
        MoveRole::Practice => "practice".into(),
        MoveRole::Answer(k) => format!("{k:?}").to_lowercase(),
    }
}

/// Plays a session to its end (or `max_lines`), as the drill screen would: 7 s per move.
fn simulate(mut session: StudySession, initial: &HashMap<Epd, Card>, max_lines: usize) -> String {
    let tree = session.trainer.tree.clone();
    let start = start();
    let mut cards = initial.clone();
    let mut now = start.now;
    let mut previous: Option<Vec<NodeId>> = None;
    let mut shown: HashSet<NodeId> = HashSet::new();
    let mut answers = 0;
    let scheduler = Scheduler::default();
    let mut out = String::new();
    for _ in 0..max_lines {
        session.update_learning_cutoff(now);
        let counts = session.queue.counts;
        let Some(line) = session.next_line(&cards) else {
            match session.queue.next_learning_due() {
                Some(due) if due < start.next_day_at => {
                    writeln!(out, "wait until +{}s", due - start.now).unwrap();
                    now = now.max(due);
                    continue;
                }
                _ => break,
            }
        };
        let resume = previous
            .as_ref()
            .and_then(|p| line.resume_index(p, p.len() - 1));
        let skip = line.skip_index(&shown);
        let roles: Vec<String> = line
            .roles
            .iter()
            .map(|(i, r)| format!("{i} {}", role(*r)))
            .collect();
        writeln!(
            out,
            "+{}s {counts:?} {}{}\n  roles: {}",
            now - start.now,
            line_san(&tree, &line.nodes),
            match resume {
                Some(r) => format!(" (from {r})"),
                None if skip > 0 => format!(" (skip to {skip})"),
                None => String::new(),
            },
            roles.join(", ")
        )
        .unwrap();
        for (&i, &role) in &line.roles {
            now += 7;
            if role == MoveRole::Auto {
                continue;
            }
            let epd = tree[line.nodes[i]].epd.clone();
            if let MoveRole::Answer(kind) = role {
                let rating = if fnv(&format!("{}{answers}", epd.as_str())).is_multiple_of(4) {
                    Rating::Again
                } else {
                    Rating::Good
                };
                answers += 1;
                let t = SchedTiming::new(start.days_elapsed, start.next_day_at, now);
                let filtered =
                    session.is_filtered || kind == ot_core::training::AnswerKind::ReviewAhead;
                let result = scheduler.answer(
                    cards.get(&epd),
                    &epd,
                    session.position(&epd),
                    rating,
                    &t,
                    filtered,
                    7000,
                    None,
                );
                let c = &result.card;
                writeln!(
                    out,
                    "  {i} {rating:?}{}: {:?}/{:?} due {} ivl {}",
                    if filtered { " filtered" } else { "" },
                    c.ctype,
                    c.queue,
                    if c.queue == CardQueue::Learn {
                        format!("+{}s", c.due - start.now)
                    } else {
                        c.due.to_string()
                    },
                    c.interval
                )
                .unwrap();
                cards.insert(epd.clone(), result.card.clone());
                session.did_answer(&epd, &result.card, &t);
            }
            session.did_play(&epd);
        }
        shown.extend(line.nodes.iter().copied());
        previous = Some(line.nodes.clone());
    }
    writeln!(
        out,
        "{answers} answers, {} positions answered, {} played; counts {:?}",
        session.answered.len(),
        session.played.len(),
        session.queue.counts
    )
    .unwrap();
    out
}

#[test]
fn sessions() {
    for name in SMALL.iter().chain(&common::REPERTOIRES) {
        let max_lines = if SMALL.contains(name) { 40 } else { 12 };
        let (tree, color) = training_tree(name);
        let reach = common::reach(&tree, color);
        let trainer = Arc::new(Trainer::new(Arc::new(tree.clone()), color));
        let order = trainer.new_card_order(RepertoireTree::ROOT, &reach);
        let branch = tree[RepertoireTree::ROOT].children[0];
        for cards in ["empty", "mixed"] {
            let initial = if cards == "mixed" {
                mixed_cards(&order, &start())
            } else {
                HashMap::new()
            };
            for mode in [
                PracticeMode::IndividualMoves,
                PracticeMode::CompleteLinesEveryTime,
                PracticeMode::CompleteLinesOncePerSession,
            ] {
                let daily = StudySession::daily(
                    trainer.clone(),
                    mode,
                    &initial,
                    RemainingLimits {
                        review: 30,
                        new: 5,
                        cap_new_to_review: true,
                    },
                    &start(),
                    1200,
                    reach.clone(),
                );
                let drill = StudySession::branch(
                    trainer.clone(),
                    mode,
                    branch,
                    &initial,
                    &start(),
                    1200,
                    reach.clone(),
                );
                let text = format!(
                    "daily:\n{}\nbranch [{}]:\n{}",
                    simulate(daily, &initial, max_lines),
                    line_san(&tree, &tree.path(branch)),
                    simulate(drill, &initial, max_lines)
                );
                insta::assert_snapshot!(format!("session.{name}.{cards}.{mode:?}"), text);
            }
        }
    }
}
