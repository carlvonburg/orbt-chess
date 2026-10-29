//! A repertoire as one move tree. All PGN games are merged; transpositions are found
//! through the EPD index.

pub mod comment;
mod tree;

pub use tree::{GameHeader, NodeId, RepertoireNode, RepertoireTree};
