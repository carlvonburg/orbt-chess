//! Ported from TrainingTests.swift and the training parts of TranspositionTests.swift.

mod common;

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::Arc;

use common::TreeExt;
use orbt_core::chess::{ChessPosition, Epd, Side};
use orbt_core::formats::{Sidecar, Summary, Timestamp};
use orbt_core::repertoire::{NodeId, RepertoireTree};
use orbt_core::training::anki::{
    Card, CardQueue, CardType, DeckStudyStats, Rating, RemainingLimits, SchedTiming, Scheduler,
};
use orbt_core::training::{
    AnswerKind, LineOutcome, LineRun, MoveRole, PracticeMode, Progress, StudyLine, StudySession,
    Trainer,
};

const ROOT: NodeId = RepertoireTree::ROOT;

fn start() -> Epd {
    ChessPosition::start().epd()
}

fn after_e4() -> Epd {
    ChessPosition::start().play_san("e4").unwrap().1.epd()
}

fn new_sidecar(color: Side) -> Sidecar {
    Sidecar::new(
        "6F9619FF-8B86-D011-B42D-00C04FC964FF".into(),
        color,
        Timestamp(1_000),
    )
}

fn answer(epd: &Epd, position: i64, rating: Rating, timing: &SchedTiming) -> Card {
    Scheduler::default()
        .answer(None, epd, position, rating, timing, false, 0, None)
        .card
}

fn trainer(tree: &RepertoireTree, color: Side) -> Arc<Trainer> {
    Arc::new(Trainer::new(Arc::new(tree.clone()), color))
}

#[test]
fn sidecar_round_trip_and_merge() {
    let at = |now| SchedTiming::new(0, 86_400, now);
    let mut a = new_sidecar(Side::White);
    a.study_cards
        .insert(start(), answer(&start(), 0, Rating::Good, &at(100)));
    let mut b = a.clone();
    b.study_cards
        .insert(start(), answer(&start(), 0, Rating::Again, &at(200)));
    b.study_cards
        .insert(after_e4(), answer(&after_e4(), 1, Rating::Good, &at(50)));
    let mut stats = DeckStudyStats::default();
    stats.record_answer(CardQueue::New, 10, 0);
    b.study_stats = Some(stats);
    let merged = a.merged(&b);
    assert_eq!(merged.study_cards[&start()].last_review_time, Some(200));
    assert_eq!(merged.study_cards.len(), 2);
    assert_eq!(merged.study_stats.unwrap().new_studied, 1);
    let decoded = Sidecar::decode(&merged.encoded()).unwrap();
    assert_eq!(decoded.study_cards, merged.study_cards);
    assert_eq!(decoded.settings_modified, merged.settings_modified);
    let text = String::from_utf8(merged.encoded()).unwrap();
    assert!(text.contains("\"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -\""));
}

#[test]
fn summary_round_trip() {
    let mut sidecar = new_sidecar(Side::Black);
    sidecar.summary = Some(Summary {
        completion: 0.5,
        gap_count: 2,
        card_count: 10,
        mature_count: 1,
        saved_move_count: Some(25),
        suspended_count: None,
        due_count: 4,
        config_key: "k".into(),
    });
    let decoded = Sidecar::decode(&sidecar.encoded()).unwrap();
    assert_eq!(decoded.summary.as_ref().unwrap().saved_move_count, Some(25));
    // Summaries written before the counts were added still decode.
    let mut old: serde_json::Value = serde_json::from_slice(&sidecar.encoded()).unwrap();
    old["summary"]
        .as_object_mut()
        .unwrap()
        .remove("savedMoveCount");
    let legacy = Sidecar::decode(&serde_json::to_vec(&old).unwrap()).unwrap();
    let s = legacy.summary.unwrap();
    assert!(s.saved_move_count.is_none() && s.card_count == 10);
}

#[test]
fn decodes_a_sidecar_written_by_the_swift_build() {
    // Apple's pretty-printer, sorted keys, a version-1 file without a version key.
    let json = r#"{
  "color" : "white",
  "database" : {
    "lichess" : {
      "ratings" : [
        1600,
        1800
      ],
      "speeds" : [
        "blitz"
      ]
    }
  },
  "id" : "6F9619FF-8B86-D011-B42D-00C04FC964FF",
  "minGames" : 25,
  "settingsModified" : "2026-10-01T08:30:00.123Z",
  "studyCards" : {
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -" : {
      "added" : 1790000000,
      "ctype" : 2,
      "due" : 2470,
      "easeFactor" : 2500,
      "id" : 12345,
      "interval" : 3,
      "lapses" : 0,
      "lastReviewTime" : 1790000000,
      "memory" : {
        "difficulty" : 5.5,
        "stability" : 3.2
      },
      "queue" : 2,
      "remainingSteps" : 0,
      "reps" : 2
    }
  },
  "targetGames" : 500
}"#;
    let s = Sidecar::decode(json.as_bytes()).unwrap();
    assert_eq!(s.version, 1);
    assert_eq!(s.settings_modified.to_string(), "2026-10-01T08:30:00.123Z");
    let card = &s.study_cards[&start()];
    assert_eq!(
        (card.ctype, card.queue, card.interval),
        (CardType::Review, CardQueue::Review, 3)
    );
    assert_eq!(card.memory.unwrap().stability, 3.2);
    assert_eq!(s.config_key(), "lichess:blitz:1600,1800|500|25|white");
    // Writing it again keeps every value.
    assert_eq!(Sidecar::decode(&s.encoded()).unwrap(), s);
}

fn white_tree() -> RepertoireTree {
    let mut tree = RepertoireTree::default();
    tree.add("e4 c5 Nf3 d6 d4");
    tree.add("e4 c5 Nf3 Nc6 d4");
    tree.add("e4 e5 Nf3");
    tree.add("e4 e5 Bc4"); // alternative of yours: not trained
    tree
}

#[test]
fn progress_groups() {
    let tree = white_tree();
    let t = trainer(&tree, Side::White);
    let epds: Vec<Epd> = t
        .card_nodes(ROOT)
        .iter()
        .map(|&id| tree[id].epd.clone())
        .collect();
    let mut cards = HashMap::new();
    cards.insert(
        epds[0].clone(),
        Card {
            ctype: CardType::Learn,
            ..Card::new(1, 0, 0)
        },
    );
    cards.insert(
        epds[1].clone(),
        Card {
            ctype: CardType::Review,
            interval: 5,
            ..Card::new(2, 1, 0)
        },
    );
    cards.insert(
        epds[2].clone(),
        Card {
            ctype: CardType::Review,
            interval: 30,
            ..Card::new(3, 2, 0)
        },
    );
    let p = t.progress(ROOT, &cards);
    assert_eq!(
        p,
        Progress {
            cards: 5,
            learning: 1,
            young: 1,
            mature: 1,
            suspended: 0
        }
    );
    assert_eq!(p.not_studied(), 2);
}

#[test]
fn next_due_after_today() {
    let timing = SchedTiming::new(10, 100_000, 50_000);
    let mut sidecar = new_sidecar(Side::White);
    let mut review = Card {
        ctype: CardType::Review,
        queue: CardQueue::Review,
        due: 12,
        ..Card::new(1, 0, 0)
    };
    sidecar.study_cards.insert(start(), review.clone());
    assert_eq!(sidecar.next_due(&timing), Some(186_400));
    let learning = Card {
        ctype: CardType::Learn,
        queue: CardQueue::Learn,
        due: 60_000,
        ..Card::new(2, 1, 0)
    };
    sidecar.study_cards.insert(after_e4(), learning);
    assert_eq!(sidecar.next_due(&timing), Some(60_000));
    let p = sidecar.estimated_progress();
    assert!(p.learning == 1 && p.young == 1);
    assert_eq!(sidecar.later_learning_dues(&timing), [60_000]);
    assert_eq!(sidecar.due_tomorrow(&timing), 0);
    review.due = 11;
    sidecar.study_cards.insert(start(), review);
    assert_eq!(sidecar.due_tomorrow(&timing), 1);
}

#[test]
fn alternatives_are_suspended_and_keep_progress() {
    let mut tree = white_tree();
    // white_tree: after 1.e4 e5 the main move is Nf3, Bc4 is an alternative.
    tree.add("e4 e5 Bc4 Nf6 d3");
    let t = trainer(&tree, Side::White);
    let epd = tree[tree.find("e4 e5 Bc4 Nf6").unwrap()].epd.clone();
    assert_eq!(t.suspended_card_epds(ROOT), HashSet::from([epd.clone()]));
    assert_eq!(t.progress(ROOT, &HashMap::new()).suspended, 1);

    // A studied card on the main line, then the line becomes an alternative and back.
    let mut sidecar = new_sidecar(Side::White);
    let review = Card {
        ctype: CardType::Review,
        queue: CardQueue::Review,
        interval: 30,
        due: 100,
        ..Card::new(1, 0, 0)
    };
    sidecar.study_cards.insert(epd.clone(), review.clone());
    assert!(sidecar.sync_suspension(&t.card_epds(ROOT)));
    assert_eq!(sidecar.study_cards[&epd].queue, CardQueue::Suspended);
    assert_eq!(sidecar.estimated_progress().mature, 0);
    assert!(sidecar.sync_suspension(&HashSet::from([epd.clone()])));
    assert_eq!(sidecar.study_cards[&epd], review);
    assert!(!sidecar.sync_suspension(&HashSet::from([epd])));
}

#[test]
fn cards_and_lines() {
    let tree = white_tree();
    let t = trainer(&tree, Side::White);
    // root, after c5, after c5 Nf3 d6, after Nc6, after e5
    assert_eq!(t.card_nodes(ROOT).len(), 5);
    assert_eq!(t.all_lines(ROOT).len(), 3);
    assert_eq!(t.all_lines(tree.find("e4 c5").unwrap()).len(), 2);
}

#[test]
fn new_card_order_is_a_line_at_a_time() {
    let mut tree = RepertoireTree::default();
    tree.add("e4 c5 Nf3 d6 d4");
    tree.add("e4 c5 Nf3 Nc6 d4");
    tree.add("e4 e5 Nf3");
    let t = trainer(&tree, Side::White);
    // e5 reached more often than c5: its line comes first
    let reach = HashMap::from([
        (tree.find("e4 e5").unwrap(), 0.5),
        (tree.find("e4 c5").unwrap(), 0.3),
        (tree.find("e4 c5 Nf3 d6").unwrap(), 0.2),
        (tree.find("e4 c5 Nf3 Nc6").unwrap(), 0.1),
    ]);
    let epd = |line: &str| tree[tree.find(line).unwrap()].epd.clone();
    assert_eq!(
        t.new_card_order(ROOT, &reach),
        [
            start(),
            epd("e4 e5"),
            epd("e4 c5"),
            epd("e4 c5 Nf3 d6"),
            epd("e4 c5 Nf3 Nc6")
        ]
    );
}

fn timing() -> SchedTiming {
    SchedTiming::new(100, 1_000_000 + 16 * 3600, 1_000_000)
}

#[test]
fn new_line_introduces_every_new_move() {
    let mut tree = RepertoireTree::default();
    tree.add("e4 c5 Nf3 d6 d4");
    tree.add("e4 e5 Nf3");
    let t = trainer(&tree, Side::White);
    let limits = RemainingLimits {
        review: 200,
        new: 1,
        cap_new_to_review: true,
    };
    let none = HashMap::new();
    let mut session = StudySession::daily(
        t,
        PracticeMode::CompleteLinesOncePerSession,
        &none,
        limits,
        &timing(),
        1200,
        HashMap::new(),
    );
    assert_eq!(session.queue.counts.new, 1);
    let line = session.next_line(&none).unwrap();
    // the limit allows one new card, but the line it starts is finished: e4, Nf3, d4
    let introduced = line
        .roles
        .values()
        .filter(|r| **r == MoveRole::Answer(AnswerKind::Introduce))
        .count();
    assert_eq!(introduced, 3);
    assert_eq!(
        tree[*line.nodes.last().unwrap()].mv.as_ref().unwrap().san,
        "d4"
    );
}

#[test]
fn review_line_roles_by_practice_mode() {
    let mut tree = RepertoireTree::default();
    tree.add("e4 c5 Nf3 d6 d4");
    let t = timing();
    let review_card = |epd: &Epd, due: i64| Card {
        due,
        ..answer(epd, 0, Rating::Easy, &t)
    };
    let e4 = start();
    let nf3 = tree[tree.find("e4 c5").unwrap()].epd.clone();
    let d4 = tree[tree.find("e4 c5 Nf3 d6").unwrap()].epd.clone();
    // only the last move is due
    let cards = HashMap::from([
        (e4.clone(), review_card(&e4, 150)),
        (nf3.clone(), review_card(&nf3, 150)),
        (d4.clone(), review_card(&d4, 90)),
    ]);
    let limits = RemainingLimits {
        review: 200,
        new: 20,
        cap_new_to_review: true,
    };
    let session = |mode| {
        StudySession::daily(
            trainer(&tree, Side::White),
            mode,
            &cards,
            limits,
            &t,
            1200,
            HashMap::new(),
        )
    };
    let queued = MoveRole::Answer(AnswerKind::Queued);
    let ahead = MoveRole::Answer(AnswerKind::ReviewAhead);

    let a = session(PracticeMode::IndividualMoves)
        .next_line(&cards)
        .unwrap();
    assert_eq!(
        (a.roles[&0], a.roles[&2], a.roles[&4]),
        (MoveRole::Auto, MoveRole::Auto, queued)
    );

    let b = session(PracticeMode::CompleteLinesEveryTime)
        .next_line(&cards)
        .unwrap();
    assert_eq!((b.roles[&0], b.roles[&4]), (ahead, queued));

    let mut once = session(PracticeMode::CompleteLinesOncePerSession);
    once.did_play(&e4);
    let c = once.next_line(&cards).unwrap();
    assert_eq!((c.roles[&0], c.roles[&2]), (MoveRole::Auto, ahead));
}

#[test]
fn next_line_takes_back_when_shorter() {
    let mut tree = RepertoireTree::default();
    tree.add("e4 c5 Nf3 d6 d4 cxd4 Nxd4 Nf6 Nc3 a6 Be3");
    tree.add("e4 c5 Nf3 d6 d4 cxd4 Nxd4 Nf6 Nc3 g6 Be3");
    tree.add("e4 e5 Nf3");
    let previous = tree.path(
        tree.find("e4 c5 Nf3 d6 d4 cxd4 Nxd4 Nf6 Nc3 a6 Be3")
            .unwrap(),
    );
    let dragon = tree.path(
        tree.find("e4 c5 Nf3 d6 d4 cxd4 Nxd4 Nf6 Nc3 g6 Be3")
            .unwrap(),
    );
    let e5 = tree.path(tree.find("e4 e5 Nf3").unwrap());
    let line = |nodes: &[NodeId], asked: usize| {
        let mut roles = BTreeMap::new();
        for i in (0..nodes.len() - 1).step_by(2) {
            roles.insert(
                i,
                if i == asked {
                    MoveRole::Answer(AnswerKind::Queued)
                } else {
                    MoveRole::Auto
                },
            );
        }
        StudyLine {
            nodes: nodes.to_vec(),
            roles,
            target: tree[nodes[asked]].epd.clone(),
        }
    };
    // parts after 9 moves, 2 to take back: take back to move 9
    assert_eq!(line(&dragon, 10).resume_index(&previous, 11), Some(9));
    // parts after 1 move: replay from move 1
    assert_eq!(line(&e5, 2).resume_index(&previous, 11), None);
    // a move you play before the split must be replayed: to move 4 is 7 back, 4 forward
    assert_eq!(line(&dragon, 4).resume_index(&previous, 11), None);
    assert_eq!(line(&dragon, 8).resume_index(&previous, 11), Some(8));
}

#[test]
fn a_line_already_shown_starts_five_half_moves_before_your_move() {
    let mut tree = RepertoireTree::default();
    tree.add("e4 c5 Nf3 d6 d4 cxd4 Nxd4 Nf6 Nc3 g6 Be3");
    let nodes = tree.path(
        tree.find("e4 c5 Nf3 d6 d4 cxd4 Nxd4 Nf6 Nc3 g6 Be3")
            .unwrap(),
    );
    let line = |asked: usize| {
        let mut roles = BTreeMap::new();
        for i in (0..nodes.len() - 1).step_by(2) {
            let role = if i == asked {
                MoveRole::Answer(AnswerKind::Queued)
            } else {
                MoveRole::Auto
            };
            roles.insert(i, role);
        }
        StudyLine {
            nodes: nodes.clone(),
            roles,
            target: tree[nodes[asked]].epd.clone(),
        }
    };
    let shown_to = |index: usize| nodes[..=index].iter().copied().collect::<HashSet<_>>();
    // not shown yet: from move 1
    assert_eq!(line(10).skip_index(&HashSet::new()), 0);
    // shown as far as 3. d4: start there, cxd4 Nxd4 Nf6 Nc3 g6 are played, then Be3 is asked
    assert_eq!(line(10).skip_index(&shown_to(5)), 5);
    assert_eq!(line(10).skip_index(&shown_to(9)), 5);
    // shown, but not as far as 5 half-moves before: from move 1
    assert_eq!(line(10).skip_index(&shown_to(4)), 0);
    // your move within 5 half-moves of the start: from move 1
    assert_eq!(line(4).skip_index(&shown_to(9)), 0);
}

#[test]
fn line_run_and_alternatives() {
    let tree = white_tree();
    let t = trainer(&tree, Side::White);
    let lines = t.all_lines(ROOT);
    let mut run = LineRun::new(t.clone(), lines[0].clone(), 0);
    assert!(run.is_own_turn());
    let expected = run.expected().unwrap().clone();
    assert_eq!(run.user_played("d2d4"), LineOutcome::Wrong { expected });
    assert_eq!(run.user_played("e2e4"), LineOutcome::Correct);
    assert!(run.advance().is_some());

    let after_e5 = tree.find("e4 e5").unwrap();
    let mut nodes = tree.path(after_e5);
    nodes.push(tree[after_e5].children[0]);
    let mut alt = LineRun::new(t, nodes, 0);
    while alt.current_node() != after_e5 {
        alt.advance();
    }
    assert_eq!(alt.user_played("f1c4"), LineOutcome::Alternative);
}

// TranspositionTests.swift (training parts)

#[test]
fn training_continues_through_transposition() {
    let tree = RepertoireTree::from_pgn(
        "1. d4 d5 2. c4 (2. Nf3 Nf6 3. c4 c6 4. Nc3 (4. e3 Bf5) e6) c6 3. Nf3 Nf6 4. Nc3 e6 *",
    );
    let t = trainer(&tree, Side::Black);
    let nf3 = tree.find("d4 d5 Nf3").unwrap();
    let lines = t.all_lines(nf3);
    let sans: Vec<Vec<&str>> = lines
        .iter()
        .map(|l| {
            l.iter()
                .filter_map(|&n| tree[n].mv.as_ref().map(|m| m.san.as_str()))
                .collect()
        })
        .collect();
    assert!(sans.contains(&vec!["d4", "d5", "Nf3", "Nf6", "c4", "c6", "Nc3", "e6"]));
    assert!(sans.contains(&vec!["d4", "d5", "Nf3", "Nf6", "c4", "c6", "e3", "Bf5"]));
    // The transposed continuation's cards count toward the branch.
    let after_e3 = tree.find("d4 d5 c4 c6 Nf3 Nf6 e3").unwrap();
    assert!(t.card_nodes(nf3).contains(&after_e3));
    // A drill along the transposed line expects the stored move.
    let line = lines
        .iter()
        .find(|l| l.contains(&after_e3))
        .unwrap()
        .clone();
    let mut drill = LineRun::new(t, line, 0);
    while !drill.is_finished() {
        if drill.is_own_turn() {
            let uci = drill.expected().unwrap().uci.clone();
            assert_eq!(drill.user_played(&uci), LineOutcome::Correct);
        } else {
            drill.advance();
        }
    }
}

#[test]
fn each_transposed_continuation_is_drilled_once() {
    // Three move orders into the same position: the continuation is drilled once.
    let tree = RepertoireTree::from_pgn(
        "1. d4 d5 2. c4 (2. Nf3 Nf6 3. c4 c6 4. Nc3) (2. Bf4 Nf6 3. Nf3 c6 4. c4) c6 3. Nf3 Nf6 4. Nc3 *",
    );
    let lines = trainer(&tree, Side::Black).all_lines(ROOT);
    let through_nc3 = lines
        .iter()
        .filter(|l| {
            l.iter()
                .any(|&n| tree[n].mv.as_ref().is_some_and(|m| m.san == "Nc3"))
        })
        .count();
    assert_eq!(through_nc3, 1);
    assert_eq!(lines.len(), 3);
}

// Per-branch statistics

#[test]
fn branch_point_follows_a_single_line() {
    use orbt_core::statistics::branch_point;
    // Against 1. e4 only: the branches are where White's second moves part. Replies with no
    // move of yours (1. d4, 2. f4) have nothing to learn.
    let tree =
        RepertoireTree::from_pgn("1. e4 (1. d4) e5 2. Nf3 (2. Bc4 Nf6) (2. f4) Nc6 3. Bb5 Nf6 *");
    let t = trainer(&tree, Side::Black);
    let p = branch_point(&t, ROOT);
    assert_eq!(p.point, tree.find("e4 e5").unwrap());
    let ids: Vec<NodeId> = p.branches.iter().map(|b| b.id).collect();
    assert_eq!(
        ids,
        vec![
            tree.find("e4 e5 Nf3").unwrap(),
            tree.find("e4 e5 Bc4").unwrap()
        ]
    );
    assert_eq!(p.branches[1].text, "2. Bc4");
    // A branch that never parts again has none.
    assert!(branch_point(&t, p.branches[0].id).branches.is_empty());

    // Several first moves branch at the start; your alternatives are not branches.
    let tree = RepertoireTree::from_pgn("1. d4 (1. c4 c6 2. d4) d5 (1... Nf6 2. c4) 2. c4 *");
    let p = branch_point(&trainer(&tree, Side::Black), ROOT);
    assert_eq!(p.point, ROOT);
    assert_eq!(p.branches.len(), 2);
    let p = branch_point(&trainer(&tree, Side::White), ROOT);
    assert_eq!(p.point, tree.find("d4").unwrap());
    let ids: Vec<NodeId> = p.branches.iter().map(|b| b.id).collect();
    assert_eq!(
        ids,
        vec![tree.find("d4 d5").unwrap(), tree.find("d4 Nf6").unwrap()]
    );
    assert_eq!(p.branches[1].text, "1... Nf6");
}

#[test]
fn branch_point_continues_through_transposition() {
    use orbt_core::statistics::branch_point;
    let tree = RepertoireTree::from_pgn(
        "1. d4 d5 2. c4 (2. Nf3 Nf6 3. c4 c6 4. Nc3 (4. e3 Bf5) e6) c6 3. Nf3 Nf6 4. Nc3 e6 *",
    );
    let t = trainer(&tree, Side::Black);
    let p = branch_point(&t, tree.find("d4 d5 Nf3").unwrap());
    // The position's lines are stored once, wherever the merge put them.
    assert_eq!(
        tree[p.point].epd,
        tree[tree.find("d4 d5 c4 c6 Nf3 Nf6").unwrap()].epd
    );
    assert_eq!(p.branches.len(), 2);
}
