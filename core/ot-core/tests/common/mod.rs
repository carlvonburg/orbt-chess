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
