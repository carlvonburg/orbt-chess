//! Engine analysis without the engine: the UCI conversation, which evaluation to show (a
//! Lichess cloud eval or the local engine's), and the engines' options. The platform runs the
//! engine (`ot-engine`, native code), writes the commands this module returns and passes each
//! line the engine prints back in, like the explorer's requests.

mod kind;
mod search;
pub mod uci;

use serde::{Deserialize, Serialize};

pub use kind::EngineKind;
pub use search::{EngineLines, EngineSearch, EngineStep, EvalSource, PvLine};
pub use uci::{EngineCommand, EngineInfo, EngineOutput, Score};

/// Most lines the engine is asked for (Lichess's cloud evals have up to five too).
pub const MAX_LINES: u32 = 5;

/// A cloud eval at least this deep (with every line asked for) is shown instead of running
/// the local engine at all.
pub const CLOUD_DEEP_ENOUGH: u32 = 30;

/// How long the local engine waits for a cloud eval before it starts (lichess mobile: 600 ms).
pub const CLOUD_WAIT_MS: u64 = 600;

/// A cloud eval with fewer lines than asked for is replaced by the local engine's from this
/// depth, even when it is not deeper yet.
pub const LOCAL_OVER_SHORT_CLOUD_DEPTH: u32 = 18;

/// Most moves of a line shown.
pub const MAX_LINE_MOVES: usize = 16;

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct EngineSettings {
    /// Lines (MultiPV), 1 to `MAX_LINES`.
    pub lines: u32,
    /// Search time for a position; 0 searches until stopped.
    pub movetime_ms: u32,
    pub threads: u32,
    pub hash_mb: u32,
    /// Ask Lichess for a cloud eval first.
    pub cloud: bool,
}

impl Default for EngineSettings {
    fn default() -> EngineSettings {
        EngineSettings {
            lines: 3,
            movetime_ms: 6000,
            threads: 2,
            hash_mb: 64,
            cloud: true,
        }
    }
}
