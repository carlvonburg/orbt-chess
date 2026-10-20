//! Ported from RepertoireTreeTests.swift, the tree parts of PGNTests.swift and the tree
//! parts of TranspositionTests.swift.

mod common;

use common::TreeExt;
use ot_core::pgn;
use ot_core::repertoire::RepertoireTree;

const ROOT: u32 = RepertoireTree::ROOT;

#[test]
fn add_reuses_delete_promote() {
    let mut tree = RepertoireTree::default();
    let e4 = tree.add_move("e2e4", ROOT).unwrap();
    assert_eq!(tree.add_move_san("e4", ROOT), Some(e4));
    let c5 = tree.add_move_san("c5", e4).unwrap();
    let e5 = tree.add_move_san("e5", e4).unwrap();
    assert_eq!(tree[e4].children, [c5, e5]);
    tree.promote(e5);
    assert_eq!(tree[e4].children, [e5, c5]);
    let nf3 = tree.add_move_san("Nf3", c5).unwrap();
    tree.delete(c5);
    assert!(tree.get(nf3).is_none());
    assert_eq!(tree.count(), 3);
    assert_eq!(tree.epd_index().values().flatten().count(), 3);
}

#[test]
fn new_moves_go_to_parents_chapter() {
    let mut tree =
        RepertoireTree::from_pgn("[Event \"A\"]\n\n1. e4 e5 *\n\n[Event \"B\"]\n\n1. d4 d5 *");
    let d4 = tree.child_by_san(ROOT, "d4").unwrap();
    let d5 = tree.child_by_san(d4, "d5").unwrap();
    tree.add_move_san("c4", d5);
    let games = pgn::parse(&tree.pgn_text());
    let first: Vec<&str> = games[0].moves.iter().map(|m| m.san.as_str()).collect();
    assert_eq!(first, ["e4"]);
    let after_d5: Vec<&str> = games[1].moves[0].children[0]
        .children
        .iter()
        .map(|m| m.san.as_str())
        .collect();
    assert_eq!(after_d5, ["c4"]);
}

#[test]
fn notes_keep_commands() {
    let mut tree = RepertoireTree::from_pgn("1. e4 { [%cal Ge2e4] old } *");
    let e4 = tree.child_by_san(ROOT, "e4").unwrap();
    assert_eq!(tree[e4].note(), "old");
    tree.set_note("new idea", e4);
    assert_eq!(tree[e4].comments, ["[%cal Ge2e4] new idea"]);
}

#[test]
fn transposition_index() {
    let mut tree = RepertoireTree::default();
    let a = tree
        .add_line(&["d2d4", "g8f6", "c2c4", "e7e6"], ROOT)
        .unwrap();
    let b = tree
        .add_line(&["c2c4", "e7e6", "d2d4", "g8f6"], ROOT)
        .unwrap();
    let mut ids = tree.nodes_at(&tree[a].epd).to_vec();
    ids.sort();
    assert_eq!(ids, [a, b]);
}

#[test]
fn union_of_concurrent_edits() {
    let base = "1. e4 e5 2. Nf3 *";
    let mut local = RepertoireTree::from_pgn(base);
    local.add("e4 c5 Nf3");
    let mut remote = RepertoireTree::from_pgn(base);
    remote.add("e4 e6 d4");
    local.merge_tree(&remote);
    assert!(local.find("e4 c5 Nf3").is_some());
    assert!(local.find("e4 e6 d4").is_some());
    assert_eq!(local.count(), 8);
}

// PGNTests.swift

const SAMPLE: &str = r#"[Event "Sicilian: Chapter 1"]
[Site "https://lichess.org/study/abc"]
[Result "*"]

{ Intro comment } 1. e4 c5 2. Nf3 { [%cal Gd2d4] Main move } (2. c3!? { Alapin } d5 3. exd5 Qxd5 4. d4) (2. d4 cxd4 3. c3) 2... d6 $1 3. d4 cxd4 4. Nxd4 Nf6 5. Nc3 a6 *

[Event "Sicilian: Chapter 2"]
[Result "*"]

1. e4 c5 2. Nf3 Nc6 ; line comment
3. Bb5 *"#;

#[test]
fn round_trips_through_tree() {
    let tree = RepertoireTree::from_pgn(SAMPLE);
    assert!(tree.load_warnings.is_empty());
    assert_eq!(tree.chapters.len(), 2);
    let text = tree.pgn_text();
    let reparsed = RepertoireTree::from_pgn(&text);
    assert_eq!(reparsed.count(), tree.count());
    assert_eq!(reparsed.pgn_text(), text);
    // chapter 2 only contains its own line
    let games = pgn::parse(&text);
    let replies: Vec<&str> = games[1].moves[0].children[0].children[0]
        .children
        .iter()
        .map(|m| m.san.as_str())
        .collect();
    assert_eq!(replies, ["Nc6"]);
    assert!(text.contains("2. c3!? { Alapin }"));
    assert!(text.contains("[%cal Gd2d4] Main move"));
}

#[test]
fn illegal_moves_are_reported_not_fatal() {
    let tree = RepertoireTree::from_pgn("1. e4 e5 2. Ke3 Nc6 (2... Nf6 3. Nc3) *");
    assert_eq!(tree.load_warnings.len(), 1);
    assert_eq!(tree.load_warnings[0], "Illegal move Ke3 after e4 e5");
    assert_eq!(tree.count(), 3); // root, e4, e5
}

#[test]
fn non_standard_start_is_kept_verbatim() {
    let pgn =
        "[Event \"Endgame\"]\n[SetUp \"1\"]\n[FEN \"8/8/8/4k3/8/8/4P3/4K3 w - - 0 1\"]\n\n1. Kd2 *";
    let tree = RepertoireTree::from_pgn(pgn);
    assert_eq!(tree.count(), 1);
    assert!(tree.pgn_text().contains("1. Kd2"));
}

// TranspositionTests.swift (tree parts; coverage and training parts are ported with those modules)

const TRANSPOSING: &str =
    "1. d4 d5 2. c4 (2. Nf3 Nf6 3. c4 c6 4. Nc3 (4. e3 Bf5) e6) c6 3. Nf3 Nf6 4. Nc3 e6 *";

#[test]
fn duplicate_subtree_is_stored_once() {
    let tree = RepertoireTree::from_pgn(TRANSPOSING);
    let main = tree.find("d4 d5 c4 c6 Nf3 Nf6").unwrap();
    let other = tree.find("d4 d5 Nf3 Nf6 c4 c6").unwrap();
    assert!(tree[other].children.is_empty());
    assert_eq!(tree.transposition_target(other), Some(main));
    // Lines from both copies end up at the main node.
    assert!(tree.find("d4 d5 c4 c6 Nf3 Nf6 Nc3 e6").is_some());
    assert!(tree.find("d4 d5 c4 c6 Nf3 Nf6 e3 Bf5").is_some());
    assert!(tree.load_warnings.is_empty());
    assert!(tree.merged_transpositions > 0);
}

#[test]
fn writing_keeps_every_move_order_and_line() {
    let tree = RepertoireTree::from_pgn(TRANSPOSING);
    let reread = RepertoireTree::from_pgn(&tree.pgn_text());
    assert_eq!(reread.count(), tree.count());
    assert!(reread.find("d4 d5 Nf3 Nf6 c4 c6").is_some());
    assert!(reread.find("d4 d5 c4 c6 Nf3 Nf6 e3 Bf5").is_some());
}

#[test]
fn lines_stay_in_their_chapter() {
    let text = "[Event \"A\"]\n\n1. d4 d5 2. c4 c6 3. Nf3 Nf6 4. Nc3 *\n\n[Event \"B\"]\n\n1. d4 d5 2. Nf3 Nf6 3. c4 c6 4. e3 *";
    let tree = RepertoireTree::from_pgn(text);
    let other = tree.find("d4 d5 Nf3 Nf6 c4 c6").unwrap();
    // Chapter B's node keeps its own move, so writing chapter B loses nothing.
    assert_eq!(tree[other].children.len(), 1);
    let games = pgn::parse(&tree.pgn_text());
    assert_eq!(games.len(), 2);
    let b = RepertoireTree::from_games(vec![games[1].clone()]);
    assert!(b.find("d4 d5 Nf3 Nf6 c4 c6 e3").is_some());
}

#[test]
fn shared_pre_comments_stay_in_their_variation() {
    // d4 and c5 start a variation in the first game and the main line in the second.
    let text = "1. e4 ({ pre d4 } 1. d4 d5) 1... e5 ({ pre c5 } 1... c5) *\n\n\
                1. d4 d5 *\n\n1. e4 c5 *\n";
    let tree = RepertoireTree::from_pgn(text);
    let saved = tree.pgn_text();
    assert_eq!(
        saved,
        "1. e4 ({ pre d4 } 1. d4 d5) 1... e5 ({ pre c5 } 1... c5) *\n\n\
         1. d4 d5 *\n\n1. e4 c5 *\n"
    );
    assert_eq!(RepertoireTree::from_pgn(&saved).pgn_text(), saved);
}
