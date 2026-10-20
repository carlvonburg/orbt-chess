//! Lichess opening explorer: the stats model, databases, and (sans-IO) request building.

pub mod cache;
pub mod queue;
mod stats;

pub use stats::{ExplorerDatabase, ExplorerMove, ExplorerSpeed, ExplorerStats, OpeningName};
