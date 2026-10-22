//! The analysis board: a line and the variations played on it, never saved.

use std::sync::{Arc, Mutex};

use ot_core::analysis::{AnalysisTree, MoveListRow, NodeEval};
use ot_core::chess::{BoardSquare, ChessPosition, PieceKind, PlayedMove, Side};

use crate::position::Position;

#[derive(uniffi::Object)]
pub struct AnalysisSession {
    state: Mutex<AnalysisTree>,
}

impl AnalysisSession {
    fn with<R>(&self, f: impl FnOnce(&mut AnalysisTree) -> R) -> R {
        f(&mut self.state.lock().expect("analysis lock"))
    }
}

#[uniffi::export]
impl AnalysisSession {
    /// An analysis of `moves` (UCI) from `start_fen` (None: the standard start), at its end.
    #[uniffi::constructor]
    pub fn new(start_fen: Option<String>, moves: Vec<String>, orientation: Side) -> Arc<Self> {
        let fen = start_fen.unwrap_or_else(|| ChessPosition::START_FEN.to_owned());
        let tree = AnalysisTree::new(&fen, &moves, orientation)
            .or_else(|| AnalysisTree::new(ChessPosition::START_FEN, &[], orientation))
            .expect("the start position is valid");
        Arc::new(AnalysisSession {
            state: Mutex::new(tree),
        })
    }

    pub fn start_fen(&self) -> String {
        self.with(|t| t.start_fen().to_owned())
    }

    pub fn orientation(&self) -> Side {
        self.with(|t| t.orientation)
    }

    pub fn set_orientation(&self, side: Side) {
        self.with(|t| t.orientation = side);
    }

    pub fn current(&self) -> u32 {
        self.with(|t| t.current())
    }

    pub fn position(&self) -> Arc<Position> {
        Arc::new(Position(self.with(|t| t.position())))
    }

    pub fn last_move(&self) -> Option<PlayedMove> {
        self.with(|t| t.last_move())
    }

    pub fn moves_to_board(&self) -> Vec<PlayedMove> {
        self.with(|t| t.moves_to_board())
    }

    pub fn line_ahead(&self) -> Vec<PlayedMove> {
        self.with(|t| t.line_ahead())
    }

    pub fn move_list(&self) -> Vec<MoveListRow> {
        self.with(|t| t.move_list())
    }

    pub fn is_main_line(&self, id: u32) -> bool {
        self.with(|t| t.is_main_line(id))
    }

    pub fn go(&self, id: u32) -> bool {
        self.with(|t| t.go(id))
    }

    pub fn back(&self) -> bool {
        self.with(|t| t.back())
    }

    pub fn forward(&self) -> bool {
        self.with(|t| t.forward())
    }

    pub fn play(&self, from: BoardSquare, to: BoardSquare, promotion: Option<PieceKind>) -> bool {
        self.with(|t| t.play(from, to, promotion).is_some())
    }

    pub fn play_uci(&self, uci: String) -> bool {
        self.with(|t| t.play_uci(&uci).is_some())
    }

    pub fn promote(&self, id: u32) -> bool {
        self.with(|t| t.promote(id))
    }

    pub fn make_main_line(&self, id: u32) -> bool {
        self.with(|t| t.make_main_line(id))
    }

    pub fn delete_from(&self, id: u32) -> bool {
        self.with(|t| t.delete_from(id))
    }

    /// Records the evaluation of the selected position (kept if deeper than the known one).
    pub fn set_eval(&self, eval: NodeEval) {
        self.with(|t| {
            let id = t.current();
            t.set_eval(id, eval);
        });
    }

    /// `id`'s line as PGN, without variations.
    pub fn line_pgn(&self, id: u32) -> String {
        self.with(|t| t.line_pgn(id))
    }

    /// The whole analysis as PGN.
    pub fn pgn(&self) -> String {
        self.with(|t| t.pgn())
    }
}
