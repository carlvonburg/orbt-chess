//! Trainers, queues and study sessions against the Swift core's fixtures.

mod common;
mod golden;

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::Arc;

use common::{TreeExt, fnv};
use ot_core::chess::{Epd, Side};
use ot_core::repertoire::{NodeId, RepertoireTree};
use ot_core::training::anki::{
    Card, CardQueue, CardQueues, CardType, Counts, DeckConfig, DeckLimits, DeckStudyStats,
    MemoryState, QueueKind, Rating, RemainingLimits, SchedTiming, Scheduler,
};
use ot_core::training::{AnswerKind, MoveRole, PracticeMode, StudyLine, StudySession, Trainer};
use serde_json::{Value, json};

/// EPD keys as the Swift build wrote them: a few Semi-Slav positions differ (legacy_epds).
struct Keys {
    to_swift: HashMap<Epd, Epd>,
}

impl Keys {
    fn new(tree: &RepertoireTree) -> Keys {
        let to_swift = tree
            .legacy_epds()
            .into_iter()
            .map(|(id, old)| (tree[id].epd.clone(), old))
            .collect();
        Keys { to_swift }
    }

    fn swift<'a>(&'a self, epd: &'a Epd) -> &'a Epd {
        self.to_swift.get(epd).unwrap_or(epd)
    }

    fn s(&self, epd: &Epd) -> String {
        self.swift(epd).as_str().to_owned()
    }

    fn sorted(&self, epds: impl IntoIterator<Item = Epd>) -> Value {
        let mut v: Vec<String> = epds.into_iter().map(|e| self.s(&e)).collect();
        v.sort();
        json!(v)
    }
}

fn training_tree(name: &str) -> (RepertoireTree, Side) {
    match name {
        "white_tree" => {
            let mut t = RepertoireTree::default();
            for line in [
                "e4 c5 Nf3 d6 d4",
                "e4 c5 Nf3 Nc6 d4",
                "e4 e5 Nf3",
                "e4 e5 Bc4",
            ] {
                t.add(line);
            }
            (t, Side::White)
        }
        "takeback_tree" => {
            let mut t = RepertoireTree::default();
            for line in [
                "e4 c5 Nf3 d6 d4 cxd4 Nxd4 Nf6 Nc3 a6 Be3",
                "e4 c5 Nf3 d6 d4 cxd4 Nxd4 Nf6 Nc3 g6 Be3",
                "e4 e5 Nf3",
                "e4 e5 Bc4 Nf6 d3",
                "d4 d5 c4 e6 Nc3",
                "d4 Nf6 c4 e6 Nc3",
            ] {
                t.add(line);
            }
            (t, Side::White)
        }
        "berlin" | "semislav" | "transposition" | "transposition_three_orders" => (
            RepertoireTree::from_pgn(&golden::text(&format!("inputs/{name}.pgn"))),
            Side::Black,
        ),
        other => panic!("unknown tree {other}"),
    }
}

const TREES: [&str; 6] = [
    "white_tree",
    "takeback_tree",
    "transposition",
    "transposition_three_orders",
    "berlin",
    "semislav",
];

fn reach(v: &Value) -> HashMap<NodeId, f64> {
    v.as_object()
        .unwrap()
        .iter()
        .map(|(k, r)| (k.parse().unwrap(), r.as_f64().unwrap()))
        .collect()
}

/// GoldenFixtureTests.mixedCards: a deterministic card set over the new-card order, hashed
/// and keyed by the Swift EPD so it matches the recorded cards.
fn mixed_cards(order: &[Epd], keys: &Keys, timing: &SchedTiming, t0: i64) -> HashMap<Epd, Card> {
    let mut cards = HashMap::new();
    let (now, today) = (timing.now, timing.days_elapsed);
    for (i, epd) in order.iter().enumerate() {
        let swift = keys.swift(epd);
        let i64i = i as i64;
        let mut c = Card::new(Card::id_for(swift), i64i, t0);
        c.original_position = Some(i64i);
        c.ease_factor = 2500;
        let m = |s: f64, d: f64| {
            Some(MemoryState {
                stability: s,
                difficulty: d,
            })
        };
        match fnv(swift.as_str()) % 10 {
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
                c.last_review_time = Some(now - (interval + i64i % 4) * 86_400);
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
                c.last_review_time = Some(now - (interval - 1 - i64i % 9) * 86_400);
            }
            8 => {
                (c.ctype, c.queue, c.due, c.reps, c.remaining_steps) =
                    (CardType::Learn, CardQueue::DayLearn, today - i64i % 2, 1, 1);
                c.memory = m(2.3, 3.0);
                c.last_review_time = Some(now - (1 + i64i % 2) * 86_400);
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

fn cards_json(cards: &HashMap<Epd, Card>, keys: &Keys) -> Value {
    let map: serde_json::Map<String, Value> = cards
        .iter()
        .map(|(e, c)| (keys.s(e), serde_json::to_value(c).unwrap()))
        .collect();
    Value::Object(map)
}

fn progress_json(p: ot_core::training::Progress) -> Value {
    json!({"cards": p.cards, "learning": p.learning, "young": p.young, "mature": p.mature,
           "suspended": p.suspended})
}

fn ids(v: &[NodeId]) -> Value {
    json!(v)
}

fn timing(v: &Value) -> SchedTiming {
    SchedTiming::new(
        v["daysElapsed"].as_i64().unwrap(),
        v["nextDayAt"].as_i64().unwrap(),
        v["now"].as_i64().unwrap(),
    )
}

#[test]
fn trainers_match_swift() {
    for name in TREES {
        let fixture = golden::json(&format!("trainer/{name}.json"));
        let (tree, color) = training_tree(name);
        assert_eq!(json!(tree.count()), fixture["tree"]["count"], "{name}");
        let keys = Keys::new(&tree);
        let t = Trainer::new(Arc::new(tree.clone()), color);
        let reach = reach(&fixture["reach"]);
        let root = RepertoireTree::ROOT;
        let card_nodes = t.card_nodes(root);
        let branches: Vec<NodeId> = tree[root]
            .children
            .iter()
            .flat_map(|&c| std::iter::once(c).chain(tree[c].children.iter().take(2).copied()))
            .collect();
        let order = t.new_card_order(root, &reach);
        let mut trainable: Vec<NodeId> = t.trainable.iter().copied().collect();
        trainable.sort();
        let by_branch = |f: &dyn Fn(NodeId) -> Value| -> Value {
            Value::Object(branches.iter().map(|&b| (b.to_string(), f(b))).collect())
        };
        let lines = |r: NodeId| json!(t.all_lines(r));
        let start = timing(
            &json!({"daysElapsed": 100, "nextDayAt": 1_700_000_000 + 101 * 86_400,
                                    "now": 1_700_000_000 + 100 * 86_400 + 8 * 3600}),
        );
        let cards = mixed_cards(&order, &keys, &start, 1_700_000_000);
        let actual = json!({
            "trainable": trainable,
            "cardNodes": ids(&card_nodes),
            "cardEPDs": keys.sorted(t.card_epd_set.iter().cloned()),
            "suspendedCardEPDs": keys.sorted(t.suspended_card_epds(root)),
            "expectedMoves": Value::Object(card_nodes.iter().map(|&id| {
                (id.to_string(), json!(t.expected_move(id).map(|m| &m.uci)))
            }).collect()),
            "allLines": lines(root),
            "branchLines": by_branch(&|b| lines(b)),
            "branchCardNodes": by_branch(&|b| ids(&t.card_nodes(b))),
            "newCardOrder": json!(t.new_card_order(root, &HashMap::new()).iter().map(|e| keys.s(e)).collect::<Vec<_>>()),
            "newCardOrderByReach": json!(order.iter().map(|e| keys.s(e)).collect::<Vec<_>>()),
            "newCardOrderByReachPerBranch": by_branch(&|b| {
                json!(t.new_card_order(b, &reach).iter().map(|e| keys.s(e)).collect::<Vec<_>>())
            }),
            "lineThrough": Value::Object(card_nodes.iter().take(200).map(|&id| {
                let score = |n: NodeId| reach.get(&n).copied().unwrap_or(0.0);
                (id.to_string(), ids(&t.line_through(id, &score)))
            }).collect()),
            "mixedCards": cards_json(&cards, &keys),
            "progress": progress_json(t.progress(root, &cards)),
            "progressEmpty": progress_json(t.progress(root, &HashMap::new())),
        });
        let mut expected = fixture.clone();
        for k in ["color", "tree", "reach"] {
            expected.as_object_mut().unwrap().remove(k);
        }
        golden::assert_same(name, &expected, &actual, 1e-12);
    }
}

// Queue snapshots, as GoldenSupport.queue writes them.

fn kind_name(k: QueueKind) -> &'static str {
    match k {
        QueueKind::New => "new",
        QueueKind::Learning => "learning",
        QueueKind::Review => "review",
    }
}

fn counts_json(c: Counts) -> Value {
    json!({"new": c.new, "learning": c.learning, "review": c.review})
}

fn limits_json(l: &RemainingLimits) -> Value {
    json!({"review": l.review, "new": l.new, "capNewToReview": l.cap_new_to_review})
}

fn learning_groups(q: &CardQueues) -> Vec<Vec<(String, i64, i64)>> {
    let mut groups: Vec<Vec<(String, i64, i64)>> = Vec::new();
    for (epd, due, reps) in q.intraday_entries() {
        let ties = |a: &(String, i64, i64)| (a.2 == 0) == (reps == 0) && a.1 == due;
        match groups.last_mut() {
            Some(g) if ties(g.last().unwrap()) => g.push((epd.as_str().into(), due, reps)),
            _ => groups.push(vec![(epd.as_str().into(), due, reps)]),
        }
    }
    groups
}

fn queue_json(q: &CardQueues, exact: bool) -> Value {
    let groups = learning_groups(q);
    let (cutoff, ahead) = (q.current_learning_cutoff(), q.learn_ahead_cutoff());
    let pick = |g: &Vec<(String, i64, i64)>, f: &dyn Fn(i64) -> bool| -> Vec<String> {
        let mut v: Vec<String> = g.iter().filter(|e| f(e.1)).map(|e| e.0.clone()).collect();
        v.sort();
        v
    };
    let mut ordered_groups: Vec<Value> = Vec::new();
    for g in &groups {
        let now = pick(g, &|d| d <= cutoff);
        if !now.is_empty() {
            ordered_groups.push(json!(now));
        }
    }
    for (epd, _) in q.main_entries() {
        ordered_groups.push(json!([epd.as_str()]));
    }
    for g in &groups {
        let later = pick(g, &|d| d > cutoff && d <= ahead);
        if !later.is_empty() {
            ordered_groups.push(json!(later));
        }
    }
    let mut kinds = serde_json::Map::new();
    for (epd, k) in q.ordered() {
        kinds.entry(epd.as_str()).or_insert(json!(kind_name(k)));
    }
    let tie_at_front = match groups.iter().find(|g| g.iter().any(|e| e.1 <= cutoff)) {
        Some(first) => first.iter().filter(|e| e.1 <= cutoff).count() > 1,
        None if q.main_entries().next().is_some() => false,
        None => groups
            .iter()
            .find(|g| g.iter().any(|e| e.1 > cutoff && e.1 <= ahead))
            .is_some_and(|g| g.len() > 1),
    };
    let mut out = json!({
        "counts": counts_json(q.counts),
        "currentDay": q.current_day,
        "learnAheadSecs": q.learn_ahead_secs(),
        "currentLearningCutoff": cutoff,
        "main": q.main_entries().map(|(e, k)| json!({"epd": e.as_str(), "kind": match k {
            QueueKind::Learning => "interdayLearning", other => kind_name(other) }})).collect::<Vec<_>>(),
        "intradayLearningGroups": groups.iter().map(|g| {
            let mut g = g.clone();
            g.sort();
            json!(g.iter().map(|e| json!({"epd": e.0, "due": e.1, "reps": e.2})).collect::<Vec<_>>())
        }).collect::<Vec<_>>(),
        "orderedGroups": ordered_groups,
        "orderedKinds": kinds,
        "nextLearningDue": q.next_learning_due(),
        "hasTieAtFront": tie_at_front,
    });
    if exact {
        let o = out.as_object_mut().unwrap();
        o.insert(
            "intradayLearning".into(),
            json!(
                q.intraday_entries()
                    .map(|(e, d, r)| json!({"epd": e.as_str(), "due": d, "reps": r}))
                    .collect::<Vec<_>>()
            ),
        );
        o.insert(
            "ordered".into(),
            json!(
                q.ordered()
                    .map(|(e, k)| json!([e.as_str(), kind_name(k)]))
                    .collect::<Vec<_>>()
            ),
        );
    }
    out
}

fn cards_from(v: &Value) -> HashMap<Epd, Card> {
    v.as_object()
        .unwrap()
        .iter()
        .map(|(e, c)| {
            (
                Epd::new(e.as_str()),
                serde_json::from_value(c.clone()).unwrap(),
            )
        })
        .collect()
}

fn epd_list(v: &Value) -> Vec<Epd> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|e| Epd::new(e.as_str().unwrap()))
        .collect()
}

fn limits_from(v: &Value) -> RemainingLimits {
    RemainingLimits {
        review: v["review"].as_i64().unwrap(),
        new: v["new"].as_i64().unwrap(),
        cap_new_to_review: v["capNewToReview"] == true,
    }
}

#[test]
fn queues_match_swift() {
    let fixture = golden::json("queue/queues.json");

    // berlin_mixed: daily queues under several limits, answering the first three cards.
    let mixed = &fixture["berlin_mixed"];
    let cards = cards_from(&mixed["cards"]);
    let order = epd_list(&mixed["newCards"]);
    let priority: HashMap<Epd, f64> = mixed["priority"]
        .as_object()
        .unwrap()
        .iter()
        .map(|(e, r)| (Epd::new(e.as_str()), r.as_f64().unwrap()))
        .collect();
    let start = timing(&mixed["timing"]);
    for (case_name, case) in mixed["cases"].as_object().unwrap() {
        let mut q = CardQueues::new(
            &cards,
            &order,
            limits_from(&case["limits"]),
            &start,
            case["learnAheadSecs"].as_i64().unwrap(),
            &|e| priority.get(e).copied().unwrap_or(0.0),
        );
        for (i, step) in case["steps"].as_array().unwrap().iter().enumerate() {
            let label = format!("berlin_mixed {case_name} step {i} {}", step["op"]);
            match step["op"].as_str().unwrap() {
                "build" => {}
                "remove" => q.remove(&Epd::new(step["epd"].as_str().unwrap())),
                "answered" => {
                    let epd = Epd::new(step["epd"].as_str().unwrap());
                    let t = timing(&step["timing"]);
                    let card: Card = serde_json::from_value(step["card"].clone()).unwrap();
                    q.answered(&card, &epd, &t);
                }
                "updateLearningCutoff" => q.update_learning_cutoff(step["now"].as_i64().unwrap()),
                other => panic!("{other}"),
            }
            let exact = step["queue"].get("ordered").is_some();
            golden::assert_same(&label, &step["queue"], &queue_json(&q, exact), 0.0);
        }
    }

    // berlin_filtered: branch queues, shuffled like Swift's shuffle(using:).
    let filtered = &fixture["berlin_filtered"];
    let fcards = cards_from(&filtered["cards"]);
    let epds = epd_list(&filtered["epds"]);
    for day in filtered["days"].as_array().unwrap() {
        let q = CardQueues::filtered(&epds, &fcards, &timing(&day["timing"]), 1200);
        golden::assert_same("berlin_filtered", &day["queue"], &queue_json(&q, true), 0.0);
    }

    // remainingLimits rows.
    let rows = fixture["remainingLimits"].as_array().unwrap();
    for ignore in [false, true] {
        let config = DeckConfig {
            new_per_day: 5,
            reviews_per_day: 10,
            new_cards_ignore_review_limit: ignore,
            ..DeckConfig::default()
        };
        let mut stats = DeckStudyStats::default();
        stats.record_answer(CardQueue::New, 10, 100);
        stats.record_answer(CardQueue::Review, 20, 100);
        stats.record_answer(CardQueue::DayLearn, 30, 100);
        stats.record_answer(CardQueue::Learn, 40, 100);
        let mut extended = stats;
        extended.extend_limits(100, 3, 4);
        let deck = DeckLimits {
            new_limit: Some(8),
            review_limit: Some(12),
            new_limit_today: Some(ot_core::training::anki::DayLimit {
                limit: 7,
                today: 100,
            }),
            review_limit_today: None,
        };
        for (sname, s) in [
            ("none", DeckStudyStats::default()),
            ("studied", stats),
            ("extended", extended),
        ] {
            for (dname, d) in [("default", DeckLimits::default()), ("deck", deck)] {
                for today in [100, 101] {
                    let row = rows
                        .iter()
                        .find(|r| {
                            r["newCardsIgnoreReviewLimit"] == ignore
                                && r["stats"] == sname
                                && r["deckLimits"] == dname
                                && r["today"] == today
                        })
                        .unwrap();
                    let actual = limits_json(&RemainingLimits::new(&config, &d, &s, today));
                    golden::assert_same(
                        &format!("limits {ignore} {sname} {dname} {today}"),
                        &row["result"],
                        &actual,
                        0.0,
                    );
                }
            }
        }
    }
}

// Sessions, simulated like GoldenFixtureTests.simulate (DrillView's flow).

fn role_name(r: MoveRole) -> &'static str {
    match r {
        MoveRole::Auto => "auto",
        MoveRole::Practice => "practice",
        MoveRole::Answer(AnswerKind::Queued) => "answer.queued",
        MoveRole::Answer(AnswerKind::Introduce) => "answer.introduce",
        MoveRole::Answer(AnswerKind::ReviewAhead) => "answer.reviewAhead",
    }
}

fn line_json(l: &StudyLine, keys: &Keys) -> Value {
    let roles: serde_json::Map<String, Value> = l
        .roles
        .iter()
        .map(|(i, r)| (i.to_string(), json!(role_name(*r))))
        .collect();
    json!({"nodes": l.nodes, "target": keys.s(&l.target), "roles": roles})
}

fn simulate(
    mut session: StudySession,
    initial: &HashMap<Epd, Card>,
    start: &SchedTiming,
    keys: &Keys,
) -> Value {
    let mut cards = initial.clone();
    let mut now = start.now;
    let mut lines = Vec::new();
    let mut previous: Option<Vec<NodeId>> = None;
    let mut answer_count = 0;
    let mut revlog = Vec::new();
    let scheduler = Scheduler::default();
    for _ in 0..40 {
        session.update_learning_cutoff(now);
        let counts_before = session.queue.counts;
        let Some(line) = session.next_line(&cards) else {
            match session.queue.next_learning_due() {
                Some(due) if due < start.next_day_at => {
                    lines.push(json!({"waitUntil": due}));
                    now = now.max(due);
                    continue;
                }
                _ => break,
            }
        };
        let resume = previous
            .as_ref()
            .and_then(|p| line.resume_index(p, p.len() - 1));
        let mut answers = Vec::new();
        for (&i, &role) in &line.roles {
            now += 7;
            if role == MoveRole::Auto {
                continue;
            }
            let epd = session.trainer.tree[line.nodes[i]].epd.clone();
            if let MoveRole::Answer(kind) = role {
                let swift = keys.s(&epd);
                let rating = if fnv(&format!("{swift}{answer_count}")).is_multiple_of(4) {
                    Rating::Again
                } else {
                    Rating::Good
                };
                answer_count += 1;
                let t = SchedTiming::new(start.days_elapsed, start.next_day_at, now);
                let filtered = session.is_filtered || kind == AnswerKind::ReviewAhead;
                let position = session.position(&epd);
                let result = scheduler.answer(
                    cards.get(&epd),
                    keys.swift(&epd),
                    position,
                    rating,
                    &t,
                    filtered,
                    7000,
                    None,
                );
                cards.insert(epd.clone(), result.card.clone());
                revlog.push(serde_json::to_value(&result.revlog).unwrap());
                session.did_answer(&epd, &result.card, &t);
                answers.push(
                    json!({"index": i, "epd": swift, "rating": i64::from(rating),
                    "filtered": filtered, "position": session.position(&epd),
                    "card": serde_json::to_value(&result.card).unwrap(),
                    "fromQueue": i64::from(result.from_queue)}),
                );
            }
            session.did_play(&epd);
        }
        lines.push(json!({"now": now - 7 * line.roles.len() as i64, "countsBefore": counts_json(counts_before),
            "line": line_json(&line, keys), "resumeIndex": resume, "answers": answers,
            "countsAfter": counts_json(session.queue.counts)}));
        previous = Some(line.nodes.clone());
    }
    json!({"lines": lines, "finalCards": cards_json(&cards, keys), "revlog": revlog,
           "answered": keys.sorted(session.answered.iter().cloned()),
           "played": keys.sorted(session.played.iter().cloned())})
}

#[test]
fn sessions_match_swift() {
    for name in TREES {
        let fixture = golden::json(&format!("session/{name}.json"));
        let (tree, color) = training_tree(name);
        let keys = Keys::new(&tree);
        let trainer = Arc::new(Trainer::new(Arc::new(tree.clone()), color));
        let reach = reach(&fixture["reach"]);
        let order = trainer.new_card_order(RepertoireTree::ROOT, &reach);
        let branch = fixture["branch"].as_u64().unwrap() as NodeId;
        let t0 = fixture["t0"].as_i64().unwrap();
        for (key, expected) in fixture.as_object().unwrap() {
            let parts: Vec<&str> = key.split('.').collect();
            if parts.len() != 3 {
                continue;
            }
            assert_eq!(expected["stoppedOnTie"], false, "{name} {key}");
            let start = timing(&expected["startTiming"]);
            let initial = if parts[0] == "mixed" {
                mixed_cards(&order, &keys, &start, t0)
            } else {
                HashMap::new()
            };
            let mode: PracticeMode = serde_json::from_value(json!(parts[1])).unwrap();
            let session = if parts[2] == "branch" {
                StudySession::branch(
                    trainer.clone(),
                    mode,
                    branch,
                    &initial,
                    &start,
                    1200,
                    reach.clone(),
                )
            } else {
                StudySession::daily(
                    trainer.clone(),
                    mode,
                    &initial,
                    limits_from(&expected["limits"]),
                    &start,
                    1200,
                    reach.clone(),
                )
            };
            let actual = simulate(session, &initial, &start, &keys);
            let want = json!({"lines": expected["lines"], "finalCards": expected["finalCards"],
                "revlog": expected["revlog"], "answered": expected["answered"],
                "played": expected["played"]});
            golden::assert_same(&format!("{name} {key}"), &want, &actual, 2e-5);
        }
    }
}

#[allow(dead_code)]
fn unused(_: BTreeMap<(), ()>, _: HashSet<()>) {}
