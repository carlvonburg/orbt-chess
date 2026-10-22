//! The engines the app can run and how each one is set up. The engines themselves are native
//! code outside this crate (`ot-engine`); here is only what to tell them.

use serde::{Deserialize, Serialize};

use super::EngineSettings;
use super::uci::EngineCommand;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum EngineKind {
    Stockfish,
    /// Leela Chess Zero: not built into the app yet.
    Leela,
}

impl EngineKind {
    /// The options for `settings`, in the order to send them.
    pub fn options(self, settings: &EngineSettings) -> Vec<EngineCommand> {
        let option = |name: &str, value: u32| EngineCommand::SetOption {
            name: name.into(),
            value: value.to_string(),
        };
        match self {
            EngineKind::Stockfish => vec![
                option("Threads", settings.threads.max(1)),
                option("Hash", settings.hash_mb.max(1)),
                option("MultiPV", settings.lines.clamp(1, super::MAX_LINES)),
            ],
            // Leela has no Hash; its cache is sized in positions and its default is fine.
            EngineKind::Leela => vec![
                option("Threads", settings.threads.max(1)),
                option("MultiPV", settings.lines.clamp(1, super::MAX_LINES)),
            ],
        }
    }
}
