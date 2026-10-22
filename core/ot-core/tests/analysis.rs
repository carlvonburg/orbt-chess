//! The analysis board's tree: variations, promoting, deleting, the move list and PGN.

use ot_core::analysis::{AnalysisLine, AnalysisTree, NodeEval, ROOT};
use ot_core::chess::{ChessPosition, Side};

fn tree(moves: &[&str]) -> AnalysisTree {
    let line: Vec<String> = moves.iter().map(|m| (*m).to_owned()).collect();
    AnalysisTree::new(ChessPosition::START_FEN, &line, Side::White).unwrap()
}

fn text(lines: &[AnalysisLine]) -> Vec<String> {
    lines
        .iter()
        .map(|line| {
            let moves: Vec<String> = line
                .moves
                .iter()
                .map(|m| match &m.number {
                    Some(n) => format!("{n} {}", m.san),
                    None => m.san.clone(),
                })
                .collect();
            format!("{}{}", "  ".repeat(line.depth as usize), moves.join(" "))
        })
        .collect()
}

#[test]
fn starts_at_the_end_of_the_line() {
    let t = tree(&["e2e4", "e7e5", "g1h3"]);
    assert_eq!(t.position().epd(), {
        let p = ChessPosition::start();
        let p = p.play_san("e4").unwrap().1.play_san("e5").unwrap().1;
        p.play_san("Nh3").unwrap().1.epd()
    });
    assert_eq!(t.last_move().unwrap().san, "Nh3");
    assert_eq!(t.moves_to_board().len(), 3);
}

#[test]
fn variations_in_the_move_list() {
    let mut t = tree(&["e2e4", "e7e5", "g1h3", "d7d5"]);
    // 2. Nf3 d5 as a variation of 2. Nh3.
    let e5 = t.path(t.current())[1];
    t.go(e5);
    t.play_uci("g1f3").unwrap();
    let d5 = t.play_uci("d7d5").unwrap();
    assert_eq!(
        text(&t.lines()),
        ["1. e4 e5 2. Nh3", "  2. Nf3 d5", "2… d5"]
    );
    assert!(t.lines()[1].moves[1].is_current);
    assert!(!t.is_main_line(d5));

    // Playing a move that is there follows it.
    t.go(e5);
    let nh3 = t.play_uci("g1h3").unwrap();
    assert!(t.is_main_line(nh3));
    assert_eq!(t.lines().len(), 3);
}

#[test]
fn promote_and_make_main_line() {
    let mut t = tree(&["e2e4", "e7e5", "g1f3", "b8c6"]);
    let e5 = t.path(t.current())[1];
    let nf3 = t.path(t.current())[2];
    t.go(e5);
    t.play_uci("f1c4").unwrap();
    t.go(nf3);
    t.play_uci("g8f6").unwrap();
    t.play_uci("d2d4").unwrap();
    // A variation inside a variation-free line: Nf6 is the variation of Nc6.
    let d4 = t.current();
    assert!(t.promote(d4));
    assert_eq!(
        text(&t.lines()),
        ["1. e4 e5 2. Nf3", "  2. Bc4", "2… Nf6", "  2… Nc6", "3. d4"]
    );

    // Bc4 to the main line.
    t.go(e5);
    let bc4 = t.play_uci("f1c4").unwrap();
    assert!(t.make_main_line(bc4));
    assert!(t.is_main_line(bc4));
    assert!(!t.make_main_line(bc4));
    assert_eq!(t.line_pgn(bc4), "1. e4 e5 2. Bc4 *");
}

#[test]
fn delete_from_here() {
    let mut t = tree(&["e2e4", "e7e5", "g1f3", "b8c6"]);
    let nf3 = t.path(t.current())[2];
    assert!(t.delete_from(nf3));
    assert_eq!(t.moves_to_board().len(), 2);
    assert_eq!(text(&t.lines()), ["1. e4 e5"]);
    assert!(!t.delete_from(ROOT));
    // Ids of deleted moves are gone.
    assert!(!t.go(nf3));
}

#[test]
fn pgn_with_variations_and_evals() {
    let mut t = tree(&["d2d4", "d7d5", "c2c4"]);
    let d5 = t.path(t.current())[1];
    t.go(d5);
    t.play_uci("g1f3").unwrap();
    assert_eq!(t.pgn(), "1. d4 d5 2. c4 (2. Nf3) *");
    t.set_eval(
        d5,
        NodeEval {
            text: "+0.3".into(),
            depth: 20,
        },
    );
    t.set_eval(
        d5,
        NodeEval {
            text: "+0.1".into(),
            depth: 12,
        },
    );
    assert_eq!(t.eval(d5).unwrap().text, "+0.3");
    assert_eq!(t.lines()[0].moves[1].eval.as_deref(), Some("+0.3"));
}

#[test]
fn starts_from_a_fen_and_stops_at_an_illegal_move() {
    let fen = "r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3";
    let line = vec!["f1b5".to_owned(), "e2e4".to_owned(), "a7a6".to_owned()];
    let t = AnalysisTree::new(fen, &line, Side::Black).unwrap();
    assert_eq!(t.moves_to_board().len(), 1);
    assert_eq!(text(&t.lines()), ["3. Bb5"]);
    assert!(t.pgn().starts_with("[SetUp \"1\"]\n[FEN \""));
    assert!(t.pgn().ends_with("3. Bb5 *"));
}

#[test]
fn a_long_line_does_not_recurse() {
    let mut t = tree(&[]);
    for _ in 0..2000 {
        for uci in ["g1f3", "g8f6", "f3g1", "f6g8"] {
            t.play_uci(uci).unwrap();
        }
    }
    assert_eq!(t.lines()[0].moves.len(), 8000);
    assert!(t.pgn().len() > 8000);
    t.delete_from(t.path(t.current())[0]);
    assert!(t.lines().is_empty());
}
