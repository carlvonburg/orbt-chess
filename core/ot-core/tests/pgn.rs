//! Ported from OpeningCore/Tests/OpeningCoreTests/PGNTests.swift (parser and writer; the tree
//! round trips are in repertoire.rs).

use ot_core::pgn;

pub const SAMPLE: &str = r#"[Event "Sicilian: Chapter 1"]
[Site "https://lichess.org/study/abc"]
[Result "*"]

{ Intro comment } 1. e4 c5 2. Nf3 { [%cal Gd2d4] Main move } (2. c3!? { Alapin } d5 3. exd5 Qxd5 4. d4) (2. d4 cxd4 3. c3) 2... d6 $1 3. d4 cxd4 4. Nxd4 Nf6 5. Nc3 a6 *

[Event "Sicilian: Chapter 2"]
[Result "*"]

1. e4 c5 2. Nf3 Nc6 ; line comment
3. Bb5 *"#;

#[test]
fn parses_games_variations_comments_and_nags() {
    let games = pgn::parse(SAMPLE);
    assert_eq!(games.len(), 2);
    let g = &games[0];
    assert_eq!(g.tag("Event"), Some("Sicilian: Chapter 1"));
    assert_eq!(g.comments, ["Intro comment"]);
    let nf3 = &g.moves[0].children[0].children[0];
    assert_eq!(nf3.san, "Nf3");
    assert_eq!(nf3.comments, ["[%cal Gd2d4] Main move"]);
    let alternatives = &g.moves[0].children[0].children;
    let sans: Vec<&str> = alternatives.iter().map(|m| m.san.as_str()).collect();
    assert_eq!(sans, ["Nf3", "c3", "d4"]);
    assert_eq!(alternatives[1].nags, [5]);
    assert_eq!(alternatives[1].comments, ["Alapin"]);
    assert_eq!(nf3.children[0].san, "d6");
    assert_eq!(nf3.children[0].nags, [1]);
    assert_eq!(
        games[1].moves[0].children[0].children[0].children[0].comments,
        ["line comment"]
    );
}

#[test]
fn writer_numbers_black_moves_after_variations() {
    let text = pgn::write_game(&pgn::parse("1. e4 e5 (1... c5) 2. Nf3 *")[0]);
    assert_eq!(text, "1. e4 e5 (1... c5) 2. Nf3 *");
    let after_comment = pgn::write_game(&pgn::parse("1. e4 {best} e5 *")[0]);
    assert_eq!(after_comment, "1. e4 { best } 1... e5 *");
}

// Beyond the Swift tests.

#[test]
fn comment_after_open_paren_is_a_pre_comment() {
    let g = &pgn::parse("1. e4 e5 ({ Sicilian } 1... c5) *")[0];
    let c5 = &g.moves[0].children[1];
    assert_eq!(c5.san, "c5");
    assert_eq!(c5.pre_comments, ["Sicilian"]);
    assert_eq!(pgn::write_game(g), "1. e4 e5 ({ Sicilian } 1... c5) *");
}

#[test]
fn tags_escape_and_games_split_without_result() {
    let games = pgn::parse("[Event \"A \\\"quoted\\\" name\"]\n1. d4\n[Event \"B\"]\n1. c4 *");
    assert_eq!(games.len(), 2);
    assert_eq!(games[0].tag("Event"), Some("A \"quoted\" name"));
    assert_eq!(games[0].result, "*");
    let written = pgn::write_games(&games);
    assert!(written.starts_with("[Event \"A \\\"quoted\\\" name\"]\n\n1. d4 *\n\n[Event \"B\"]"));
}

#[test]
fn wraps_at_eighty_columns() {
    let line = (1..=30)
        .map(|n| format!("{n}. Nf3 Nf6 {n}... Ng1"))
        .collect::<Vec<_>>()
        .join(" ");
    let text = pgn::write_game(&pgn::parse(&format!("{line} *"))[0]);
    assert!(text.lines().all(|l| l.chars().count() <= 80));
    assert!(text.lines().count() > 1);
}

#[test]
fn start_ply_from_fen() {
    assert_eq!(pgn::start_ply(None), 0);
    assert_eq!(pgn::start_ply(Some("8/8/8/4k3/8/8/4P3/4K3 b - - 0 12")), 23);
}

#[test]
fn a_closing_brace_in_a_comment_is_dropped_when_written() {
    // A ";" comment can contain "}", which would end a "{ }" comment early.
    let games = pgn::parse("1. e4 ; best } by test\n1... e5 *");
    assert_eq!(games[0].moves[0].comments, ["best } by test"]);
    let written = pgn::write_games(&games);
    assert_eq!(written, "1. e4 { best  by test } 1... e5 *\n");
    assert_eq!(pgn::write_games(&pgn::parse(&written)), written);
}
