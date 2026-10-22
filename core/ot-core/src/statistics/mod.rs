// Ported from Anki, rslib/src/stats/graphs/{today,card_counts,future_due,reviews,hours,buttons,
// intervals,eases,retrievability,retention}.rs (https://github.com/ankitects/anki).
// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

mod chess_stats;
mod scope;

use std::collections::{BTreeMap, BTreeSet};

pub use chess_stats::{WeakMove, expected_recall, opening_branches, weakest_moves};
pub use scope::{GraphParts, card_reach, repertoire_cards};

use crate::chess::Epd;
use crate::training::MATURE_INTERVAL;
use crate::training::anki::{
    Card, CardQueue, CardType, MemoryState, RevlogEntry, RevlogReviewKind, SchedTiming,
};

/// Time ranges of Anki's graphs.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum GraphRange {
    Month,
    ThreeMonths,
    Year,
    All,
}

impl GraphRange {
    pub const ALL: [GraphRange; 4] = [
        GraphRange::Month,
        GraphRange::ThreeMonths,
        GraphRange::Year,
        GraphRange::All,
    ];

    pub fn days(self) -> i64 {
        match self {
            GraphRange::Month => 30,
            GraphRange::ThreeMonths => 90,
            GraphRange::Year => 365,
            GraphRange::All => 0,
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            GraphRange::Month => "1 month",
            GraphRange::ThreeMonths => "3 months",
            GraphRange::Year => "1 year",
            GraphRange::All => "All",
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Today {
    pub answer_count: i64,
    /// Moves answered today, each once however often it was answered (an addition to
    /// Anki's today stats: today's progress against the moves still due).
    pub card_count: i64,
    pub answer_millis: i64,
    pub correct_count: i64,
    pub mature_count: i64,
    pub mature_correct: i64,
    pub learn_count: i64,
    pub review_count: i64,
    pub relearn_count: i64,
    pub early_review_count: i64,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct CardCounts {
    pub new: i64,
    pub learn: i64,
    pub relearn: i64,
    pub young: i64,
    pub mature: i64,
    pub suspended: i64,
}

impl CardCounts {
    pub fn total(&self) -> i64 {
        self.new + self.learn + self.relearn + self.young + self.mature + self.suspended
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct FutureDue {
    /// Days from today (0 = today, negative = overdue) → cards.
    pub due_by_day: BTreeMap<i64, i64>,
    pub have_backlog: bool,
    pub daily_load: i64,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ReviewCounts {
    pub learn: i64,
    pub relearn: i64,
    pub young: i64,
    pub mature: i64,
    pub filtered: i64,
}

impl ReviewCounts {
    pub fn total(&self) -> i64 {
        self.learn + self.relearn + self.young + self.mature + self.filtered
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Reviews {
    /// Day (0 = today, -1 = yesterday) → answers by kind.
    pub count: BTreeMap<i64, ReviewCounts>,
    /// Day → milliseconds by kind.
    pub time: BTreeMap<i64, ReviewCounts>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Hour {
    pub total: i64,
    pub correct: i64,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ButtonCounts {
    /// Index 0 = Again ... 3 = Easy.
    pub learning: [i64; 4],
    pub young: [i64; 4],
    pub mature: [i64; 4],
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Retrievability {
    /// Percent bin → cards.
    pub bins: BTreeMap<i64, i64>,
    /// Average in percent over cards with a memory state.
    pub average: f64,
    /// Estimated total knowledge: the sum of R over cards.
    pub sum: f64,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct TrueRetention {
    pub young_passed: i64,
    pub young_failed: i64,
    pub mature_passed: i64,
    pub mature_failed: i64,
}

fn rate(passed: i64, failed: i64) -> Option<f64> {
    (passed + failed > 0).then(|| passed as f64 / (passed + failed) as f64)
}

impl TrueRetention {
    pub fn young(&self) -> Option<f64> {
        rate(self.young_passed, self.young_failed)
    }

    pub fn mature(&self) -> Option<f64> {
        rate(self.mature_passed, self.mature_failed)
    }

    pub fn total(&self) -> Option<f64> {
        rate(
            self.young_passed + self.mature_passed,
            self.young_failed + self.mature_failed,
        )
    }

    pub fn count(&self) -> i64 {
        self.young_passed + self.young_failed + self.mature_passed + self.mature_failed
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum RetentionPeriod {
    Today,
    Yesterday,
    Week,
    Month,
    Year,
    AllTime,
}

impl RetentionPeriod {
    pub const ALL: [RetentionPeriod; 6] = [
        RetentionPeriod::Today,
        RetentionPeriod::Yesterday,
        RetentionPeriod::Week,
        RetentionPeriod::Month,
        RetentionPeriod::Year,
        RetentionPeriod::AllTime,
    ];

    pub fn title(self) -> &'static str {
        match self {
            RetentionPeriod::Today => "Today",
            RetentionPeriod::Yesterday => "Yesterday",
            RetentionPeriod::Week => "Last week",
            RetentionPeriod::Month => "Last month",
            RetentionPeriod::Year => "Last year",
            RetentionPeriod::AllTime => "All time",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct CardInfo {
    /// Unix seconds.
    pub added: i64,
    /// Unix milliseconds of the first and latest rated answer.
    pub first_review: Option<i64>,
    pub latest_review: Option<i64>,
    /// Unix seconds.
    pub due: Option<i64>,
    pub interval: i64,
    pub reps: i64,
    pub lapses: i64,
    pub average_millis: i64,
    pub total_millis: i64,
    pub retrievability: Option<f64>,
    pub memory: Option<MemoryState>,
    pub history: Vec<RevlogEntry>,
}

/// Consecutive days with answers, from the same days as the calendar (Anki's days, starting
/// at 4 AM). Not part of Anki itself; the Review Heatmap add-on shows the same numbers.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Streak {
    /// Days in a row up to today, or up to yesterday while today has no answers yet.
    pub current: i64,
    pub longest: i64,
    pub studied_today: bool,
}

impl Streak {
    /// `days`: days with answers, 0 = today, -1 = yesterday.
    pub fn from_days(days: &BTreeSet<i64>) -> Streak {
        let studied_today = days.contains(&0);
        let mut current = 0;
        let mut day = if studied_today { 0 } else { -1 };
        while days.contains(&day) {
            current += 1;
            day -= 1;
        }
        let (mut longest, mut run, mut previous) = (0, 0, None);
        for &d in days {
            run = if previous == Some(d - 1) { run + 1 } else { 1 };
            longest = longest.max(run);
            previous = Some(d);
        }
        Streak {
            current,
            longest,
            studied_today,
        }
    }
}

/// The cards and review log statistics are computed from (Anki's `GraphsContext`).
#[cfg(test)]
mod tests;

#[derive(Clone, Debug)]
pub struct GraphsContext {
    pub cards: Vec<Card>,
    /// Cards never studied (Anki: cards of type New).
    pub new_count: i64,
    /// Suspended positions never studied (below alternative moves), which have no stored card.
    pub suspended_new_count: i64,
    /// Sorted by id.
    pub revlog: Vec<RevlogEntry>,
    pub timing: SchedTiming,
    /// The local UTC offset, for the hour-of-day graph.
    pub local_offset_secs: i64,
}

fn is_scheduling(entry: &RevlogEntry) -> bool {
    !matches!(
        entry.kind,
        RevlogReviewKind::Manual | RevlogReviewKind::Rescheduled
    )
}

impl GraphsContext {
    pub fn new(
        cards: Vec<Card>,
        new_count: i64,
        suspended_new_count: i64,
        mut revlog: Vec<RevlogEntry>,
        timing: SchedTiming,
        local_offset_secs: i64,
    ) -> GraphsContext {
        revlog.sort_by_key(|e| e.id);
        GraphsContext {
            cards,
            new_count,
            suspended_new_count,
            revlog,
            timing,
            local_offset_secs,
        }
    }

    fn next_day_start(&self) -> i64 {
        self.timing.next_day_at
    }

    pub fn today(&self) -> Today {
        let mut today = Today::default();
        let start = (self.next_day_start() - 86_400) * 1000;
        let mut cards = BTreeSet::new();
        for review in self
            .revlog
            .iter()
            .filter(|r| r.id >= start && is_scheduling(r))
        {
            today.answer_count += 1;
            cards.insert(&review.cid);
            today.answer_millis += review.time;
            if review.ease > 1 {
                today.correct_count += 1;
            }
            if review.last_ivl >= MATURE_INTERVAL {
                today.mature_count += 1;
                if review.ease > 1 {
                    today.mature_correct += 1;
                }
            }
            match review.kind {
                RevlogReviewKind::Learning => today.learn_count += 1,
                RevlogReviewKind::Review => today.review_count += 1,
                RevlogReviewKind::Relearning => today.relearn_count += 1,
                RevlogReviewKind::Filtered => today.early_review_count += 1,
                RevlogReviewKind::Manual | RevlogReviewKind::Rescheduled => {}
            }
        }
        today.card_count = cards.len() as i64;
        today
    }

    /// Excluding inactive cards: suspended ones are counted separately.
    pub fn card_counts(&self) -> CardCounts {
        let mut counts = CardCounts {
            new: self.new_count,
            suspended: self.suspended_new_count,
            ..CardCounts::default()
        };
        for card in &self.cards {
            if card.queue == CardQueue::Suspended {
                counts.suspended += 1;
                continue;
            }
            match card.ctype {
                CardType::New => counts.new += 1,
                CardType::Learn => counts.learn += 1,
                CardType::Review if card.interval < MATURE_INTERVAL => counts.young += 1,
                CardType::Review => counts.mature += 1,
                CardType::Relearn => counts.relearn += 1,
            }
        }
        counts
    }

    pub fn future_due(&self) -> FutureDue {
        let mut result = FutureDue::default();
        let mut load = 0.0;
        for card in self
            .cards
            .iter()
            .filter(|c| c.ctype != CardType::New && c.queue != CardQueue::Suspended)
        {
            let day = if card.queue == CardQueue::Learn {
                (card.due - self.next_day_start()) / 86_400
            } else {
                card.due - self.timing.days_elapsed
            };
            load += 1.0 / card.interval.max(1) as f64;
            result.have_backlog |= day < 0;
            *result.due_by_day.entry(day).or_default() += 1;
        }
        result.daily_load = load as i64;
        result
    }

    /// Per day (0 = today, -1 = yesterday): answer counts and milliseconds by kind.
    pub fn reviews(&self) -> Reviews {
        fn slot<'a>(c: &'a mut ReviewCounts, r: &RevlogEntry) -> Option<&'a mut i64> {
            match r.kind {
                RevlogReviewKind::Learning => Some(&mut c.learn),
                RevlogReviewKind::Relearning => Some(&mut c.relearn),
                RevlogReviewKind::Review if r.last_ivl < MATURE_INTERVAL => Some(&mut c.young),
                RevlogReviewKind::Review => Some(&mut c.mature),
                RevlogReviewKind::Filtered => Some(&mut c.filtered),
                RevlogReviewKind::Manual | RevlogReviewKind::Rescheduled => None,
            }
        }
        let mut result = Reviews::default();
        for review in self.revlog.iter().filter(|r| is_scheduling(r)) {
            let day = (review.id / 1000 - self.next_day_start()) / 86_400;
            if let Some(n) = slot(result.count.entry(day).or_default(), review) {
                *n += 1;
            }
            if let Some(t) = slot(result.time.entry(day).or_default(), review) {
                *t += review.time;
            }
        }
        result
    }

    fn since(&self, range: GraphRange) -> i64 {
        match range {
            GraphRange::All => i64::MIN,
            _ => (self.next_day_start() - 86_400 * range.days()) * 1000,
        }
    }

    pub fn hours(&self, range: GraphRange) -> [Hour; 24] {
        let mut hours = [Hour::default(); 24];
        let start = self.since(range);
        for review in self
            .revlog
            .iter()
            .filter(|r| r.id >= start && r.kind != RevlogReviewKind::Filtered && is_scheduling(r))
        {
            let secs = review.id / 1000 + self.local_offset_secs;
            let hour = ((secs / 3600) % 24 + 24) % 24;
            hours[hour as usize].total += 1;
            if review.ease > 1 {
                hours[hour as usize].correct += 1;
            }
        }
        hours
    }

    pub fn buttons(&self, range: GraphRange) -> ButtonCounts {
        let mut counts = ButtonCounts::default();
        let start = self.since(range);
        for review in self
            .revlog
            .iter()
            .filter(|r| r.id >= start && (1..=4).contains(&r.ease))
        {
            let i = (review.ease - 1) as usize;
            match review.kind {
                RevlogReviewKind::Learning
                | RevlogReviewKind::Relearning
                | RevlogReviewKind::Filtered => counts.learning[i] += 1,
                RevlogReviewKind::Review if review.last_ivl < MATURE_INTERVAL => {
                    counts.young[i] += 1
                }
                RevlogReviewKind::Review => counts.mature[i] += 1,
                RevlogReviewKind::Manual | RevlogReviewKind::Rescheduled => {}
            }
        }
        counts
    }

    /// Interval in days → cards (review and relearning cards).
    pub fn intervals(&self) -> BTreeMap<i64, i64> {
        let mut result = BTreeMap::new();
        for card in self
            .cards
            .iter()
            .filter(|c| matches!(c.ctype, CardType::Review | CardType::Relearn))
        {
            *result.entry(card.interval).or_default() += 1;
        }
        result
    }

    /// Rounded stability in days → cards.
    pub fn stability(&self) -> BTreeMap<i64, i64> {
        let mut result = BTreeMap::new();
        for memory in self.cards.iter().filter_map(|c| c.memory) {
            let days = if memory.stability.is_finite() {
                (memory.stability.round() as i64).max(0)
            } else {
                0
            };
            *result.entry(days).or_default() += 1;
        }
        result
    }

    /// Difficulty as a percentage, (D - 1) / 9, in 1% bins → cards.
    pub fn difficulty(&self) -> BTreeMap<i64, i64> {
        let mut result = BTreeMap::new();
        for memory in self.cards.iter().filter_map(|c| c.memory) {
            let bin = ((memory.difficulty - 1.0) / 9.0 * 100.0).floor() as i64;
            *result.entry(bin).or_default() += 1;
        }
        result
    }

    pub fn retrievability(&self) -> Retrievability {
        let mut result = Retrievability::default();
        let mut count = 0;
        for r in self
            .cards
            .iter()
            .filter_map(|c| c.retrievability(self.timing.now as f64))
        {
            *result.bins.entry((r * 100.0).floor() as i64).or_default() += 1;
            result.sum += r;
            count += 1;
        }
        if count > 0 {
            result.average = result.sum * 100.0 / count as f64;
        }
        result
    }

    /// Reviews of cards with an interval of a day or more; Again fails, the rest pass.
    pub fn true_retention(
        &self,
        filter: Option<&dyn Fn(&Epd) -> bool>,
    ) -> BTreeMap<RetentionPeriod, TrueRetention> {
        let day = 86_400;
        let next = self.next_day_start();
        let periods = [
            (RetentionPeriod::Today, next - day, next),
            (RetentionPeriod::Yesterday, next - 2 * day, next - day),
            (RetentionPeriod::Week, next - 7 * day, next),
            (RetentionPeriod::Month, next - 30 * day, next),
            (RetentionPeriod::Year, next - 365 * day, next),
            (RetentionPeriod::AllTime, 0, next),
        ];
        let mut result: BTreeMap<RetentionPeriod, TrueRetention> = RetentionPeriod::ALL
            .iter()
            .map(|&p| (p, TrueRetention::default()))
            .collect();
        for review in self.revlog.iter().filter(|r| {
            r.has_rating()
                && !r.is_cramming()
                && (r.kind == RevlogReviewKind::Review || r.last_ivl <= -86_400 || r.last_ivl >= 1)
        }) {
            if let Some(filter) = filter
                && !filter(&review.cid)
            {
                continue;
            }
            let secs = review.id / 1000;
            for &(period, start, end) in &periods {
                if secs < start || secs >= end {
                    continue;
                }
                let t = result.get_mut(&period).expect("period");
                match (review.last_ivl < MATURE_INTERVAL, review.ease == 1) {
                    (true, true) => t.young_failed += 1,
                    (true, false) => t.young_passed += 1,
                    (false, true) => t.mature_failed += 1,
                    (false, false) => t.mature_passed += 1,
                }
            }
        }
        result
    }

    pub fn card_info(&self, card: &Card, epd: &Epd) -> CardInfo {
        let history: Vec<RevlogEntry> = self
            .revlog
            .iter()
            .filter(|r| &r.cid == epd)
            .cloned()
            .collect();
        let rated: Vec<&RevlogEntry> = history.iter().filter(|r| r.has_rating()).collect();
        let due = match card.queue {
            CardQueue::Learn => Some(card.due),
            CardQueue::Review | CardQueue::DayLearn => Some(self.timing.start_of_day(card.due)),
            CardQueue::New | CardQueue::Suspended => None,
        };
        let total: i64 = history.iter().map(|r| r.time).sum();
        CardInfo {
            added: card.added,
            first_review: rated.first().map(|r| r.id),
            latest_review: rated.last().map(|r| r.id),
            due,
            interval: card.interval,
            reps: card.reps,
            lapses: card.lapses,
            average_millis: if rated.is_empty() {
                0
            } else {
                total / rated.len() as i64
            },
            total_millis: total,
            retrievability: card.retrievability(self.timing.now as f64),
            memory: card.memory,
            history,
        }
    }

    pub fn streak(&self) -> Streak {
        let days: BTreeSet<i64> = self
            .reviews()
            .count
            .iter()
            .filter(|(_, c)| c.total() > 0)
            .map(|(&d, _)| d)
            .collect();
        Streak::from_days(&days)
    }
}
