// Ported from Anki, rslib/src/scheduler/answering/{mod,current,learning,review,relearning,revlog}.rs
// (https://github.com/ankitects/anki).
// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

use super::fuzz::{fuzz_factor, fuzz_seed, learning_interval_with_fuzz};
use super::interval_kind::IntervalKind;
use super::states::{FsrsStates, StateContext};
use super::{
    Card, CardQueue, CardState, CardType, DeckConfig, LearnState, LearningSteps, LeechAction,
    NewState, Rating, RelearnState, ReviewState, RevlogEntry, SECS_PER_DAY, SchedTiming,
    SchedulingStates,
};
use crate::chess::Epd;

/// Answers cards: current state → next states → the card and revlog entry after an answer.
#[derive(Clone, Debug)]
pub struct Scheduler {
    pub config: DeckConfig,
    fsrs: fsrs::FSRS,
    parameters: [f32; 21],
}

impl Default for Scheduler {
    fn default() -> Scheduler {
        Scheduler::new(DeckConfig::default())
    }
}

/// The result of answering a card.
#[derive(Clone, Debug, PartialEq)]
pub struct Answer {
    pub card: Card,
    pub revlog: RevlogEntry,
    /// The queue before answering (Anki counts new/review studied by it).
    pub from_queue: CardQueue,
    pub leeched: bool,
}

impl Scheduler {
    /// With FSRS's default parameters, as Anki uses before optimizing.
    pub fn new(config: DeckConfig) -> Scheduler {
        let parameters = fsrs::DEFAULT_PARAMETERS;
        Scheduler {
            config,
            fsrs: fsrs::FSRS::new(&parameters).expect("default FSRS parameters are valid"),
            parameters,
        }
    }

    fn learn_steps(&self) -> LearningSteps {
        LearningSteps::new(&self.config.learn_steps)
    }

    fn relearn_steps(&self) -> LearningSteps {
        LearningSteps::new(&self.config.relearn_steps)
    }

    /// `card` None means New at `position`. `filtered`: studied outside the normal queue (a
    /// branch session or a review ahead), so a review card keeps its real due day.
    pub fn current_state(
        &self,
        card: Option<&Card>,
        position: i64,
        timing: &SchedTiming,
        filtered: bool,
    ) -> CardState {
        let Some(card) = card.filter(|c| c.ctype != CardType::New) else {
            return CardState::New(NewState {
                position: card.map_or(position, |c| c.due),
            });
        };
        let mut due = card.due;
        if !filtered && card.ctype == CardType::Review {
            due = due.min(timing.days_elapsed);
        }
        let elapsed_secs = |last_ivl: i64| -> i64 {
            match card.queue {
                CardQueue::Learn => {
                    let last_answered = card.last_review_time.unwrap_or(due - last_ivl);
                    (timing.now - last_answered).max(0)
                }
                CardQueue::DayLearn => {
                    let last_ivl_days = (last_ivl / SECS_PER_DAY).max(1);
                    ((timing.days_elapsed - due + last_ivl_days) * SECS_PER_DAY).max(0)
                }
                _ => 0,
            }
        };
        let ease = card.ease_factor as f64 / 1000.0;
        match card.ctype {
            CardType::New => CardState::New(NewState { position: due }),
            CardType::Learn => {
                let last_ivl = self.learn_steps().current_delay_secs(card.remaining_steps);
                CardState::Learning(LearnState {
                    remaining_steps: card.remaining_steps,
                    scheduled_secs: last_ivl,
                    elapsed_secs: elapsed_secs(last_ivl),
                    memory: card.memory,
                })
            }
            CardType::Review => CardState::Review(ReviewState {
                scheduled_days: card.interval,
                elapsed_days: (card.interval - (due - timing.days_elapsed)).max(0),
                ease_factor: ease,
                lapses: card.lapses,
                leeched: false,
                memory: card.memory,
            }),
            CardType::Relearn => {
                let last_ivl = self
                    .relearn_steps()
                    .current_delay_secs(card.remaining_steps);
                CardState::Relearning(RelearnState {
                    learning: LearnState {
                        remaining_steps: card.remaining_steps,
                        scheduled_secs: last_ivl,
                        elapsed_secs: elapsed_secs(last_ivl),
                        memory: card.memory,
                    },
                    review: ReviewState {
                        scheduled_days: card.interval,
                        elapsed_days: card.interval,
                        ease_factor: ease,
                        lapses: card.lapses,
                        leeched: false,
                        memory: card.memory,
                    },
                })
            }
        }
    }

    fn context(&self, card: Option<&Card>, id: i64, timing: &SchedTiming) -> StateContext {
        let days_elapsed = card
            .and_then(|c| c.last_review_time)
            .map_or(0, |t| timing.days_since(t));
        let next = self
            .fsrs
            .next_states(
                card.and_then(|c| c.memory).map(|m| m.to_fsrs()),
                self.config.desired_retention as f32,
                days_elapsed.max(0) as u32,
            )
            .ok()
            .map(FsrsStates::from);
        let config = &self.config;
        StateContext {
            fuzz_factor: fuzz_factor(Some(fuzz_seed(id, card.map_or(0, |c| c.reps)))),
            fsrs_next_states: next,
            fsrs_short_term_with_steps_enabled: config.fsrs_short_term_with_steps_enabled,
            fsrs_allow_short_term: self.parameters[17] > 0.0 && self.parameters[18] > 0.0,
            steps: self.learn_steps(),
            graduating_interval_good: config.graduating_interval_good,
            graduating_interval_easy: config.graduating_interval_easy,
            initial_ease: config.initial_ease,
            hard_multiplier: config.hard_multiplier,
            easy_multiplier: config.easy_multiplier,
            interval_multiplier: config.interval_multiplier,
            maximum_review_interval: config.maximum_review_interval,
            leech_threshold: config.leech_threshold,
            relearn_steps: self.relearn_steps(),
            lapse_multiplier: config.lapse_multiplier,
            minimum_lapse_interval: config.minimum_lapse_interval,
        }
    }

    pub fn next_states(
        &self,
        card: Option<&Card>,
        id: i64,
        position: i64,
        timing: &SchedTiming,
        filtered: bool,
    ) -> SchedulingStates {
        self.current_state(card, position, timing, filtered)
            .next_states(&self.context(card, id, timing))
    }

    /// Answers a card. `card` None means a New card at `position`.
    #[allow(clippy::too_many_arguments)]
    pub fn answer(
        &self,
        card: Option<&Card>,
        epd: &Epd,
        position: i64,
        rating: Rating,
        timing: &SchedTiming,
        filtered: bool,
        taken_millis: i64,
        answered_at: Option<i64>,
    ) -> Answer {
        let id = card.map_or_else(|| Card::id_for(epd), |c| c.id);
        let states = self.next_states(card, id, position, timing, filtered);
        let current = states.current;
        let next = states.get(rating);
        let mut updated = card
            .cloned()
            .unwrap_or_else(|| Card::new(id, position, timing.now));
        let from_queue = updated.queue;
        let seed = fuzz_seed(id, updated.reps);

        let factor = match next {
            CardState::New(s) => {
                updated.ctype = CardType::New;
                updated.queue = CardQueue::New;
                updated.due = s.position;
                updated.original_position = None;
                updated.memory = None;
                0.0
            }
            CardState::Learning(s) => {
                updated.remaining_steps = s.remaining_steps;
                updated.ctype = CardType::Learn;
                if let Some(position) = current.new_position() {
                    updated.original_position = Some(position);
                }
                updated.memory = s.memory;
                set_learning_due(&mut updated, next.interval_kind(), timing, seed);
                updated.memory.map_or(0.0, |m| m.difficulty_shifted())
            }
            CardState::Review(s) => {
                updated.queue = CardQueue::Review;
                updated.ctype = CardType::Review;
                updated.interval = s.scheduled_days;
                updated.due = timing.days_elapsed + s.scheduled_days;
                updated.ease_factor = (s.ease_factor * 1000.0).round() as i64;
                updated.lapses = s.lapses;
                updated.remaining_steps = 0;
                if let Some(position) = current.new_position() {
                    updated.original_position = Some(position);
                }
                updated.memory = s.memory;
                updated
                    .memory
                    .map_or(s.ease_factor, |m| m.difficulty_shifted())
            }
            CardState::Relearning(s) => {
                updated.interval = s.review.scheduled_days;
                updated.remaining_steps = s.learning.remaining_steps;
                updated.ctype = CardType::Relearn;
                updated.lapses = s.review.lapses;
                updated.ease_factor = (s.review.ease_factor * 1000.0).round() as i64;
                if let Some(position) = current.new_position() {
                    updated.original_position = Some(position);
                }
                updated.memory = s.learning.memory;
                set_learning_due(&mut updated, next.interval_kind(), timing, seed);
                updated
                    .memory
                    .map_or(s.review.ease_factor, |m| m.difficulty_shifted())
            }
        };
        updated.reps += 1;
        updated.last_review_time = Some(timing.now);
        if next.leeched() {
            updated.leech = Some(true);
            if self.config.leech_action == LeechAction::Suspend {
                updated.queue = CardQueue::Suspended;
            }
        }

        let rollover = timing.secs_until_rollover();
        let revlog = RevlogEntry {
            id: answered_at.unwrap_or(timing.now * 1000),
            cid: epd.clone(),
            ease: i64::from(rating),
            ivl: next
                .interval_kind()
                .maybe_as_days(rollover)
                .as_revlog_interval(),
            last_ivl: current
                .interval_kind()
                .maybe_as_days(rollover)
                .as_revlog_interval(),
            factor: (factor * 1000.0).round() as i64,
            time: taken_millis
                .max(0)
                .min(self.config.cap_answer_time_to_secs * 1000),
            kind: current.revlog_kind(),
        };
        Answer {
            card: updated,
            revlog,
            from_queue,
            leeched: next.leeched(),
        }
    }
}

fn set_learning_due(card: &mut Card, interval: IntervalKind, timing: &SchedTiming, seed: u64) {
    match interval.maybe_as_days(timing.secs_until_rollover()) {
        IntervalKind::Secs(secs) => {
            card.queue = CardQueue::Learn;
            card.due = timing.now + learning_interval_with_fuzz(Some(seed), secs);
        }
        IntervalKind::Days(days) => {
            card.queue = CardQueue::DayLearn;
            card.due = timing.days_elapsed + days;
        }
    }
}
