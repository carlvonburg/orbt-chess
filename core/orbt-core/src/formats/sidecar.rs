use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

use serde::{Deserialize, Serialize};

use super::Timestamp;
use crate::chess::{Epd, Side};
use crate::coverage::CoverageSettings;
use crate::explorer::ExplorerDatabase;
use crate::training::anki::{
    Card, CardQueue, Counts, DeckConfig, DeckLimits, DeckStudyStats, RemainingLimits, SECS_PER_DAY,
    SchedTiming,
};
use crate::training::{PracticeMode, Progress};

pub const FILE_EXTENSION: &str = "otrep.json";

fn default_version() -> i64 {
    1
}

/// Fields are declared in key order, so the JSON keys come out sorted.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Summary {
    pub card_count: i64,
    pub completion: f64,
    pub config_key: String,
    pub due_count: i64,
    pub gap_count: i64,
    pub mature_count: i64,
    /// Every move in the PGN, both sides. None in summaries written before it was added.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub saved_move_count: Option<i64>,
    /// Your positions below alternative moves (suspended), studied or not.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub suspended_count: Option<i64>,
}

/// Everything about a repertoire that is not moves: stored next to the PGN as
/// `<Name>.otrep.json` so the PGN stays clean for other chess programs.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Sidecar {
    pub color: Side,
    pub database: ExplorerDatabase,
    /// Opponent moves (UCI) not to cover, by the position before them. A setting: merged
    /// with the others by `settings_modified`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub excluded_moves: Option<BTreeMap<Epd, Vec<String>>>,
    pub id: String,
    /// Last position the user looked at, as UCI moves from the start.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_line: Option<Vec<String>>,
    /// "This deck" and "Today only" daily limits; None uses the default preset.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limits: Option<DeckLimits>,
    /// Overrides the default practice mode.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub practice_mode: Option<PracticeMode>,
    pub settings_modified: Timestamp,
    /// Study state of each card (Anki's card table), by position. New cards have none.
    #[serde(default)]
    pub study_cards: BTreeMap<Epd, Card>,
    /// Cards answered today, for the daily limits.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub study_stats: Option<DeckStudyStats>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<Summary>,
    pub target_games: i64,
    #[serde(default = "default_version")]
    pub version: i64,
}

impl Sidecar {
    /// `id` is a new UUID from the platform.
    pub fn new(id: String, color: Side, now: Timestamp) -> Sidecar {
        Sidecar {
            color,
            database: ExplorerDatabase::default_lichess(),
            excluded_moves: None,
            id,
            last_line: None,
            limits: None,
            practice_mode: None,
            settings_modified: now,
            study_cards: BTreeMap::new(),
            study_stats: None,
            summary: None,
            target_games: 500,
            version: 2,
        }
    }

    pub fn decode(data: &[u8]) -> Result<Sidecar, serde_json::Error> {
        serde_json::from_slice(data)
    }

    /// The file's bytes.
    pub fn encoded(&self) -> Vec<u8> {
        serde_json::to_vec_pretty(self).expect("serializes")
    }

    pub fn coverage_settings(&self) -> CoverageSettings {
        let excluded: HashMap<Epd, BTreeSet<String>> = self
            .excluded_moves
            .iter()
            .flatten()
            .map(|(epd, moves)| (epd.clone(), moves.iter().cloned().collect()))
            .collect();
        CoverageSettings {
            excluded,
            ..CoverageSettings::new(self.color, self.target_games, self.database.min_games())
        }
    }

    pub fn config_key(&self) -> String {
        let color = match self.color {
            Side::White => "white",
            Side::Black => "black",
        };
        format!(
            "{}|{}|{}|{color}",
            self.database.cache_key(),
            self.target_games,
            self.database.min_games()
        )
    }

    pub fn is_excluded(&self, uci: &str, epd: &Epd) -> bool {
        self.excluded_moves
            .as_ref()
            .and_then(|m| m.get(epd))
            .is_some_and(|v| v.iter().any(|u| u == uci))
    }

    /// Adds or removes an excluded opponent move.
    pub fn set_excluded(&mut self, uci: &str, epd: &Epd, excluded: bool, now: Timestamp) {
        let mut moves = self.excluded_moves.take().unwrap_or_default();
        let mut set: BTreeSet<String> = moves.remove(epd).unwrap_or_default().into_iter().collect();
        if excluded {
            set.insert(uci.to_owned());
        } else {
            set.remove(uci);
        }
        if !set.is_empty() {
            moves.insert(epd.clone(), set.into_iter().collect());
        }
        self.excluded_moves = (!moves.is_empty()).then_some(moves);
        self.settings_modified = now;
    }

    /// Equal apart from the summary, which each device computes from its own coverage and
    /// clock: a different summary alone is no reason to write the file.
    pub fn same_content(&self, other: &Sidecar) -> bool {
        let without_summary = |s: &Sidecar| Sidecar {
            summary: None,
            ..s.clone()
        };
        without_summary(self) == without_summary(other)
    }

    /// Merges a version written elsewhere: cards by latest review, settings by latest change,
    /// today's study counts by the larger.
    pub fn merged(&self, other: &Sidecar) -> Sidecar {
        let mut result = if self.settings_modified >= other.settings_modified {
            self.clone()
        } else {
            other.clone()
        };
        let mut cards = self.study_cards.clone();
        for (epd, card) in &other.study_cards {
            if let Some(mine) = cards.get(epd)
                && mine.last_review_time.unwrap_or(0) >= card.last_review_time.unwrap_or(0)
            {
                continue;
            }
            cards.insert(epd.clone(), card.clone());
        }
        result.study_cards = cards;
        result.study_stats = match (&self.study_stats, &other.study_stats) {
            (Some(a), Some(b)) => Some(a.merged(b)),
            (a, b) => a.or(*b),
        };
        result
    }

    /// Suspends the cards of positions that are not on a main line (below an alternative move,
    /// or no longer in the PGN) and restores the others, keeping their progress either way.
    /// Returns whether a card changed.
    pub fn sync_suspension(&mut self, active: &HashSet<Epd>) -> bool {
        let mut changed = false;
        for (epd, card) in &mut self.study_cards {
            if active.contains(epd) {
                if card.queue != CardQueue::Suspended {
                    continue;
                }
                card.restore_queue();
            } else {
                if card.queue == CardQueue::Suspended {
                    continue;
                }
                card.queue = CardQueue::Suspended;
            }
            changed = true;
        }
        changed
    }

    /// The cards as a map for the scheduler and sessions.
    pub fn cards(&self) -> HashMap<Epd, Card> {
        self.study_cards
            .iter()
            .map(|(e, c)| (e.clone(), c.clone()))
            .collect()
    }

    // Estimates without opening the PGN (library rows)

    /// Progress from the stored cards, out of the positions counted in the last summary.
    pub fn estimated_progress(&self) -> Progress {
        let active: Vec<&Card> = self
            .study_cards
            .values()
            .filter(|c| c.queue != CardQueue::Suspended)
            .collect();
        let mut p = Progress {
            cards: self
                .summary
                .as_ref()
                .map_or(0, |s| s.card_count)
                .max(active.len() as i64),
            ..Progress::default()
        };
        for card in &active {
            p.add(card);
        }
        p.suspended = self
            .summary
            .as_ref()
            .and_then(|s| s.suspended_count)
            .unwrap_or((self.study_cards.len() - active.len()) as i64);
        p
    }

    /// Unix seconds when the next card falls due after today's are done: a learning step
    /// later today, or the start of the day a review is due.
    pub fn next_due(&self, timing: &SchedTiming) -> Option<i64> {
        self.study_cards
            .values()
            .filter_map(|card| match card.queue {
                CardQueue::Learn => Some(card.due),
                CardQueue::Review | CardQueue::DayLearn => Some(
                    timing.next_day_at
                        + (card.due.max(timing.days_elapsed + 1) - timing.days_elapsed - 1)
                            * SECS_PER_DAY,
                ),
                _ => None,
            })
            .filter(|&at| at > timing.now)
            .min()
    }

    /// Unix seconds when the learning cards waiting for a later step are due, soonest first.
    pub fn later_learning_dues(&self, timing: &SchedTiming) -> Vec<i64> {
        let mut dues: Vec<i64> = self
            .study_cards
            .values()
            .filter(|c| c.queue == CardQueue::Learn && c.due > timing.now)
            .map(|c| c.due)
            .collect();
        dues.sort_unstable();
        dues
    }

    /// Reviews due tomorrow (Anki's "Due tomorrow" in today's statistics).
    pub fn due_tomorrow(&self, timing: &SchedTiming) -> i64 {
        let tomorrow = timing.days_elapsed + 1;
        self.study_cards
            .values()
            .filter(|c| {
                matches!(c.queue, CardQueue::Review | CardQueue::DayLearn) && c.due == tomorrow
            })
            .count() as i64
    }

    /// New / learning / review counts without opening the PGN, as Anki's deck list computes
    /// them: learning within the learn-ahead limit, reviews and new cards within today's limits.
    pub fn estimated_study_counts(&self, config: &DeckConfig, timing: &SchedTiming) -> Counts {
        let today = timing.days_elapsed;
        let remaining = RemainingLimits::new(
            config,
            &self.limits.unwrap_or_default(),
            &self.study_stats.unwrap_or_default(),
            today,
        );
        let (mut intraday, mut interday, mut review) = (0, 0, 0);
        let cutoff = timing.now + config.learn_ahead_secs;
        for card in self.study_cards.values() {
            match card.queue {
                CardQueue::Learn if card.due <= cutoff => intraday += 1,
                CardQueue::DayLearn if card.due <= today => interday += 1,
                CardQueue::Review if card.due <= today => review += 1,
                _ => {}
            }
        }
        interday = interday.min(remaining.review);
        let review_left = remaining.review - interday;
        review = review.min(review_left);
        let active = self
            .study_cards
            .values()
            .filter(|c| c.queue != CardQueue::Suspended)
            .count() as i64;
        let unseen = (self.summary.as_ref().map_or(0, |s| s.card_count) - active).max(0);
        let mut new = unseen.min(remaining.new);
        if remaining.cap_new_to_review {
            new = new.min(review_left - review);
        }
        Counts {
            new: new.max(0),
            learning: intraday + interday,
            review,
        }
    }
}
