//! Ported from OpeningCore/Tests/OpeningCoreTests/ChessTests.swift.

use ot_core::chess::{ChessPosition, Epd, Side};

fn pos(fen: &str) -> ChessPosition {
    ChessPosition::from_fen(fen).expect("valid FEN")
}

#[test]
fn plays_san_and_uci() {
    let (e4, p1) = ChessPosition::start().play_san("e4").unwrap();
    assert_eq!(e4.uci, "e2e4");
    assert_eq!(p1.side_to_move(), Side::Black);
    let (nf6, _) = p1.play_uci("g8f6").unwrap();
    assert_eq!(nf6.san, "Nf6");
}

#[test]
fn tolerant_san() {
    let p = pos("r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3");
    assert_eq!(p.play_san("Bb5!?").unwrap().0.san, "Bb5");
    assert_eq!(p.play_san("Bf1b5").unwrap().0.san, "Bb5");
    assert!(p.play_san("0-0").is_none()); // not legal yet
    let castle = pos("r1bqk1nr/pppp1ppp/2n5/2b1p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4");
    assert_eq!(castle.play_san("0-0").unwrap().0.uci, "e1g1");
    assert_eq!(castle.play_uci("e1h1").unwrap().0.san, "O-O");
}

#[test]
fn check_suffix() {
    let p = pos("rnbqkbnr/ppppp2p/5p2/6p1/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 3");
    assert_eq!(p.play_san("Qh5").unwrap().0.san, "Qh5#");
    assert!(p.play_san("Qh5#").unwrap().1.is_checkmate());
}

#[test]
fn promotion() {
    let p = pos("8/4P3/8/8/8/8/k7/4K3 w - - 0 1");
    assert_eq!(p.play_uci("e7e8n").unwrap().0.san, "e8=N");
    assert_eq!(p.play_san("e8=Q+").unwrap().0.uci, "e7e8q");
}

#[test]
fn epd_drops_counters_and_irrelevant_en_passant() {
    let (_, after_e4) = ChessPosition::start().play_san("e4").unwrap();
    assert!(after_e4.fen().contains(" e3 "));
    assert_eq!(
        after_e4.epd().as_str(),
        "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq -"
    );
    // ep capture possible: white pawn e5, black plays d7d5
    let p = pos("rnbqkbnr/pppppppp/8/4P3/8/8/PPPP1PPP/RNBQKBNR b KQkq - 0 2");
    let (_, after_d5) = p.play_san("d5").unwrap();
    assert!(after_d5.epd().as_str().ends_with(" w KQkq d6"));
}

#[test]
fn transpositions_share_epd() {
    fn play(moves: &[&str]) -> Epd {
        let mut p = ChessPosition::start();
        for m in moves {
            p = p.play_san(m).unwrap().1;
        }
        p.epd()
    }
    assert_eq!(
        play(&["d4", "Nf6", "c4", "e6"]),
        play(&["c4", "e6", "d4", "Nf6"])
    );
}

// Beyond the Swift tests: behaviour the app relies on.

#[test]
fn castling_destination_is_the_kings_square() {
    let p = pos("r1bqk1nr/pppp1ppp/2n5/2b1p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4");
    let king = ot_core::chess::BoardSquare::parse("e1").unwrap();
    let dests: Vec<String> = p
        .legal_destinations(king)
        .iter()
        .map(|s| s.to_string())
        .collect();
    assert!(dests.contains(&"g1".to_owned()));
    assert!(!dests.contains(&"h1".to_owned()));
}

#[test]
fn promotion_defaults_to_queen() {
    let p = pos("8/4P3/8/8/8/8/k7/4K3 w - - 0 1");
    let sq = |s| ot_core::chess::BoardSquare::parse(s).unwrap();
    let (m, _) = p.play(sq("e7"), sq("e8"), None).unwrap();
    assert_eq!(m.uci, "e7e8q");
    assert!(p.is_promotion(sq("e7"), sq("e8")));
}

#[test]
fn epd_side_to_move() {
    assert_eq!(ChessPosition::start().epd().side_to_move(), Side::White);
    let (_, p) = ChessPosition::start().play_san("e4").unwrap();
    assert_eq!(p.epd().side_to_move(), Side::Black);
    assert_eq!(
        p.epd().query_fen(),
        "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"
    );
}
