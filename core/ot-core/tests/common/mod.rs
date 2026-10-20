//! Helpers shared by the ported tests (from CoverageTests.swift).
#![allow(dead_code)]

use ot_core::repertoire::{NodeId, RepertoireTree};

pub trait TreeExt {
    /// Adds a SAN line from the root; returns its last node.
    fn add(&mut self, line: &str) -> NodeId;
    /// Follows a SAN line from the root.
    fn find(&self, line: &str) -> Option<NodeId>;
}

impl TreeExt for RepertoireTree {
    fn add(&mut self, line: &str) -> NodeId {
        let mut cursor = RepertoireTree::ROOT;
        for san in line.split_whitespace() {
            cursor = self.add_move_san(san, cursor).expect("legal move");
        }
        cursor
    }

    fn find(&self, line: &str) -> Option<NodeId> {
        let mut cursor = RepertoireTree::ROOT;
        for san in line.split_whitespace() {
            cursor = self.child_by_san(cursor, san)?;
        }
        Some(cursor)
    }
}

use std::collections::HashMap;

use ot_core::chess::{ChessPosition, Epd};
use ot_core::explorer::{ExplorerMove, ExplorerStats};

/// Stats keyed by the SAN line that leads to the position.
#[derive(Default)]
pub struct FixtureStats {
    pub by_epd: HashMap<Epd, ExplorerStats>,
}

impl FixtureStats {
    pub fn set(&mut self, line: &str, moves: &[(&str, i64)]) {
        let mut p = ChessPosition::start();
        for san in line.split_whitespace() {
            p = p.play_san(san).expect("legal line").1;
        }
        let explorer_moves = moves
            .iter()
            .map(|&(san, games)| {
                let played = p.play_san(san).expect("legal move").0;
                ExplorerMove::new(&played.uci, &played.san, games, 0, 0)
            })
            .collect();
        let total = moves.iter().map(|m| m.1).sum();
        self.by_epd.insert(
            p.epd(),
            ExplorerStats {
                white: total,
                draws: 0,
                black: 0,
                moves: explorer_moves,
                opening: None,
            },
        );
    }

    pub fn lookup(&self, epd: &Epd) -> Option<&ExplorerStats> {
        self.by_epd.get(epd)
    }
}

// CoveragePropertyTests

pub struct Rng(pub u64);

impl Rng {
    pub fn next_u64(&mut self) -> u64 {
        self.0 = self
            .0
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        self.0
    }
}

pub fn fnv(s: &str) -> u64 {
    let mut h: u64 = 14695981039346656037;
    for b in s.bytes() {
        h = (h ^ u64::from(b)).wrapping_mul(1099511628211);
    }
    h
}

/// Synthetic stats: a few legal moves per position with hash-based counts.
pub fn make_synthetic(epd: &Epd) -> Option<ExplorerStats> {
    let pos = ChessPosition::from_fen(&epd.query_fen())?;
    let mut moves = pos.legal_moves();
    moves.sort_by_key(|m| fnv(&format!("{}{}", epd.as_str(), m.uci)));
    let explorer: Vec<ExplorerMove> = moves
        .iter()
        .take(4)
        .enumerate()
        .map(|(i, m)| {
            let games =
                (fnv(&format!("{}{}", m.uci, epd.as_str())) % 200) as i64 + (4 - i as i64) * 100;
            ExplorerMove::new(&m.uci, &m.san, games, 0, 0)
        })
        .collect();
    let total = explorer.iter().map(ExplorerMove::games).sum();
    Some(ExplorerStats {
        white: total,
        draws: 0,
        black: 0,
        moves: explorer,
        opening: None,
    })
}

// Test data (tests/data) and the snapshot tests' helpers.

use std::path::PathBuf;

use ot_core::chess::Side;
use ot_core::coverage::{CoverageEngine, CoverageSettings};

pub fn data_path(path: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/data")
        .join(path)
}

pub fn data_text(path: &str) -> String {
    std::fs::read_to_string(data_path(path)).unwrap_or_else(|e| panic!("{path}: {e}"))
}

pub fn data_json(path: &str) -> serde_json::Value {
    serde_json::from_str(&data_text(path)).unwrap_or_else(|e| panic!("{path}: {e}"))
}

/// The small PGNs in tests/data/pgn, by name, sorted.
pub fn small_pgns() -> Vec<(String, String)> {
    let mut names: Vec<String> = std::fs::read_dir(data_path("pgn"))
        .expect("tests/data/pgn")
        .filter_map(|e| {
            let name = e.ok()?.file_name().into_string().ok()?;
            name.strip_suffix(".pgn").map(str::to_owned)
        })
        .collect();
    names.sort();
    names
        .into_iter()
        .map(|n| {
            let text = data_text(&format!("pgn/{n}.pgn"));
            (n, text)
        })
        .collect()
}

/// The real repertoires in the repository's testData/ (both Black): `berlin`, `semislav`.
pub const REPERTOIRES: [&str; 2] = ["berlin", "semislav"];

pub fn repertoire(name: &str) -> String {
    let file = match name {
        "berlin" => "Berlin-2026-09-22T19_03_40.239Z.pgn",
        "semislav" => "Semi-Slav-2026-09-22T18_59_03.655Z.pgn",
        other => panic!("unknown repertoire {other}"),
    };
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../testData")
        .join(file);
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

/// Stats built from the tree's own moves: child i of a position gets 1000/(i+1) games, the
/// position 200 more; a transposed position uses its lowest node.
pub fn tree_stats(tree: &RepertoireTree) -> HashMap<Epd, ExplorerStats> {
    let mut stats = HashMap::new();
    for node in tree.nodes() {
        if stats.contains_key(&node.epd) {
            continue;
        }
        let moves: Vec<ExplorerMove> = node
            .children
            .iter()
            .enumerate()
            .filter_map(|(i, &c)| {
                let mv = tree[c].mv.as_ref()?;
                Some(ExplorerMove::new(
                    &mv.uci,
                    &mv.san,
                    1000 / (i as i64 + 1),
                    0,
                    0,
                ))
            })
            .collect();
        let total = moves.iter().map(ExplorerMove::games).sum::<i64>() + 200;
        stats.insert(
            node.epd.clone(),
            ExplorerStats {
                white: total,
                draws: 0,
                black: 0,
                moves,
                opening: None,
            },
        );
    }
    stats
}

/// Synthetic stats (`make_synthetic`) for every position of the tree.
pub fn synthetic_stats(tree: &RepertoireTree) -> HashMap<Epd, ExplorerStats> {
    tree.nodes()
        .filter_map(|n| Some((n.epd.clone(), make_synthetic(&n.epd)?)))
        .collect()
}

/// Leaves out one position in five (by hash), so some positions are still pending.
pub fn with_missing(mut stats: HashMap<Epd, ExplorerStats>) -> HashMap<Epd, ExplorerStats> {
    stats.retain(|epd, _| !fnv(epd.as_str()).is_multiple_of(5));
    stats
}

/// Reach of every node under `tree_stats`, coverage target 1 in 500.
pub fn reach(tree: &RepertoireTree, color: Side) -> HashMap<NodeId, f64> {
    let mut engine = CoverageEngine::new(CoverageSettings::new(color, 500, 25));
    engine.recompute_all(tree, &tree_stats(tree));
    engine
        .info()
        .iter()
        .filter_map(|(&id, c)| Some((id, c.reach?)))
        .collect()
}

/// A number for a snapshot: whole numbers without a fraction, others to 6 decimals.
pub fn num(x: f64) -> String {
    if x.fract() == 0.0 && x.abs() < 1e15 {
        format!("{x:.0}")
    } else {
        let s = format!("{x:.6}");
        s.trim_end_matches('0').to_owned()
    }
}

/// The SAN moves from the root to `id`.
pub fn line_san(tree: &RepertoireTree, nodes: &[NodeId]) -> String {
    nodes
        .iter()
        .filter_map(|&n| tree[n].mv.as_ref().map(|m| m.san.as_str()))
        .collect::<Vec<_>>()
        .join(" ")
}
