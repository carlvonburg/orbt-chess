//! The repertoire's files besides the PGN: the sidecar `<Name>.otrep.json` and the review log
//! `<Name>.otlog.jsonl`. They are written byte for byte as the Swift build wrote them
//! (`apple_json`), so existing files open unchanged and an unchanged file is never rewritten.

pub mod apple_json;
mod date;
pub mod revlog;
mod sidecar;

pub use date::Timestamp;
pub use sidecar::{FILE_EXTENSION as SIDECAR_EXTENSION, Sidecar, Summary};
