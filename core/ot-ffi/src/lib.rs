//! The FFI surface of ot-core: the core's types as they are, and objects that hold the state
//! of an open repertoire, the builder, a drill and the explorer for the platform's views.
//! Thin: conversions and locking only; the rules live in ot-core.

uniffi::setup_scaffolding!("opening_core");

mod analysis;
mod document;
mod engine;
mod explorer;
mod position;
mod sessions;
mod stats;
mod types;

pub use analysis::*;
pub use document::*;
pub use engine::*;
pub use explorer::*;
pub use position::*;
pub use sessions::*;
pub use stats::*;
pub use types::*;

#[uniffi::export]
pub fn core_version() -> String {
    ot_core::version().to_owned()
}
