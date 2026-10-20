//! A Lichess explorer answer: decode it for a position, then compute coverage with it.
#![no_main]

use std::collections::HashMap;

use libfuzzer_sys::fuzz_target;
use ot_core::chess::Side;
use ot_core::coverage::{CoverageEngine, CoverageSettings};
use ot_core::explorer::queue::decode_stats;
use ot_core::repertoire::RepertoireTree;

fuzz_target!(|data: &[u8]| {
    let tree = RepertoireTree::from_pgn(ot_fuzz::PGN);
    let mut stats = HashMap::new();
    for node in tree.nodes().take(8) {
        if let Some(s) = decode_stats(data, &node.epd) {
            stats.insert(node.epd.clone(), s);
        }
    }
    if stats.is_empty() {
        return;
    }
    ot_fuzz::coverage(&tree, &stats);
    let engine = CoverageEngine::new(CoverageSettings::new(Side::White, 100, 1));
    for (epd, s) in &stats {
        for reply in engine.draft_replies(epd, s, Some(1.0)) {
            assert!(reply.share.is_finite() && reply.reach.is_finite());
        }
    }
    ot_fuzz::exercise_document(ot_fuzz::PGN, &ot_fuzz::sidecar(Side::White), &stats, 200);
});
