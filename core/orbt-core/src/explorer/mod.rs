//! Lichess opening explorer: the stats model, databases, (sans-IO) request building, and the
//! offline coverage tables.

pub mod cache;
pub mod manifest;
pub mod queue;
mod stats;
pub mod table;

pub use stats::{ExplorerDatabase, ExplorerMove, ExplorerSpeed, ExplorerStats, OpeningName};
