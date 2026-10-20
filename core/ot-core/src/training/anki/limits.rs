// Ported from Anki, rslib/src/decks/limits.rs and rslib/src/decks/stats.rs
// (https://github.com/ankitects/anki).
// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// A repertoire is one deck without subdecks, so the limit tree is a single node.

use serde::{Deserialize, Serialize};

use super::{CardQueue, DeckConfig};

/// A limit that applies on one day only ("Today only" in Anki's deck options).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct DayLimit {
    pub limit: i64,
    pub today: i64,
}

/// Per-deck overrides ("This deck" and "Today only").
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeckLimits {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub new_limit: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub review_limit: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub new_limit_today: Option<DayLimit>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub review_limit_today: Option<DayLimit>,
}

impl DeckLimits {
    pub fn is_empty(&self) -> bool {
        *self == DeckLimits::default()
    }

    pub fn current_new_limit(&self, today: i64) -> Option<i64> {
        match self.new_limit_today {
            Some(t) if t.today == today => Some(t.limit),
            _ => self.new_limit,
        }
    }

    pub fn current_review_limit(&self, today: i64) -> Option<i64> {
        match self.review_limit_today {
            Some(t) if t.today == today => Some(t.limit),
            _ => self.review_limit,
        }
    }
}

/// Cards studied today; reset lazily when the day changes.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeckStudyStats {
    pub last_day_studied: i64,
    pub new_studied: i64,
    pub review_studied: i64,
    pub milliseconds_studied: i64,
}

impl DeckStudyStats {
    /// (new, review) studied today.
    pub fn counts(&self, today: i64) -> (i64, i64) {
        if self.last_day_studied == today {
            (self.new_studied, self.review_studied)
        } else {
            (0, 0)
        }
    }

    fn reset_if_day_changed(&mut self, today: i64) {
        if self.last_day_studied != today {
            *self = DeckStudyStats {
                last_day_studied: today,
                ..DeckStudyStats::default()
            };
        }
    }

    /// Anki counts by the card's queue before answering: new → new, review/day-learn →
    /// review, intraday learning → nothing.
    pub fn record_answer(&mut self, from_queue: CardQueue, millis: i64, today: i64) {
        self.reset_if_day_changed(today);
        match from_queue {
            CardQueue::New => self.new_studied += 1,
            CardQueue::Review | CardQueue::DayLearn => self.review_studied += 1,
            _ => {}
        }
        self.milliseconds_studied += millis;
    }

    /// Custom study "increase today's limit": studied counts may go negative.
    pub fn extend_limits(&mut self, today: i64, new: i64, review: i64) {
        self.reset_if_day_changed(today);
        self.new_studied -= new;
        self.review_studied -= review;
    }

    /// Two devices studied the same day: keep the larger counts.
    pub fn merged(&self, other: &DeckStudyStats) -> DeckStudyStats {
        if self.last_day_studied != other.last_day_studied {
            return if self.last_day_studied > other.last_day_studied {
                *self
            } else {
                *other
            };
        }
        DeckStudyStats {
            last_day_studied: self.last_day_studied,
            new_studied: self.new_studied.max(other.new_studied),
            review_studied: self.review_studied.max(other.review_studied),
            milliseconds_studied: self.milliseconds_studied.max(other.milliseconds_studied),
        }
    }
}

/// How many more new and review cards may be shown today.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RemainingLimits {
    pub review: i64,
    pub new: i64,
    pub cap_new_to_review: bool,
}

impl RemainingLimits {
    /// Filtered decks have no limits.
    pub const UNLIMITED: RemainingLimits = RemainingLimits {
        review: 9999,
        new: 9999,
        cap_new_to_review: false,
    };

    pub fn new(
        config: &DeckConfig,
        limits: &DeckLimits,
        stats: &DeckStudyStats,
        today: i64,
    ) -> RemainingLimits {
        let mut review_limit = limits
            .current_review_limit(today)
            .unwrap_or(config.reviews_per_day);
        let mut new_limit = limits
            .current_new_limit(today)
            .unwrap_or(config.new_per_day);
        let (new_today, review_today) = stats.counts(today);
        review_limit -= review_today;
        new_limit -= new_today;
        if !config.new_cards_ignore_review_limit {
            review_limit -= new_today;
            new_limit = new_limit.min(review_limit);
        }
        RemainingLimits {
            review: review_limit.max(0),
            new: new_limit.max(0),
            cap_new_to_review: !config.new_cards_ignore_review_limit,
        }
    }

    pub(crate) fn decrement_review(&mut self) {
        self.review = (self.review - 1).max(0);
        if self.cap_new_to_review {
            self.new = self.new.min(self.review);
        }
    }

    pub(crate) fn decrement_new(&mut self) {
        self.new = (self.new - 1).max(0);
    }
}
