//! The FFI surface of ot-core. Thin: converts types and holds objects; no domain logic here.

uniffi::setup_scaffolding!("opening_core");

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    #[error("invalid FEN: {fen}")]
    InvalidFen { fen: String },
}

impl From<ot_core::CoreError> for CoreError {
    fn from(error: ot_core::CoreError) -> Self {
        match error {
            ot_core::CoreError::InvalidFen(fen) => CoreError::InvalidFen { fen },
        }
    }
}

#[uniffi::export]
pub fn core_version() -> String {
    ot_core::version().to_owned()
}

#[uniffi::export]
pub fn legal_move_count(fen: String) -> Result<u32, CoreError> {
    Ok(ot_core::legal_move_count(&fen)? as u32)
}
