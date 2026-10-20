//! Spaced-repetition training: Anki's scheduler plus the chess-specific study rules.

pub mod anki;
mod study;
mod trainer;

pub use study::{AnswerKind, MoveRole, PracticeMode, StudyLine, StudySession};
pub use trainer::{LineOutcome, LineRun, MATURE_INTERVAL, Progress, Trainer};
