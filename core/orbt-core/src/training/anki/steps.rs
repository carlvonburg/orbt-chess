// Ported from Anki, rslib/src/scheduler/states/steps.rs (https://github.com/ankitects/anki).
// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

use super::SECS_PER_DAY;

/// Learning or relearning steps, in minutes.
#[derive(Clone, Debug, PartialEq)]
pub struct LearningSteps {
    pub steps: Vec<f64>,
}

fn to_secs(minutes: f64) -> i64 {
    ((minutes * 60.0) as i64).max(0)
}

impl LearningSteps {
    pub fn new(steps: &[f64]) -> LearningSteps {
        LearningSteps {
            steps: steps.to_vec(),
        }
    }

    /// Strips off "learning today" and keeps the index in bounds.
    fn index(&self, remaining: i64) -> usize {
        let total = self.steps.len() as i64;
        (total - remaining % 1000).max(0).min((total - 1).max(0)) as usize
    }

    fn secs(&self, index: usize) -> Option<i64> {
        self.steps.get(index).map(|&m| to_secs(m))
    }

    pub fn again_delay_secs_learn(&self) -> Option<i64> {
        self.secs(0)
    }

    pub fn hard_delay_secs(&self, remaining: i64) -> Option<i64> {
        let idx = self.index(remaining);
        // If the current step is invalid, try the first step.
        let current = self
            .secs(idx)
            .or_else(|| self.steps.first().map(|&m| to_secs(m)))?;
        Some(if idx == 0 {
            self.hard_delay_secs_for_first_step(current)
        } else {
            current
        })
    }

    /// Avoids equality with the again interval, and keeps it below the good interval.
    fn hard_delay_secs_for_first_step(&self, again_secs: i64) -> i64 {
        match self.secs(1) {
            // average of first (again) and second (good) steps
            Some(next) => maybe_round_in_days((again_secs + next) / 2),
            // 50% more than the again secs, but at most one day more
            None => maybe_round_in_days((again_secs * 3 / 2).min(again_secs + SECS_PER_DAY)),
        }
    }

    pub fn good_delay_secs(&self, remaining: i64) -> Option<i64> {
        self.secs(self.index(remaining) + 1)
    }

    pub fn current_delay_secs(&self, remaining: i64) -> i64 {
        self.secs(self.index(remaining)).unwrap_or(0)
    }

    pub fn remaining_for_good(&self, remaining: i64) -> i64 {
        (self.steps.len() as i64 - (self.index(remaining) as i64 + 1)).max(0)
    }

    pub fn remaining_for_failed(&self) -> i64 {
        self.steps.len() as i64
    }

    pub fn is_empty(&self) -> bool {
        self.steps.is_empty()
    }
}

/// Above one day, rounds to whole days, so results are the same earlier and later in the day.
fn maybe_round_in_days(secs: i64) -> i64 {
    if secs > SECS_PER_DAY {
        (secs as f64 / SECS_PER_DAY as f64).round() as i64 * SECS_PER_DAY
    } else {
        secs
    }
}
