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
