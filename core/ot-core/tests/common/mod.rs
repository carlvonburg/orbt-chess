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
