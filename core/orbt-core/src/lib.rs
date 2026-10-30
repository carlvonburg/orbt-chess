//! ORBT's domain core, shared by every platform.
//!
//! Pure Rust: no file or network IO, no async runtime, no OS APIs, so it also builds for
//! `wasm32-unknown-unknown`. The platform shell does IO and passes bytes and the current time in.

pub mod analysis;
pub mod builder;
pub mod chess;
pub mod coverage;
pub mod document;
pub mod drill;
pub mod engine;
pub mod explorer;
pub mod formats;
pub mod http;
pub mod lichess;
pub mod oauth;
pub mod pgn;
pub mod repertoire;
pub mod statistics;
pub mod sync;
pub mod training;

use shakmaty::fen::Fen;
use shakmaty::{CastlingMode, Chess, Position};

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum CoreError {
    #[error("invalid FEN: {0}")]
    InvalidFen(String),
}

pub fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

/// Number of legal moves in a position. A smoke test for the chess dependency.
pub fn legal_move_count(fen: &str) -> Result<usize, CoreError> {
    let invalid = || CoreError::InvalidFen(fen.to_owned());
    let parsed: Fen = fen.parse().map_err(|_| invalid())?;
    let position: Chess = parsed
        .into_position(CastlingMode::Standard)
        .map_err(|_| invalid())?;
    Ok(position.legal_moves().len())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn start_position_has_twenty_moves() {
        let start = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
        assert_eq!(legal_move_count(start), Ok(20));
    }

    #[test]
    fn rejects_garbage() {
        assert!(legal_move_count("not a fen").is_err());
    }
}
