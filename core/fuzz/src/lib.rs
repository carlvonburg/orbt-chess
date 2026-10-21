//! What the fuzz targets do with a decoded file: everything the app does on opening it.

use std::collections::HashMap;

use ot_core::chess::{Epd, Side};
use ot_core::coverage::{CoverageEngine, CoverageSettings};
use ot_core::document::{Repertoire, StudyDefaults, outline_children, search};
use ot_core::drill::{Drill, DrillMode};
use ot_core::explorer::{ExplorerMove, ExplorerStats};
use ot_core::formats::{Sidecar, Timestamp};
use ot_core::repertoire::RepertoireTree;
use ot_core::training::anki::SchedTiming;

/// A small repertoire with variations and a transposition.
pub const PGN: &str = "[Event \"Fuzz\"]\n\n1. e4 e5 (1... c5 2. Nf3 d6 (2... Nc6 3. d4) 3. d4) 2. Nf3 Nc6 3. Bb5 a6 (3... Nf6 4. O-O) 4. Ba4 Nf6 5. O-O *\n\n[Event \"Two\"]\n\n1. Nf3 Nc6 2. e4 e5 3. Bb5 *\n";

pub fn timing() -> SchedTiming {
    SchedTiming::new(100, 1_000_000 + 16 * 3600, 1_000_000)
}

pub fn sidecar(color: Side) -> Vec<u8> {
    Sidecar::new("ID".into(), color, Timestamp(1_000)).encoded()
}

/// Stats for every position in the tree, made up from the position, so replies are
/// required, covered and missing.
pub fn synthetic_stats(tree: &RepertoireTree) -> HashMap<Epd, ExplorerStats> {
    let mut stats = HashMap::new();
    for node in tree.nodes() {
        let moves: Vec<ExplorerMove> = node
            .position
            .legal_moves()
            .into_iter()
            .take(6)
            .enumerate()
            .map(|(i, m)| ExplorerMove::new(&m.uci, &m.san, 100 >> i, 10, 50 >> i))
            .collect();
        let white = moves.iter().map(|m| m.white).sum();
        let black = moves.iter().map(|m| m.black).sum();
        let draws = moves.iter().map(|m| m.draws).sum();
        let s = ExplorerStats {
            white,
            draws,
            black,
            moves,
            opening: None,
        };
        stats.insert(node.epd.clone(), s);
    }
    stats
}

pub fn coverage(tree: &RepertoireTree, stats: &HashMap<Epd, ExplorerStats>) {
    for color in [Side::White, Side::Black] {
        let mut engine = CoverageEngine::new(CoverageSettings::new(color, 100, 1));
        engine.recompute_all(tree, stats);
        let _ = engine.gaps();
        let _ = engine.pending_positions(tree);
    }
}

/// Opens a document and runs what its screens call: outline, search, study counts,
/// progress, a drill, and the save.
pub fn exercise_document(
    pgn: &str,
    sidecar: &[u8],
    stats: &HashMap<Epd, ExplorerStats>,
    drill_steps: usize,
) {
    let Ok((mut doc, _)) = Repertoire::open(pgn, sidecar, StudyDefaults::default(), stats) else {
        return;
    };
    let timing = timing();
    let _ = outline_children(doc.tree(), RepertoireTree::ROOT);
    let _ = search(doc.tree(), "e4", 20);
    let _ = doc.study_counts(&timing);
    let _ = doc.learning_progress(RepertoireTree::ROOT);
    let _ = doc.reach();
    let mut drill = Drill::new(DrillMode::Study);
    drill.start(&mut doc, 0, &timing);
    for i in 0..drill_steps {
        if drill.is_user_turn() {
            let expected = drill.run().and_then(|r| r.expected()).cloned();
            match expected.as_ref().and_then(|m| Some((m.from()?, m.to()?))) {
                // Every third move is wrong, so cards are failed too.
                Some((from, to)) if i % 3 != 0 => {
                    drill.user_moved(&mut doc, from, to, None, &timing, 1_000);
                }
                Some((from, _)) => {
                    drill.user_moved(&mut doc, from, from, None, &timing, 1_000);
                    drill.wrong_timeout();
                }
                None => break,
            }
        } else {
            drill.step(1_000);
            drill.next_line(&doc, &timing);
        }
        let _ = drill.arrows();
    }
    let _ = doc.pgn_to_save();
    if let Some(bytes) = doc.sidecar_to_save(&timing) {
        Sidecar::decode(&bytes).expect("a saved sidecar reads back");
    }
}
