use std::collections::HashMap;

use super::*;
use crate::chess::{ChessPosition, Epd, Side};
use crate::explorer::{ExplorerMove, ExplorerStats};
use crate::formats::{Sidecar, Timestamp};
use crate::repertoire::RepertoireTree;
use crate::training::anki::{CardQueue, Rating, SchedTiming};

const PGN: &str =
    "[Event \"Sicilian\"]\n[Site \"?\"]\n[Result \"*\"]\n\n1. e4 c5 2. Nf3 d6 3. d4 *\n";

fn sidecar(color: Side) -> Vec<u8> {
    Sidecar::new("ID".into(), color, Timestamp(1_000)).encoded()
}

fn no_stats() -> HashMap<Epd, ExplorerStats> {
    HashMap::new()
}

fn open() -> Repertoire {
    Repertoire::open(
        PGN,
        &sidecar(Side::White),
        StudyDefaults::default(),
        &no_stats(),
    )
    .unwrap()
    .0
}

fn timing() -> SchedTiming {
    SchedTiming::new(100, 1_000_000 + 16 * 3600, 1_000_000)
}

fn find(doc: &Repertoire, line: &str) -> u32 {
    let mut cursor = RepertoireTree::ROOT;
    for san in line.split_whitespace() {
        cursor = doc.tree().child_by_san(cursor, san).unwrap();
    }
    cursor
}

#[test]
fn opening_needs_no_save_for_a_compact_file() {
    let (mut doc, changes) = Repertoire::open(
        PGN,
        &sidecar(Side::White),
        StudyDefaults::default(),
        &no_stats(),
    )
    .unwrap();
    assert_eq!(changes.save_pgn_after_ms, None);
    assert!(doc.pgn_to_save().is_none());
    assert_eq!(doc.saved_move_count(), 5);
}

#[test]
fn a_file_with_repeated_subtrees_is_rewritten_compactly() {
    let pgn = "1. d4 d5 2. c4 (2. Nf3 Nf6 3. c4 c6 4. Nc3 e6) c6 3. Nf3 Nf6 4. Nc3 e6 *";
    let (mut doc, changes) = Repertoire::open(
        pgn,
        &sidecar(Side::Black),
        StudyDefaults::default(),
        &no_stats(),
    )
    .unwrap();
    assert_eq!(changes.save_pgn_after_ms, Some(save_delay::PGN_MS));
    let text = doc.pgn_to_save().unwrap();
    assert!(text.len() < pgn.len() + 60);
    doc.pgn_saved(text);
    assert!(doc.pgn_to_save().is_none());
}

#[test]
fn edits_save_undo_and_reuse_moves() {
    let mut doc = open();
    // A line that is already saved changes nothing.
    let d6 = find(&doc, "e4 c5 Nf3 d6");
    let (existing, changes) = doc.add_line(&["d2d4".into()], d6, &no_stats());
    assert_eq!(
        (existing, changes),
        (Some(find(&doc, "e4 c5 Nf3 d6 d4")), Changes::default())
    );

    let nc6 = doc.add_move("b8c6", find(&doc, "e4 c5 Nf3"), &no_stats());
    let (Some(nc6), changes) = nc6 else {
        panic!("move added")
    };
    assert!(changes.tree_changed);
    assert_eq!(changes.save_pgn_after_ms, Some(save_delay::PGN_MS));
    assert_eq!(
        changes.save_sidecar_after_ms,
        Some(save_delay::SIDECAR_AFTER_EDIT_MS)
    );
    assert!(doc.can_undo());
    // The same move again is reused and changes nothing.
    let (again, changes) = doc.add_move("b8c6", find(&doc, "e4 c5 Nf3"), &no_stats());
    assert_eq!((again, changes), (Some(nc6), Changes::default()));

    let text = doc.pgn_to_save().unwrap();
    assert!(text.contains("2... Nc6") || text.contains("(2... Nc6)"));
    doc.pgn_saved(text);

    doc.promote(nc6, &no_stats());
    assert_eq!(doc.tree()[find(&doc, "e4 c5 Nf3")].children[0], nc6);
    doc.delete(nc6, &no_stats());
    assert!(doc.tree().get(nc6).is_none());
    doc.undo(&no_stats());
    assert!(doc.tree().get(nc6).is_some());
    doc.undo(&no_stats());
    doc.undo(&no_stats());
    assert!(doc.tree().get(nc6).is_none());
    assert!(!doc.can_undo());
}

#[test]
fn notes_are_edits_too() {
    let mut doc = open();
    let e4 = find(&doc, "e4");
    let changes = doc.set_note("best by test", e4);
    assert!(changes.tree_changed && changes.save_pgn_after_ms.is_some());
    assert_eq!(doc.tree()[e4].note(), "best by test");
    assert_eq!(doc.set_note("best by test", e4), Changes::default());
    doc.undo(&no_stats());
    assert_eq!(doc.tree()[e4].note(), "");
}

#[test]
fn remote_pgn_replaces_or_merges() {
    let mut doc = open();
    // No local edits pending: the file's version replaces ours.
    let remote = "1. e4 c5 2. Nf3 Nc6 *\n";
    doc.remote_pgn(remote, &no_stats());
    assert!(doc.tree().find_san("e4 c5 Nf3 Nc6").is_some());
    assert!(doc.tree().find_san("e4 c5 Nf3 d6").is_none());
    // A local edit not saved yet: both sides are kept.
    doc.add_move("d7d6", find(&doc, "e4 c5 Nf3"), &no_stats());
    let changes = doc.remote_pgn("1. e4 c5 2. Nf3 Nc6 3. d4 *\n", &no_stats());
    assert!(changes.save_pgn_after_ms.is_some());
    assert!(doc.tree().find_san("e4 c5 Nf3 d6").is_some());
    assert!(doc.tree().find_san("e4 c5 Nf3 Nc6 d4").is_some());
    assert!(!doc.can_undo());
}

#[test]
fn answering_counts_saves_and_logs() {
    let mut doc = open();
    let t = timing();
    let counts = doc.study_counts(&t);
    assert_eq!(counts.new, 3); // e4, Nf3, d4
    let start = ChessPosition::start().epd();
    let (card, changes) = doc.answer(&start, 0, Rating::Good, false, 3000, &t);
    assert_eq!(card.queue, CardQueue::Learn);
    assert_eq!(
        changes.save_sidecar_after_ms,
        Some(save_delay::SIDECAR_AFTER_ANSWER_MS)
    );
    assert_eq!(doc.sidecar().study_stats.unwrap().new_studied, 1);
    assert!(doc.study_counts(&t).learning >= 1);
    let log = doc.revlog_to_append().unwrap();
    assert_eq!(log.iter().filter(|&&b| b == b'\n').count(), 1);
    assert_eq!(doc.review_log(&[]).len(), 1);
    doc.revlog_appended();
    assert!(doc.revlog_to_append().is_none());

    let bytes = doc.sidecar_to_save(&t).unwrap();
    let saved = Sidecar::decode(&bytes).unwrap();
    let summary = saved.summary.unwrap();
    assert_eq!((summary.card_count, summary.saved_move_count), (3, Some(5)));
    doc.sidecar_saved(bytes.clone());
    assert!(doc.sidecar_to_save(&t).is_none());
    // Our own write coming back from disk changes nothing.
    assert_eq!(doc.remote_sidecar(&bytes), Changes::default());
}

#[test]
fn remote_sidecar_merges_cards_and_asks_for_a_recompute_on_new_settings() {
    let mut doc = open();
    let t = timing();
    let start = ChessPosition::start().epd();
    let mut other = Sidecar::decode(&sidecar(Side::White)).unwrap();
    let card = crate::training::anki::Scheduler::default()
        .answer(None, &start, 0, Rating::Good, &t, false, 0, None)
        .card;
    other.study_cards.insert(start.clone(), card);
    let changes = doc.remote_sidecar(&other.encoded());
    assert!(!changes.reload_stats);
    assert!(doc.sidecar().study_cards.contains_key(&start));

    other.target_games = 100;
    other.settings_modified = Timestamp(5_000);
    let changes = doc.remote_sidecar(&other.encoded());
    assert!(changes.reload_stats);
    assert_eq!(doc.sidecar().target_games, 100);
}

#[test]
fn a_remote_sidecar_equal_to_ours_but_its_summary_is_not_written_back() {
    let mut doc = open();
    let t = timing();
    let start = ChessPosition::start().epd();
    doc.answer(&start, 0, Rating::Good, false, 3000, &t);
    let bytes = doc.sidecar_to_save(&t).unwrap();
    doc.sidecar_saved(bytes.clone());

    // Another device with the same cards and settings and a summary of its own coverage.
    let mut other = Sidecar::decode(&bytes).unwrap();
    let mut summary = other.summary.clone().unwrap();
    summary.gap_count += 7;
    summary.completion = 0.25;
    other.summary = Some(summary);
    let changes = doc.remote_sidecar(&other.encoded());
    assert_eq!(changes.save_sidecar_after_ms, None);
    // Nor by a later flush, whose summary would differ from the other device's.
    assert!(doc.sidecar_to_save(&t).is_none());

    // A remote copy without our card is written back with it.
    other.study_cards.remove(&start);
    let changes = doc.remote_sidecar(&other.encoded());
    assert_eq!(changes.save_sidecar_after_ms, Some(save_delay::NOW));
    assert!(doc.sidecar().study_cards.contains_key(&start));
    let bytes = doc.sidecar_to_save(&t).unwrap();
    doc.sidecar_saved(bytes);

    // A local edit refreshes the summary even when only the summary changes (an opponent
    // move adds no card).
    doc.add_move("b8c6", find(&doc, "e4 c5 Nf3"), &no_stats());
    let saved = Sidecar::decode(&doc.sidecar_to_save(&t).unwrap()).unwrap();
    assert!(saved.same_content(doc.sidecar()));
    assert_eq!(saved.summary.unwrap().saved_move_count, Some(6));
}

#[test]
fn coverage_requests_only_while_a_screen_shows() {
    let mut stats = HashMap::new();
    let start = ChessPosition::start();
    let (e4, after_e4) = start.play_san("e4").unwrap();
    let _ = e4;
    stats.insert(
        start.epd(),
        ExplorerStats {
            white: 100,
            draws: 0,
            black: 0,
            moves: vec![ExplorerMove::new("e2e4", "e4", 100, 0, 0)],
            opening: None,
        },
    );
    let (mut doc, _) =
        Repertoire::open(PGN, &sidecar(Side::White), StudyDefaults::default(), &stats).unwrap();
    assert!(doc.coverage_requests().is_empty());
    doc.start_coverage_check();
    let requests = doc.coverage_requests();
    assert_eq!(requests.first().map(|r| &r.0), Some(&after_e4.epd()));
    assert!(doc.stop_coverage_check());
    assert!(doc.coverage_requests().is_empty());
}

#[test]
fn line_text_numbers_moves() {
    let doc = open();
    assert_eq!(doc.line_text(find(&doc, "e4 c5 Nf3")), "1. e4 c5 2. Nf3");
}
