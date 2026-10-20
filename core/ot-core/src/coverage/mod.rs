//! Coverage: reach probability, completion and gaps for a repertoire.
//!
//! Reach p: root 1; own moves keep p; an opponent move multiplies by its share at the
//! parent. An opponent reply is required when p·f ≥ 1/N and the position has ≥ minGames
//! games. Gaps: an own-turn node with p ≥ 1/N and no saved move (and no transposition), or
//! a missing required reply. Completion is the frequency-weighted mean over required replies.

mod engine;

use std::collections::{BTreeSet, HashMap};

pub use engine::{CoverageEngine, StatsSource};

use crate::chess::{Epd, Side};
use crate::repertoire::NodeId;

#[derive(Clone, Debug, PartialEq)]
pub struct CoverageSettings {
    pub color: Side,
    /// Cover every opponent move seen at least once in `target_games` games.
    pub target_games: i64,
    /// Positions with fewer explorer games create no requirements.
    pub min_games: i64,
    /// Opponent moves (UCI) you chose not to cover, by the position before them. They are
    /// never required and never gaps. A move you save anyway is covered as usual.
    pub excluded: HashMap<Epd, BTreeSet<String>>,
}

impl CoverageSettings {
    pub fn new(color: Side, target_games: i64, min_games: i64) -> CoverageSettings {
        CoverageSettings {
            color,
            target_games,
            min_games,
            excluded: HashMap::new(),
        }
    }

    pub fn threshold(&self) -> f64 {
        1.0 / self.target_games.max(1) as f64
    }

    pub fn is_excluded(&self, uci: &str, epd: &Epd) -> bool {
        self.excluded.get(epd).is_some_and(|s| s.contains(uci))
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum GapKind {
    /// Your move is missing in this position.
    MissingMove,
    /// A required opponent reply is missing below this position.
    MissingReply { uci: String, san: String },
}

#[derive(Clone, Debug, PartialEq)]
pub struct CoverageGap {
    pub node: NodeId,
    pub kind: GapKind,
    /// Reach probability of the uncovered position.
    pub mass: f64,
}

impl CoverageGap {
    /// "Seen once every N games".
    pub fn seen_every(&self) -> i64 {
        if self.mass > 0.0 {
            (1.0 / self.mass).round() as i64
        } else {
            i64::MAX
        }
    }
}

/// An opponent reply at an opponent-to-move node, as listed in the builder.
#[derive(Clone, Debug, PartialEq)]
pub struct ReplyInfo {
    pub uci: String,
    pub san: String,
    pub share: f64,
    pub reach: f64,
    pub required: bool,
    /// Not in the repertoire and excluded from coverage.
    pub excluded: bool,
    /// The child node if the reply is in the repertoire.
    pub child: Option<NodeId>,
    /// A node elsewhere with the same position and a move of yours.
    pub transposes_to: Option<NodeId>,
    pub completion: f64,
    pub games: i64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Status {
    /// Inside the required region and has what it needs (completion may still be < 1 below it).
    Required,
    /// Reach below the target: nothing is required here.
    BelowTarget,
    /// Opponent to move, stats not fetched yet.
    Pending,
    /// Reach unknown because an ancestor is pending.
    Unknown,
    /// Your move is missing.
    Gap,
    /// Your move is missing here, but the same position is covered at another node.
    Transposition(NodeId),
    /// An alternative move of yours (not the main one); carries no mass.
    Alternative,
}

#[derive(Clone, Debug, PartialEq)]
pub struct NodeCoverage {
    pub reach: Option<f64>,
    pub status: Status,
    pub completion: f64,
    pub gap_count: i64,
    pub gap_mass: f64,
    pub pending_count: i64,
    pub biggest_gap: Option<CoverageGap>,
    pub local_gaps: Vec<CoverageGap>,
    /// For opponent-to-move nodes with stats: explorer replies plus tree children not in the stats.
    pub replies: Vec<ReplyInfo>,
    /// Whether this node counts toward its parent (false under alternatives).
    pub counts: bool,
}

impl Default for NodeCoverage {
    fn default() -> NodeCoverage {
        NodeCoverage {
            reach: None,
            status: Status::Unknown,
            completion: 0.0,
            gap_count: 0,
            gap_mass: 0.0,
            pending_count: 0,
            biggest_gap: None,
            local_gaps: Vec::new(),
            replies: Vec::new(),
            counts: true,
        }
    }
}

impl NodeCoverage {
    pub fn seen_every(&self) -> Option<i64> {
        self.reach
            .filter(|&r| r > 0.0)
            .map(|r| (1.0 / r).round() as i64)
    }
}
