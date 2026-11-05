// Ported from Anki, rslib/src/scheduler/queue/{mod,main,learning}.rs and
// rslib/src/scheduler/queue/builder/{mod,gathering,sorting,intersperser}.rs
// (https://github.com/ankitects/anki).
// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// Differences: one deck, no burying, Anki's default orders only. Reviews due the same day are
// ordered by a priority (how often the position is reached) instead of a random hash, and a
// card may be removed from anywhere in the queue, because one chess line answers several cards.

use std::collections::HashMap;

use rand::prelude::*;
use rand::rngs::StdRng;

use super::{Card, CardQueue, RemainingLimits, SchedTiming};
use crate::chess::Epd;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Counts {
    pub new: i64,
    pub learning: i64,
    pub review: i64,
}

impl Counts {
    pub fn total(&self) -> i64 {
        self.new + self.learning + self.review
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum QueueKind {
    New,
    Learning,
    Review,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum MainKind {
    New,
    Review,
    InterdayLearning,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct MainEntry {
    epd: Epd,
    kind: MainKind,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct LearningEntry {
    due: i64,
    epd: Epd,
    reps: i64,
}

impl LearningEntry {
    /// Previously attempted cards first, then by due.
    fn precedes(&self, other: &LearningEntry) -> bool {
        let a = i64::from(self.reps == 0);
        let b = i64::from(other.reps == 0);
        if a != b { a < b } else { self.due < other.due }
    }

    fn order_key(&self) -> (bool, i64, &Epd) {
        (self.reps == 0, self.due, &self.epd)
    }
}

#[derive(Clone, Debug)]
pub struct CardQueues {
    pub counts: Counts,
    main: Vec<MainEntry>,
    intraday_learning: Vec<LearningEntry>,
    pub current_day: i64,
    learn_ahead_secs: i64,
    current_learning_cutoff: i64,
}

impl CardQueues {
    /// Builds the queue for today.
    /// - cards: studied cards by position.
    /// - new_cards: positions not studied yet, in new-card order (Anki's "position").
    /// - priority: higher first among reviews due the same day.
    pub fn new(
        cards: &HashMap<Epd, Card>,
        new_cards: &[Epd],
        limits: RemainingLimits,
        timing: &SchedTiming,
        learn_ahead_secs: i64,
        priority: &dyn Fn(&Epd) -> f64,
    ) -> CardQueues {
        let mut limits = limits;

        // 1. intraday learning: no limit
        let mut intraday: Vec<LearningEntry> = Vec::new();
        let mut day_learning: Vec<(&Epd, &Card)> = Vec::new();
        let mut reviews: Vec<(&Epd, &Card)> = Vec::new();
        for (epd, card) in cards {
            match card.queue {
                CardQueue::Learn if card.due <= timing.next_day_at => {
                    intraday.push(LearningEntry {
                        due: card.due,
                        epd: epd.clone(),
                        reps: card.reps,
                    })
                }
                CardQueue::DayLearn if card.due <= timing.days_elapsed => {
                    day_learning.push((epd, card))
                }
                CardQueue::Review if card.due <= timing.days_elapsed => reviews.push((epd, card)),
                _ => {}
            }
        }
        // Ties by EPD, so the order does not depend on map iteration.
        intraday.sort_by(|a, b| a.order_key().cmp(&b.order_key()));

        // 2. interday learning, then 3. reviews: "due date" order, sharing the review limit
        let due_order = |a: &(&Epd, &Card), b: &(&Epd, &Card)| {
            a.1.due
                .cmp(&b.1.due)
                .then_with(|| priority(b.0).total_cmp(&priority(a.0)))
                .then(a.1.id.cmp(&b.1.id))
        };
        day_learning.sort_by(due_order);
        reviews.sort_by(due_order);
        let mut gathered_day_learning = Vec::new();
        for (epd, _) in day_learning {
            if limits.review <= 0 {
                break;
            }
            gathered_day_learning.push(MainEntry {
                epd: epd.clone(),
                kind: MainKind::InterdayLearning,
            });
            limits.decrement_review();
        }
        let mut gathered_reviews = Vec::new();
        for (epd, _) in reviews {
            if limits.review <= 0 {
                break;
            }
            gathered_reviews.push(MainEntry {
                epd: epd.clone(),
                kind: MainKind::Review,
            });
            limits.decrement_review();
        }

        // 4. new cards in position order
        let mut gathered_new = Vec::new();
        for epd in new_cards {
            if limits.new <= 0 {
                break;
            }
            if cards.contains_key(epd) {
                continue;
            }
            gathered_new.push(MainEntry {
                epd: epd.clone(),
                kind: MainKind::New,
            });
            limits.decrement_new();
        }

        let cutoff = timing.now + learn_ahead_secs;
        let counts = Counts {
            new: gathered_new.len() as i64,
            learning: intraday.iter().filter(|e| e.due <= cutoff).count() as i64
                + gathered_day_learning.len() as i64,
            review: gathered_reviews.len() as i64,
        };
        // Anki defaults: interday learning and new cards both "mix with reviews"
        let with_interday = intersperse(gathered_reviews, gathered_day_learning);
        CardQueues {
            counts,
            main: intersperse(with_interday, gathered_new),
            intraday_learning: intraday,
            current_day: timing.days_elapsed,
            learn_ahead_secs,
            current_learning_cutoff: timing.now,
        }
    }

    /// A filtered deck with rescheduling (Anki's custom study): every card in `epds`, due or
    /// not, in random order and without limits. Learning cards are shown first.
    pub fn filtered(
        epds: &[Epd],
        cards: &HashMap<Epd, Card>,
        timing: &SchedTiming,
        learn_ahead_secs: i64,
    ) -> CardQueues {
        // Differences: Anki shuffles with SQL's random(); a `StdRng` seeded by the day keeps a
        // branch drill's order for the day.
        let mut rng = StdRng::seed_from_u64(timing.days_elapsed as u64);
        let mut learning = Vec::new();
        let mut main = Vec::new();
        for epd in epds {
            let kind = match cards.get(epd).map(|c| c.queue) {
                None | Some(CardQueue::New) => MainKind::New,
                Some(CardQueue::Suspended) => continue,
                Some(CardQueue::Learn) => {
                    learning.push(LearningEntry {
                        due: timing.now,
                        epd: epd.clone(),
                        reps: cards[epd].reps,
                    });
                    continue;
                }
                Some(CardQueue::DayLearn) => MainKind::InterdayLearning,
                Some(CardQueue::Review) => MainKind::Review,
            };
            main.push(MainEntry {
                epd: epd.clone(),
                kind,
            });
        }
        main.shuffle(&mut rng);
        let count = |kind| main.iter().filter(|e| e.kind == kind).count() as i64;
        let counts = Counts {
            new: count(MainKind::New),
            learning: learning.len() as i64 + count(MainKind::InterdayLearning),
            review: count(MainKind::Review),
        };
        CardQueues {
            counts,
            main,
            intraday_learning: learning,
            current_day: timing.days_elapsed,
            learn_ahead_secs,
            current_learning_cutoff: timing.now,
        }
    }

    /// The main queue (new, review, interday learning) in order, for inspection.
    pub fn main_entries(&self) -> impl Iterator<Item = (&Epd, QueueKind)> {
        self.main.iter().map(|e| {
            let kind = match e.kind {
                MainKind::New => QueueKind::New,
                MainKind::Review => QueueKind::Review,
                MainKind::InterdayLearning => QueueKind::Learning,
            };
            (&e.epd, kind)
        })
    }

    /// Intraday learning cards in order: (position, due, reps), for inspection.
    pub fn intraday_entries(&self) -> impl Iterator<Item = (&Epd, i64, i64)> {
        self.intraday_learning
            .iter()
            .map(|e| (&e.epd, e.due, e.reps))
    }

    pub fn current_learning_cutoff(&self) -> i64 {
        self.current_learning_cutoff
    }

    pub fn learn_ahead_secs(&self) -> i64 {
        self.learn_ahead_secs
    }

    pub fn learn_ahead_cutoff(&self) -> i64 {
        self.current_learning_cutoff + self.learn_ahead_secs
    }

    // Iterating

    /// The cards in the order they will be shown: intraday learning due now, the main queue,
    /// then learning cards due within the learn-ahead limit.
    pub fn ordered(&self) -> impl Iterator<Item = (&Epd, QueueKind)> {
        let cutoff = self.current_learning_cutoff;
        let ahead = self.learn_ahead_cutoff();
        let now = self
            .intraday_learning
            .iter()
            .filter(move |e| e.due <= cutoff)
            .map(|e| (&e.epd, QueueKind::Learning));
        let main = self.main.iter().map(|e| {
            let kind = match e.kind {
                MainKind::New => QueueKind::New,
                MainKind::Review => QueueKind::Review,
                MainKind::InterdayLearning => QueueKind::Learning,
            };
            (&e.epd, kind)
        });
        let later = self
            .intraday_learning
            .iter()
            .filter(move |e| e.due > cutoff && e.due <= ahead)
            .map(|e| (&e.epd, QueueKind::Learning));
        now.chain(main).chain(later)
    }

    pub fn next(&self) -> Option<(&Epd, QueueKind)> {
        self.ordered().next()
    }

    pub fn contains(&self, epd: &Epd) -> bool {
        self.kind_of(epd).is_some()
    }

    pub fn kind_of(&self, epd: &Epd) -> Option<QueueKind> {
        self.ordered().find(|(e, _)| *e == epd).map(|(_, k)| k)
    }

    /// Unix seconds of the earliest learning card due later today, beyond learn-ahead.
    pub fn next_learning_due(&self) -> Option<i64> {
        let ahead = self.learn_ahead_cutoff();
        self.intraday_learning
            .iter()
            .map(|e| e.due)
            .filter(|&d| d > ahead)
            .min()
    }

    // Updating

    /// Removes a card that is about to be answered, wherever it is.
    pub fn remove(&mut self, epd: &Epd) {
        if let Some(i) = self.intraday_learning.iter().position(|e| &e.epd == epd) {
            let entry = self.intraday_learning.remove(i);
            if entry.due <= self.learn_ahead_cutoff() {
                self.counts.learning = (self.counts.learning - 1).max(0);
            }
        } else if let Some(i) = self.main.iter().position(|e| &e.epd == epd) {
            match self.main.remove(i).kind {
                MainKind::New => self.counts.new -= 1,
                MainKind::Review => self.counts.review -= 1,
                MainKind::InterdayLearning => {
                    self.counts.learning = (self.counts.learning - 1).max(0)
                }
            }
        }
    }

    /// After answering: puts a learning card due later today back, not right in front.
    pub fn answered(&mut self, card: &Card, epd: &Epd, timing: &SchedTiming) {
        if card.queue == CardQueue::Learn && card.due < timing.next_day_at {
            let mut entry = LearningEntry {
                due: card.due,
                epd: epd.clone(),
                reps: card.reps,
            };
            let cutoff = self.learn_ahead_cutoff();
            // shown again immediately? place it after the next learning card instead
            if entry.due <= cutoff
                && self.main.is_empty()
                && let Some(next) = self.intraday_learning.first()
                && next.due >= entry.due
                && next.due + 1 < cutoff
            {
                entry.due = next.due + 1;
            }
            self.insert_intraday_learning(entry);
        }
        self.update_learning_cutoff(timing.now);
    }

    fn insert_intraday_learning(&mut self, entry: LearningEntry) {
        if entry.due <= self.learn_ahead_cutoff() {
            self.counts.learning += 1;
        }
        let index = self
            .intraday_learning
            .iter()
            .position(|e| entry.precedes(e))
            .unwrap_or(self.intraday_learning.len());
        self.intraday_learning.insert(index, entry);
    }

    /// Moves the cutoff to now and counts learning cards that came within learn-ahead.
    pub fn update_learning_cutoff(&mut self, now: i64) {
        let last_ahead = self.learn_ahead_cutoff();
        self.current_learning_cutoff = self.current_learning_cutoff.max(now);
        let new_ahead = self.learn_ahead_cutoff();
        self.counts.learning += self
            .intraday_learning
            .iter()
            .filter(|e| e.due > last_ahead && e.due <= new_ahead)
            .count() as i64;
    }
}

/// Evenly mixes `two` into `one`.
pub(crate) fn intersperse<T>(one: Vec<T>, two: Vec<T>) -> Vec<T> {
    let ratio = (one.len() + 1) as f64 / (two.len() + 1) as f64;
    let mut result = Vec::with_capacity(one.len() + two.len());
    let (n1, n2) = (one.len(), two.len());
    let mut one = one.into_iter();
    let mut two = two.into_iter();
    let (mut i1, mut i2) = (0, 0);
    while i1 < n1 || i2 < n2 {
        if i1 < n1 && i2 < n2 {
            if (i2 + 1) as f64 * ratio < (i1 + 1) as f64 {
                result.extend(two.next());
                i2 += 1;
            } else {
                result.extend(one.next());
                i1 += 1;
            }
        } else if i1 < n1 {
            result.extend(one.next());
            i1 += 1;
        } else {
            result.extend(two.next());
            i2 += 1;
        }
    }
    result
}
