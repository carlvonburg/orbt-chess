//! A Lichess explorer answer: decode it for a position, then compute coverage with it.
#![no_main]

use std::collections::HashMap;

use libfuzzer_sys::fuzz_target;
use orbt_core::chess::Side;
use orbt_core::coverage::{CoverageEngine, CoverageSettings};
use orbt_core::explorer::queue::decode_stats;
use orbt_core::repertoire::RepertoireTree;

fuzz_target!(|data: &[u8]| {
    let tree = RepertoireTree::from_pgn(orbt_fuzz::PGN);
    let mut stats = HashMap::new();
    for node in tree.nodes().take(8) {
        if let Some(s) = decode_stats(data, &node.epd) {
            stats.insert(node.epd.clone(), s);
        }
    }
    if stats.is_empty() {
        return;
    }
    orbt_fuzz::coverage(&tree, &stats);
    let engine = CoverageEngine::new(CoverageSettings::new(Side::White, 100, 1));
    for (epd, s) in &stats {
        for reply in engine.draft_replies(epd, s, Some(1.0)) {
            assert!(reply.share.is_finite() && reply.reach.is_finite());
        }
    }
    orbt_fuzz::exercise_document(orbt_fuzz::PGN, &orbt_fuzz::sidecar(Side::White), &stats, 200);
});
