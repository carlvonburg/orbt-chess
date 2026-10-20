//! Timings on a real repertoire, like LargeRepertoireTests.swift. Set OT_LARGE_PGN to a PGN path
//! and run with `cargo test --release --test large_repertoire -- --nocapture`.

use std::time::Instant;

use ot_core::repertoire::RepertoireTree;

#[test]
fn load_and_write_large_pgn() {
    let Ok(path) = std::env::var("OT_LARGE_PGN") else {
        return;
    };
    let text = std::fs::read_to_string(&path).expect("readable PGN");

    let start = Instant::now();
    let tree = RepertoireTree::from_pgn(&text);
    let load = start.elapsed();

    let start = Instant::now();
    let written = tree.pgn_text();
    let write = start.elapsed();

    let reread = RepertoireTree::from_pgn(&written);
    println!(
        "{path}: {} bytes, {} nodes, {} merged transpositions, {} warnings; load {load:?}, write {write:?}",
        text.len(),
        tree.count(),
        tree.merged_transpositions,
        tree.load_warnings.len()
    );
    assert_eq!(reread.count(), tree.count());
    assert_eq!(reread.pgn_text(), written);
}
