//! Lichess opening explorer: the stats model, databases, and (sans-IO) request building.

mod stats;

pub use stats::{ExplorerDatabase, ExplorerMove, ExplorerSpeed, ExplorerStats, OpeningName};
