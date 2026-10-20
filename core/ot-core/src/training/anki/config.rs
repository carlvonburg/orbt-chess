// Defaults from Anki, rslib/src/deckconfig/mod.rs (https://github.com/ankitects/anki).
// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LeechAction {
    Suspend,
    TagOnly,
}

/// A deck options preset. Anki's defaults, with FSRS enabled.
#[derive(Clone, Debug, PartialEq)]
pub struct DeckConfig {
    pub new_per_day: i64,
    pub reviews_per_day: i64,
    pub new_cards_ignore_review_limit: bool,
    /// Minutes.
    pub learn_steps: Vec<f64>,
    pub relearn_steps: Vec<f64>,
    pub graduating_interval_good: i64,
    pub graduating_interval_easy: i64,
    pub initial_ease: f64,
    pub easy_multiplier: f64,
    pub hard_multiplier: f64,
    pub lapse_multiplier: f64,
    pub interval_multiplier: f64,
    pub maximum_review_interval: i64,
    pub minimum_lapse_interval: i64,
    pub leech_threshold: i64,
    pub leech_action: LeechAction,
    pub desired_retention: f64,
    pub cap_answer_time_to_secs: i64,
    /// Collection settings.
    pub learn_ahead_secs: i64,
    pub fsrs_short_term_with_steps_enabled: bool,
}

impl Default for DeckConfig {
    fn default() -> DeckConfig {
        DeckConfig {
            new_per_day: 20,
            reviews_per_day: 200,
            new_cards_ignore_review_limit: false,
            learn_steps: vec![1.0, 10.0],
            relearn_steps: vec![10.0],
            graduating_interval_good: 1,
            graduating_interval_easy: 4,
            initial_ease: 2.5,
            easy_multiplier: 1.3,
            hard_multiplier: 1.2,
            lapse_multiplier: 0.0,
            interval_multiplier: 1.0,
            maximum_review_interval: 36500,
            minimum_lapse_interval: 1,
            leech_threshold: 8,
            leech_action: LeechAction::TagOnly,
            desired_retention: 0.9,
            cap_answer_time_to_secs: 60,
            learn_ahead_secs: 1200,
            fsrs_short_term_with_steps_enabled: false,
        }
    }
}
