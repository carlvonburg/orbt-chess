//! Very long lines and deeply nested variations, as a corrupt or hostile file could contain,
//! must not overflow the stack: the app calls the core on threads with small stacks, and an
//! overflow aborts the process on every launch.

mod common;

use std::collections::{HashMap, HashSet};
use std::hash::{DefaultHasher, Hash, Hasher};
use std::sync::OnceLock;

use common::Rng;
use ot_core::chess::{ChessPosition, Epd, PlayedMove, Side};
use ot_core::coverage::{CoverageEngine, CoverageSettings};
use ot_core::document::{Repertoire, StudyDefaults};
use ot_core::explorer::{ExplorerMove, ExplorerStats};
use ot_core::formats::{Sidecar, Timestamp};
use ot_core::pgn;
use ot_core::repertoire::RepertoireTree;
use ot_core::training::anki::SchedTiming;

const PLIES: usize = 100_000;
const STACK: usize = 512 * 1024;

fn on_small_stack(f: impl FnOnce() + Send + 'static) {
    std::thread::Builder::new()
        .stack_size(STACK)
        .spawn(f)
        .expect("spawn")
        .join()
        .expect("no stack overflow or panic");
}

/// A legal line of `PLIES` moves that never repeats a position (a repeated position would be
/// stored as a transposition), with the stats that make every opponent reply required.
fn long_line() -> &'static (Vec<String>, HashMap<Epd, ExplorerStats>) {
    static LINE: OnceLock<(Vec<String>, HashMap<Epd, ExplorerStats>)> = OnceLock::new();
    LINE.get_or_init(|| {
        let mut rng = Rng(7);
        let start = ChessPosition::start();
        let mut seen = HashSet::from([start.epd()]);
        // A depth-first search that backs up from dead ends. Each frame: a position and its
        // untried moves, quiet piece moves last (they are tried first and never run out).
        let mut stack = vec![(start.clone(), candidates(&start, &mut rng))];
        let mut line: Vec<(PlayedMove, ChessPosition)> = Vec::new();
        while line.len() < PLIES {
            let (_, options) = stack.last_mut().expect("the start has moves");
            match options.pop() {
                Some((mv, next)) => {
                    if !seen.insert(next.epd()) {
                        continue;
                    }
                    stack.push((next.clone(), candidates(&next, &mut rng)));
                    line.push((mv, next));
                }
                None => {
                    stack.pop();
                    line.pop();
                }
            }
        }
        let mut stats = HashMap::new();
        let mut position = start;
        for (mv, next) in &line {
            if position.side_to_move() == Side::Black {
                let explorer = ExplorerMove::new(&mv.uci, &mv.san, 10, 0, 0);
                let s = ExplorerStats {
                    white: 10,
                    draws: 0,
                    black: 0,
                    moves: vec![explorer],
                    opening: None,
                };
                stats.insert(position.epd(), s);
            }
            position = next.clone();
        }
        let sans = line.into_iter().map(|(mv, _)| mv.san).collect();
        (sans, stats)
    })
}

fn candidates(position: &ChessPosition, rng: &mut Rng) -> Vec<(PlayedMove, ChessPosition)> {
    let mut moves: Vec<_> = position
        .legal_moves()
        .into_iter()
        .filter_map(|m| position.play_uci(&m.uci))
        .collect();
    for i in (1..moves.len()).rev() {
        moves.swap(i, (rng.next_u64() % (i as u64 + 1)) as usize);
    }
    let quiet = |m: &PlayedMove| !m.san.contains('x') && m.san.starts_with(char::is_uppercase);
    moves.sort_by_key(|(m, _)| quiet(m));
    moves
}

fn hash(value: &impl Hash) -> u64 {
    let mut hasher = DefaultHasher::new();
    value.hash(&mut hasher);
    hasher.finish()
}

#[test]
fn a_long_line_parses_builds_writes_and_computes_coverage() {
    let (sans, stats) = long_line();
    let text = format!("1. {} *", sans.join(" "));
    on_small_stack(move || {
        let games = pgn::parse(&text);
        let copy = games.clone();
        assert_eq!(copy, games);
        assert_eq!(hash(&copy), hash(&games));
        assert!(format!("{:?}", games[0].moves[0]).len() > PLIES);
        drop(copy);

        let tree = RepertoireTree::from_games(games);
        assert_eq!(tree.count(), PLIES + 1);
        assert!(tree.load_warnings.is_empty());
        let written = tree.pgn_text();
        assert_eq!(pgn::write_games(&pgn::parse(&written)), written);

        let mut engine = CoverageEngine::new(CoverageSettings::new(Side::White, 100, 1));
        engine.recompute_all(&tree, stats);
        let root = engine.root().expect("root computed");
        assert_eq!(root.completion, 0.0, "the line ends in a gap");
        assert_eq!(root.gap_count, 1);
    });
}

#[test]
fn deeply_nested_variations_parse_build_and_write() {
    let (sans, _) = long_line();
    // "e4 (e4 e5 (e5 Nf3 (Nf3 ...)))": each variation repeats the move it replaces and opens
    // the next one, so the parentheses nest once per ply; the tree has a single line.
    let mut text = sans[0].clone();
    for pair in sans.windows(2) {
        text += &format!(" ({} {}", pair[0], pair[1]);
    }
    text += &")".repeat(PLIES - 1);
    text += " *";
    on_small_stack(move || {
        let games = pgn::parse(&text);
        assert_eq!(games[0].moves.len(), 2);
        let written = pgn::write_games(&games);
        assert_eq!(pgn::parse(&written), games);
        let tree = RepertoireTree::from_games(games);
        assert_eq!(tree.count(), PLIES + 1);
        assert_eq!(tree.leaves(RepertoireTree::ROOT).len(), 1);
    });
}

#[test]
fn a_long_line_opens_as_a_document_and_trains() {
    let (sans, stats) = long_line();
    let text = format!("1. {} *", sans.join(" "));
    on_small_stack(move || {
        let sidecar = Sidecar::new("ID".into(), Side::White, Timestamp(1_000)).encoded();
        let (mut doc, _) =
            Repertoire::open(&text, &sidecar, StudyDefaults::default(), stats).expect("opens");
        let timing = SchedTiming::new(100, 1_000_000 + 16 * 3600, 1_000_000);
        assert!(doc.study_counts(&timing).new > 0);
        assert!(doc.learning_progress(RepertoireTree::ROOT).cards as usize >= PLIES / 2);
        assert!(doc.pgn_to_save().is_some_and(|t| t.len() > PLIES));
    });
}
