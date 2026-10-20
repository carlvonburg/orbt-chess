// Ported from Anki, rslib/src/scheduler/states/{mod,normal,new,learning,review,relearning}.rs
// (https://github.com/ankitects/anki).
// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// Not ported: preview filtered decks and the rescheduling-filter wrapper. A card studied in a
// branch session keeps its normal state; only its revlog kind shows it was reviewed early.

use super::card::int_enum;
use super::fuzz::{minimum_review_fuzz_interval, rounded_int, with_review_fuzz};
use super::interval_kind::IntervalKind;
use super::{LearningSteps, MemoryState};

const MINIMUM_EASE_FACTOR: f64 = 1.3;
const EASE_FACTOR_AGAIN_DELTA: f64 = -0.2;
const EASE_FACTOR_HARD_DELTA: f64 = -0.15;
const EASE_FACTOR_EASY_DELTA: f64 = 0.15;

int_enum!(Rating {
    Again = 1,
    Hard = 2,
    Good = 3,
    Easy = 4,
});

int_enum!(RevlogReviewKind {
    Learning = 0,
    Review = 1,
    Relearning = 2,
    Filtered = 3,
    Manual = 4,
    Rescheduled = 5,
});

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct NewState {
    pub position: i64,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LearnState {
    pub remaining_steps: i64,
    pub scheduled_secs: i64,
    pub elapsed_secs: i64,
    pub memory: Option<MemoryState>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ReviewState {
    pub scheduled_days: i64,
    pub elapsed_days: i64,
    pub ease_factor: f64,
    pub lapses: i64,
    pub leeched: bool,
    pub memory: Option<MemoryState>,
}

impl ReviewState {
    fn days_late(&self) -> i64 {
        self.elapsed_days - self.scheduled_days
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RelearnState {
    pub learning: LearnState,
    pub review: ReviewState,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum CardState {
    New(NewState),
    Learning(LearnState),
    Review(ReviewState),
    Relearning(RelearnState),
}

impl CardState {
    pub fn interval_kind(&self) -> IntervalKind {
        match self {
            CardState::New(_) => IntervalKind::Secs(0),
            CardState::Learning(s) => IntervalKind::Secs(s.scheduled_secs),
            CardState::Review(s) => IntervalKind::Days(s.scheduled_days),
            CardState::Relearning(s) => IntervalKind::Secs(s.learning.scheduled_secs),
        }
    }

    pub fn revlog_kind(&self) -> RevlogReviewKind {
        match self {
            CardState::New(_) | CardState::Learning(_) => RevlogReviewKind::Learning,
            CardState::Review(s) if s.days_late() < 0 => RevlogReviewKind::Filtered,
            CardState::Review(_) => RevlogReviewKind::Review,
            CardState::Relearning(_) => RevlogReviewKind::Relearning,
        }
    }

    pub fn review_state(&self) -> Option<ReviewState> {
        match self {
            CardState::Review(s) => Some(*s),
            CardState::Relearning(s) => Some(s.review),
            _ => None,
        }
    }

    pub fn leeched(&self) -> bool {
        self.review_state().is_some_and(|s| s.leeched)
    }

    pub fn new_position(&self) -> Option<i64> {
        match self {
            CardState::New(s) => Some(s.position),
            _ => None,
        }
    }

    pub(crate) fn next_states(&self, ctx: &StateContext) -> SchedulingStates {
        match self {
            CardState::New(_) => {
                // A new card is answered like a failed learning card, but stays New as current.
                let next = LearnState {
                    remaining_steps: ctx.steps.remaining_for_failed(),
                    scheduled_secs: 0,
                    elapsed_secs: 0,
                    memory: None,
                }
                .next_states(ctx);
                SchedulingStates {
                    current: *self,
                    ..next
                }
            }
            CardState::Learning(s) => s.next_states(ctx),
            CardState::Review(s) => s.next_states(ctx),
            CardState::Relearning(s) => s.next_states(ctx),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SchedulingStates {
    pub current: CardState,
    pub again: CardState,
    pub hard: CardState,
    pub good: CardState,
    pub easy: CardState,
}

impl SchedulingStates {
    pub fn get(&self, rating: Rating) -> CardState {
        match rating {
            Rating::Again => self.again,
            Rating::Hard => self.hard,
            Rating::Good => self.good,
            Rating::Easy => self.easy,
        }
    }
}

/// One answer button's FSRS result.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct FsrsItem {
    pub memory: MemoryState,
    /// Days, not rounded.
    pub interval: f64,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct FsrsStates {
    pub again: FsrsItem,
    pub hard: FsrsItem,
    pub good: FsrsItem,
    pub easy: FsrsItem,
}

impl From<fsrs::NextStates> for FsrsStates {
    fn from(n: fsrs::NextStates) -> FsrsStates {
        let item = |s: fsrs::ItemState| FsrsItem {
            memory: MemoryState::from_fsrs(s.memory),
            interval: f64::from(s.interval),
        };
        FsrsStates {
            again: item(n.again),
            hard: item(n.hard),
            good: item(n.good),
            easy: item(n.easy),
        }
    }
}

/// Info required during state transitions.
#[derive(Clone, Debug)]
pub(crate) struct StateContext {
    /// In `0..1`; picks the final interval from the fuzz range.
    pub fuzz_factor: Option<f64>,
    pub fsrs_next_states: Option<FsrsStates>,
    pub fsrs_short_term_with_steps_enabled: bool,
    pub fsrs_allow_short_term: bool,
    // learning
    pub steps: LearningSteps,
    pub graduating_interval_good: i64,
    pub graduating_interval_easy: i64,
    pub initial_ease: f64,
    // reviewing
    pub hard_multiplier: f64,
    pub easy_multiplier: f64,
    pub interval_multiplier: f64,
    pub maximum_review_interval: i64,
    pub leech_threshold: i64,
    // relearning
    pub relearn_steps: LearningSteps,
    pub lapse_multiplier: f64,
    pub minimum_lapse_interval: i64,
}

impl StateContext {
    fn min_and_max_review_intervals(&self, minimum: i64) -> (i64, i64) {
        let maximum = self.maximum_review_interval.max(1);
        (minimum.max(1).min(maximum), maximum)
    }

    fn with_review_fuzz(&self, interval: f64, minimum: i64, maximum: i64) -> i64 {
        with_review_fuzz(self.fuzz_factor, interval, minimum, maximum)
    }

    /// FSRS may schedule below half a day itself only when allowed and no steps are set.
    fn short_term(&self, interval: f64, steps: &LearningSteps) -> bool {
        self.fsrs_allow_short_term
            && (self.fsrs_short_term_with_steps_enabled || steps.is_empty())
            && interval < 0.5
    }

    fn fsrs_memory(&self, pick: impl Fn(&FsrsStates) -> FsrsItem) -> Option<MemoryState> {
        self.fsrs_next_states.as_ref().map(|s| pick(s).memory)
    }
}

#[cfg(test)]
impl StateContext {
    /// Anki's `StateContext::defaults_for_testing()`: FSRS off, no fuzz.
    pub(crate) fn defaults_for_testing() -> StateContext {
        StateContext {
            fuzz_factor: None,
            fsrs_next_states: None,
            fsrs_short_term_with_steps_enabled: false,
            fsrs_allow_short_term: false,
            steps: LearningSteps::new(&[1.0, 10.0]),
            graduating_interval_good: 1,
            graduating_interval_easy: 4,
            initial_ease: 2.5,
            hard_multiplier: 1.2,
            easy_multiplier: 1.3,
            interval_multiplier: 1.0,
            maximum_review_interval: 36500,
            leech_threshold: 8,
            relearn_steps: LearningSteps::new(&[10.0]),
            lapse_multiplier: 0.0,
            minimum_lapse_interval: 1,
        }
    }
}

fn secs_of_days(days: f64) -> i64 {
    (days * 86_400.0) as i64
}

// Learning

impl LearnState {
    pub(crate) fn next_states(&self, ctx: &StateContext) -> SchedulingStates {
        SchedulingStates {
            current: CardState::Learning(*self),
            again: self.answer_again(ctx),
            hard: self.answer_hard(ctx),
            good: self.answer_good(ctx),
            easy: CardState::Review(self.answer_easy(ctx)),
        }
    }

    /// Shared fallback when no step applies: graduate, or a short-term FSRS step.
    fn graduated(
        &self,
        ctx: &StateContext,
        fsrs: Option<FsrsItem>,
        memory: Option<MemoryState>,
        remaining: i64,
    ) -> CardState {
        let (minimum, maximum) = ctx.min_and_max_review_intervals(1);
        let interval = fsrs.map_or(ctx.graduating_interval_good as f64, |f| f.interval);
        if fsrs.is_some() && ctx.short_term(interval, &ctx.steps) {
            return CardState::Learning(LearnState {
                remaining_steps: remaining,
                scheduled_secs: secs_of_days(interval),
                elapsed_secs: 0,
                memory,
            });
        }
        CardState::Review(ReviewState {
            scheduled_days: ctx.with_review_fuzz(interval.round().max(1.0), minimum, maximum),
            elapsed_days: 0,
            ease_factor: ctx.initial_ease,
            lapses: 0,
            leeched: false,
            memory,
        })
    }

    fn answer_again(&self, ctx: &StateContext) -> CardState {
        let memory = ctx.fsrs_memory(|s| s.again);
        if let Some(delay) = ctx.steps.again_delay_secs_learn() {
            return CardState::Learning(LearnState {
                remaining_steps: ctx.steps.remaining_for_failed(),
                scheduled_secs: delay,
                elapsed_secs: 0,
                memory,
            });
        }
        self.graduated(
            ctx,
            ctx.fsrs_next_states.map(|s| s.again),
            memory,
            ctx.steps.remaining_for_failed(),
        )
    }

    fn answer_hard(&self, ctx: &StateContext) -> CardState {
        let memory = ctx.fsrs_memory(|s| s.hard);
        if let Some(delay) = ctx.steps.hard_delay_secs(self.remaining_steps) {
            return CardState::Learning(LearnState {
                remaining_steps: self.remaining_steps,
                scheduled_secs: delay,
                elapsed_secs: 0,
                memory,
            });
        }
        self.graduated(
            ctx,
            ctx.fsrs_next_states.map(|s| s.hard),
            memory,
            self.remaining_steps,
        )
    }

    fn answer_good(&self, ctx: &StateContext) -> CardState {
        let memory = ctx.fsrs_memory(|s| s.good);
        if let Some(delay) = ctx.steps.good_delay_secs(self.remaining_steps) {
            return CardState::Learning(LearnState {
                remaining_steps: ctx.steps.remaining_for_good(self.remaining_steps),
                scheduled_secs: delay,
                elapsed_secs: 0,
                memory,
            });
        }
        self.graduated(
            ctx,
            ctx.fsrs_next_states.map(|s| s.good),
            memory,
            self.remaining_steps,
        )
    }

    fn answer_easy(&self, ctx: &StateContext) -> ReviewState {
        let (mut minimum, maximum) = ctx.min_and_max_review_intervals(1);
        let interval = match &ctx.fsrs_next_states {
            Some(states) => {
                let good = ctx.with_review_fuzz(states.good.interval, minimum, maximum);
                minimum = good + 1;
                rounded_int(states.easy.interval.round().max(1.0))
            }
            None => ctx.graduating_interval_easy,
        };
        ReviewState {
            scheduled_days: ctx.with_review_fuzz(interval as f64, minimum, maximum),
            elapsed_days: 0,
            ease_factor: ctx.initial_ease,
            lapses: 0,
            leeched: false,
            memory: ctx.fsrs_memory(|s| s.easy),
        }
    }
}

// Review

impl ReviewState {
    pub(crate) fn next_states(&self, ctx: &StateContext) -> SchedulingStates {
        let (hard, good, easy) = self.passing_review_intervals(ctx);
        let hard_state = ReviewState {
            scheduled_days: hard,
            elapsed_days: 0,
            ease_factor: (self.ease_factor + EASE_FACTOR_HARD_DELTA).max(MINIMUM_EASE_FACTOR),
            memory: ctx.fsrs_memory(|s| s.hard),
            ..*self
        };
        let good_state = ReviewState {
            scheduled_days: good,
            elapsed_days: 0,
            memory: ctx.fsrs_memory(|s| s.good),
            ..*self
        };
        let easy_state = ReviewState {
            scheduled_days: easy,
            elapsed_days: 0,
            ease_factor: self.ease_factor + EASE_FACTOR_EASY_DELTA,
            memory: ctx.fsrs_memory(|s| s.easy),
            ..*self
        };
        SchedulingStates {
            current: CardState::Review(*self),
            again: self.answer_again(ctx),
            hard: CardState::Review(hard_state),
            good: CardState::Review(good_state),
            easy: CardState::Review(easy_state),
        }
    }

    fn failing_review_interval(&self, ctx: &StateContext) -> (f64, Option<MemoryState>) {
        if let Some(states) = &ctx.fsrs_next_states {
            // In FSRS, fuzz is applied when the card leaves the relearning stage.
            return (states.again.interval, Some(states.again.memory));
        }
        let (minimum, maximum) = ctx.min_and_max_review_intervals(ctx.minimum_lapse_interval);
        let interval = ctx.with_review_fuzz(
            (self.scheduled_days as f64).max(1.0) * ctx.lapse_multiplier,
            minimum,
            maximum,
        );
        (interval as f64, None)
    }

    fn answer_again(&self, ctx: &StateContext) -> CardState {
        let lapses = self.lapses + 1;
        let (days, memory) = self.failing_review_interval(ctx);
        let again_review = ReviewState {
            scheduled_days: rounded_int(days.round().max(1.0)),
            elapsed_days: 0,
            ease_factor: (self.ease_factor + EASE_FACTOR_AGAIN_DELTA).max(MINIMUM_EASE_FACTOR),
            lapses,
            leeched: leech_threshold_met(lapses, ctx.leech_threshold),
            memory,
        };
        if let Some(delay) = ctx.relearn_steps.again_delay_secs_learn() {
            return CardState::Relearning(RelearnState {
                learning: LearnState {
                    remaining_steps: ctx.relearn_steps.remaining_for_failed(),
                    scheduled_secs: delay,
                    elapsed_secs: 0,
                    memory,
                },
                review: again_review,
            });
        }
        if ctx.short_term(days, &ctx.relearn_steps) {
            return CardState::Relearning(RelearnState {
                learning: LearnState {
                    remaining_steps: ctx.relearn_steps.remaining_for_failed(),
                    scheduled_secs: secs_of_days(days),
                    elapsed_secs: 0,
                    memory,
                },
                review: again_review,
            });
        }
        CardState::Review(again_review)
    }

    /// Hard, good and easy intervals; each depends on the previous.
    pub(crate) fn passing_review_intervals(&self, ctx: &StateContext) -> (i64, i64, i64) {
        if let Some(states) = &ctx.fsrs_next_states {
            let max_ivl = ctx.maximum_review_interval;
            let min_for = |interval: f64| {
                minimum_review_fuzz_interval(interval, self.scheduled_days, max_ivl)
            };
            let hard = constrain_passing_interval(
                ctx,
                states.hard.interval,
                min_for(states.hard.interval).max(1),
                true,
            );
            let good = constrain_passing_interval(
                ctx,
                states.good.interval,
                min_for(states.good.interval).max(hard + 1),
                true,
            );
            let easy = constrain_passing_interval(
                ctx,
                states.easy.interval,
                min_for(states.easy.interval).max(good + 1),
                true,
            );
            return (hard, good, easy);
        }
        if self.days_late() < 0 {
            self.passing_early_review_intervals(ctx)
        } else {
            self.passing_non_early_review_intervals(ctx)
        }
    }

    fn passing_non_early_review_intervals(&self, ctx: &StateContext) -> (i64, i64, i64) {
        let current = (self.scheduled_days as f64).max(1.0);
        let late = self.days_late().max(0) as f64;
        let hard_factor = ctx.hard_multiplier;
        let hard_minimum = if hard_factor <= 1.0 {
            0
        } else {
            self.scheduled_days + 1
        };
        let hard = constrain_passing_interval(ctx, current * hard_factor, hard_minimum, true);
        let good_minimum = if hard_factor <= 1.0 {
            self.scheduled_days + 1
        } else {
            hard + 1
        };
        let good = constrain_passing_interval(
            ctx,
            (current + late / 2.0) * self.ease_factor,
            good_minimum,
            true,
        );
        let easy = constrain_passing_interval(
            ctx,
            (current + late) * self.ease_factor * ctx.easy_multiplier,
            good + 1,
            true,
        );
        (hard, good, easy)
    }

    fn passing_early_review_intervals(&self, ctx: &StateContext) -> (i64, i64, i64) {
        let scheduled = (self.scheduled_days as f64).max(1.0);
        let elapsed = self.elapsed_days as f64;
        let hard = constrain_passing_interval(
            ctx,
            (elapsed * ctx.hard_multiplier).max(scheduled * ctx.hard_multiplier / 2.0),
            0,
            false,
        );
        let good =
            constrain_passing_interval(ctx, (elapsed * self.ease_factor).max(scheduled), 0, false);
        let reduced_bonus = ctx.easy_multiplier - (ctx.easy_multiplier - 1.0) / 2.0;
        let easy = constrain_passing_interval(
            ctx,
            (elapsed * self.ease_factor).max(scheduled) * reduced_bonus,
            0,
            false,
        );
        (hard, good, easy)
    }
}

/// True at the threshold, and every half threshold (rounded up) after that.
pub(crate) fn leech_threshold_met(lapses: i64, threshold: i64) -> bool {
    if threshold <= 0 {
        return false;
    }
    let half = ((threshold as f64 / 2.0).ceil() as i64).max(1);
    lapses >= threshold && (lapses - threshold) % half == 0
}

/// Applies the interval multiplier (not with FSRS), fuzz, and the minimum and maximum.
fn constrain_passing_interval(ctx: &StateContext, interval: f64, minimum: i64, fuzz: bool) -> i64 {
    let interval = if ctx.fsrs_next_states.is_some() {
        interval
    } else {
        interval * ctx.interval_multiplier
    };
    let (minimum, maximum) = ctx.min_and_max_review_intervals(minimum);
    if fuzz {
        ctx.with_review_fuzz(interval, minimum, maximum)
    } else {
        rounded_int(interval).max(minimum).min(maximum)
    }
}

// Relearning

impl RelearnState {
    fn next_states(&self, ctx: &StateContext) -> SchedulingStates {
        SchedulingStates {
            current: CardState::Relearning(*self),
            again: self.answer_again(ctx),
            hard: self.answer_hard(ctx),
            good: self.answer_good(ctx),
            easy: CardState::Review(self.answer_easy(ctx)),
        }
    }

    /// FSRS fallback once the relearning steps are used up.
    fn fsrs_exit(
        &self,
        ctx: &StateContext,
        item: FsrsItem,
        memory: Option<MemoryState>,
        remaining: i64,
        reset_elapsed: bool,
    ) -> CardState {
        let (minimum, maximum) = ctx.min_and_max_review_intervals(1);
        let exit_review = ReviewState {
            scheduled_days: ctx.with_review_fuzz(item.interval.round().max(1.0), minimum, maximum),
            memory,
            ..self.review
        };
        if ctx.short_term(item.interval, &ctx.relearn_steps) {
            let stay = LearnState {
                scheduled_secs: secs_of_days(item.interval),
                remaining_steps: remaining,
                memory,
                elapsed_secs: if reset_elapsed {
                    0
                } else {
                    self.learning.elapsed_secs
                },
            };
            return CardState::Relearning(RelearnState {
                learning: stay,
                review: exit_review,
            });
        }
        CardState::Review(exit_review)
    }

    fn answer_again(&self, ctx: &StateContext) -> CardState {
        let (days, memory) = self.review.failing_review_interval(ctx);
        if let Some(delay) = ctx.relearn_steps.again_delay_secs_learn() {
            let again_review = ReviewState {
                scheduled_days: rounded_int(days.round().max(1.0)),
                elapsed_days: 0,
                memory,
                ..self.review
            };
            return CardState::Relearning(RelearnState {
                learning: LearnState {
                    remaining_steps: ctx.relearn_steps.remaining_for_failed(),
                    scheduled_secs: delay,
                    elapsed_secs: 0,
                    memory,
                },
                review: again_review,
            });
        }
        if let Some(states) = &ctx.fsrs_next_states {
            return self.fsrs_exit(
                ctx,
                states.again,
                memory,
                ctx.relearn_steps.remaining_for_failed(),
                true,
            );
        }
        CardState::Review(self.review)
    }

    fn answer_hard(&self, ctx: &StateContext) -> CardState {
        let memory = ctx.fsrs_memory(|s| s.hard);
        if let Some(delay) = ctx
            .relearn_steps
            .hard_delay_secs(self.learning.remaining_steps)
        {
            return CardState::Relearning(RelearnState {
                learning: LearnState {
                    scheduled_secs: delay,
                    memory,
                    ..self.learning
                },
                review: ReviewState {
                    elapsed_days: 0,
                    memory,
                    ..self.review
                },
            });
        }
        if let Some(states) = &ctx.fsrs_next_states {
            return self.fsrs_exit(
                ctx,
                states.hard,
                memory,
                self.learning.remaining_steps,
                false,
            );
        }
        CardState::Review(self.review)
    }

    fn answer_good(&self, ctx: &StateContext) -> CardState {
        let memory = ctx.fsrs_memory(|s| s.good);
        if let Some(delay) = ctx
            .relearn_steps
            .good_delay_secs(self.learning.remaining_steps)
        {
            return CardState::Relearning(RelearnState {
                learning: LearnState {
                    remaining_steps: ctx
                        .relearn_steps
                        .remaining_for_good(self.learning.remaining_steps),
                    scheduled_secs: delay,
                    elapsed_secs: 0,
                    memory,
                },
                review: ReviewState {
                    elapsed_days: 0,
                    memory,
                    ..self.review
                },
            });
        }
        if let Some(states) = &ctx.fsrs_next_states {
            return self.fsrs_exit(
                ctx,
                states.good,
                memory,
                ctx.relearn_steps
                    .remaining_for_good(self.learning.remaining_steps),
                false,
            );
        }
        CardState::Review(self.review)
    }

    fn answer_easy(&self, ctx: &StateContext) -> ReviewState {
        let mut r = self.review;
        match &ctx.fsrs_next_states {
            Some(states) => {
                let (mut minimum, maximum) = ctx.min_and_max_review_intervals(1);
                let good = ctx.with_review_fuzz(states.good.interval, minimum, maximum);
                minimum = good + 1;
                r.scheduled_days =
                    ctx.with_review_fuzz(states.easy.interval.round().max(1.0), minimum, maximum);
            }
            None => r.scheduled_days = self.review.scheduled_days + 1,
        }
        r.elapsed_days = 0;
        r.memory = ctx.fsrs_memory(|s| s.easy);
        r
    }
}
