//! The repertoire's files besides the PGN: the sidecar `<Name>.otrep.json` and the review log
//! `<Name>.otlog.jsonl`. Field names and value shapes match what the Swift build wrote, so
//! existing files open unchanged; formatting (spacing) may differ.

mod date;
pub mod revlog;
mod sidecar;

pub use date::Timestamp;
pub use sidecar::{FILE_EXTENSION as SIDECAR_EXTENSION, Sidecar, Summary};
