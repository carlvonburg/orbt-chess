//! An open repertoire: the move tree from the PGN, the sidecar (settings and cards) and the
//! coverage engine, with the rules for editing, studying, saving and merging changes made
//! elsewhere.
//!
//! Sans-IO: the platform reads and writes the files and runs the timers. Every operation
//! returns `Changes`, which say whether the views must refresh and when to save (a save
//! request replaces the previous one, like rescheduling a timer). `pgn_to_save`,
//! `sidecar_to_save` and `take_revlog` give the bytes to write.

mod outline;
mod repertoire;
#[cfg(test)]
mod tests;

pub use outline::{OutlineItem, gap_text, outline_children, search};
pub use repertoire::{Changes, OpenError, Repertoire, StudyDefaults};

/// Delays before saving, by what changed.
pub mod save_delay {
    /// After an edit: the PGN is saved shortly after.
    pub const PGN_MS: u32 = 800;
    /// After an edit or remembering the last line.
    pub const SIDECAR_AFTER_EDIT_MS: u32 = 3000;
    /// After an answer or a suspension change.
    pub const SIDECAR_AFTER_ANSWER_MS: u32 = 1000;
    /// After a settings change.
    pub const SIDECAR_AFTER_SETTINGS_MS: u32 = 500;
    /// Now: new totals for the library row.
    pub const NOW: u32 = 0;
}
