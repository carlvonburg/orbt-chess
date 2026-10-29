use std::sync::Arc;

use orbt_core::chess::{BoardPiece, BoardSquare, ChessPosition, Epd, PieceKind, PlayedMove, Side};

/// An immutable chess position with legal-move helpers.
#[derive(uniffi::Object, Debug)]
pub struct Position(pub(crate) ChessPosition);

#[derive(uniffi::Record)]
pub struct PlayResult {
    pub mv: PlayedMove,
    pub position: Arc<Position>,
}

fn result(r: Option<(PlayedMove, ChessPosition)>) -> Option<PlayResult> {
    r.map(|(mv, p)| PlayResult {
        mv,
        position: Arc::new(Position(p)),
    })
}

/// A position from a FEN; None when the FEN is not valid.
#[uniffi::export]
pub fn position_from_fen(fen: String) -> Option<Arc<Position>> {
    ChessPosition::from_fen(&fen).map(|p| Arc::new(Position(p)))
}

#[uniffi::export]
impl Position {
    #[uniffi::constructor]
    pub fn start() -> Arc<Position> {
        Arc::new(Position(ChessPosition::start()))
    }

    pub fn fen(&self) -> String {
        self.0.fen()
    }

    pub fn epd(&self) -> Epd {
        self.0.epd()
    }

    pub fn side_to_move(&self) -> Side {
        self.0.side_to_move()
    }

    pub fn fullmove_number(&self) -> u32 {
        self.0.fullmove_number()
    }

    pub fn pieces(&self) -> Vec<BoardPiece> {
        self.0.pieces()
    }

    pub fn piece_at(&self, square: BoardSquare) -> Option<BoardPiece> {
        self.0.piece_at(square)
    }

    pub fn legal_destinations(&self, square: BoardSquare) -> Vec<BoardSquare> {
        self.0.legal_destinations(square)
    }

    pub fn is_promotion(&self, from: BoardSquare, to: BoardSquare) -> bool {
        self.0.is_promotion(from, to)
    }

    pub fn is_checkmate(&self) -> bool {
        self.0.is_checkmate()
    }

    pub fn play(
        &self,
        from: BoardSquare,
        to: BoardSquare,
        promotion: Option<PieceKind>,
    ) -> Option<PlayResult> {
        result(self.0.play(from, to, promotion))
    }

    pub fn play_uci(&self, uci: String) -> Option<PlayResult> {
        result(self.0.play_uci(&uci))
    }

    pub fn play_san(&self, san: String) -> Option<PlayResult> {
        result(self.0.play_san(&san))
    }

    pub fn legal_moves(&self) -> Vec<PlayedMove> {
        self.0.legal_moves()
    }
}
