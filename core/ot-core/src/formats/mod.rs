//! The repertoire's files besides the PGN: the sidecar `<Name>.otrep.json` and the review log
//! `<Name>.otlog.jsonl`. Keys are sorted, so the output is deterministic and an unchanged file
//! is never rewritten.

mod date;
pub mod revlog;
mod sidecar;

pub use date::Timestamp;
pub use sidecar::{FILE_EXTENSION as SIDECAR_EXTENSION, Sidecar, Summary};
