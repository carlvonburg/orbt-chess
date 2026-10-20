//! A PGN file: parse, write, build the tree, write it back, coverage, the document.
#![no_main]

use libfuzzer_sys::fuzz_target;
use ot_core::chess::Side;
use ot_core::pgn;
use ot_core::repertoire::RepertoireTree;

fuzz_target!(|data: &[u8]| {
    let Ok(text) = std::str::from_utf8(data) else {
        return;
    };
    let games = pgn::parse(text);
    let written = pgn::write_games(&games);
    assert_eq!(
        pgn::write_games(&pgn::parse(&written)),
        written,
        "write is stable"
    );

    let tree = RepertoireTree::from_games(games);
    let saved = tree.pgn_text();
    let stats = ot_fuzz::synthetic_stats(&tree);
    ot_fuzz::coverage(&tree, &stats);
    // Opening the saved text: the same tree, and what the app opens from then on.
    let color = if data.len().is_multiple_of(2) {
        Side::White
    } else {
        Side::Black
    };
    ot_fuzz::exercise_document(&saved, &ot_fuzz::sidecar(color), &stats, 30);
});
