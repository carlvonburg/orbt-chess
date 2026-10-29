use std::fmt;

use serde::{Deserialize, Serialize};
use shakmaty::fen::{Epd as ShakmatyEpd, Fen};
use shakmaty::san::SanPlus;
use shakmaty::{CastlingMode, Chess, Color, EnPassantMode, File, Move, Position, Role, Square};

use super::Epd;
use super::san;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Side {
    White,
    Black,
}

impl Side {
    pub fn opposite(self) -> Side {
        match self {
            Side::White => Side::Black,
            Side::Black => Side::White,
        }
    }
}

impl From<Color> for Side {
    fn from(color: Color) -> Side {
        match color {
            Color::White => Side::White,
            Color::Black => Side::Black,
        }
    }
}

/// A square stored as 0...63 with a1 = 0, h8 = 63.
#[derive(Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub struct BoardSquare {
    pub index: u8,
}

impl BoardSquare {
    pub fn new(file: u8, rank: u8) -> BoardSquare {
        BoardSquare {
            index: rank * 8 + file,
        }
    }

    /// Parses algebraic notation, e.g. "e4".
    pub fn parse(notation: &str) -> Option<BoardSquare> {
        match notation.as_bytes() {
            &[f @ b'a'..=b'h', r @ b'1'..=b'8'] => Some(BoardSquare::new(f - b'a', r - b'1')),
            _ => None,
        }
    }

    pub fn file(self) -> u8 {
        self.index % 8
    }

    pub fn rank(self) -> u8 {
        self.index / 8
    }

    pub fn is_light(self) -> bool {
        (self.file() + self.rank()) % 2 == 1
    }

    fn kit(self) -> Square {
        Square::new(u32::from(self.index))
    }
}

impl From<Square> for BoardSquare {
    fn from(square: Square) -> BoardSquare {
        BoardSquare {
            index: u8::from(square),
        }
    }
}

impl fmt::Display for BoardSquare {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}{}", (b'a' + self.file()) as char, self.rank() + 1)
    }
}

impl fmt::Debug for BoardSquare {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(self, f)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum PieceKind {
    #[serde(rename = "p")]
    Pawn,
    #[serde(rename = "n")]
    Knight,
    #[serde(rename = "b")]
    Bishop,
    #[serde(rename = "r")]
    Rook,
    #[serde(rename = "q")]
    Queen,
    #[serde(rename = "k")]
    King,
}

impl PieceKind {
    pub fn from_char(c: char) -> Option<PieceKind> {
        Role::from_char(c.to_ascii_lowercase()).map(PieceKind::from)
    }

    pub fn char(self) -> char {
        Role::from(self).char()
    }
}

impl From<Role> for PieceKind {
    fn from(role: Role) -> PieceKind {
        match role {
            Role::Pawn => PieceKind::Pawn,
            Role::Knight => PieceKind::Knight,
            Role::Bishop => PieceKind::Bishop,
            Role::Rook => PieceKind::Rook,
            Role::Queen => PieceKind::Queen,
            Role::King => PieceKind::King,
        }
    }
}

impl From<PieceKind> for Role {
    fn from(kind: PieceKind) -> Role {
        match kind {
            PieceKind::Pawn => Role::Pawn,
            PieceKind::Knight => Role::Knight,
            PieceKind::Bishop => Role::Bishop,
            PieceKind::Rook => Role::Rook,
            PieceKind::Queen => Role::Queen,
            PieceKind::King => Role::King,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct BoardPiece {
    pub side: Side,
    pub kind: PieceKind,
    pub square: BoardSquare,
}

/// A move that was played from a position, in both notations.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct PlayedMove {
    /// SAN including check and mate suffixes, e.g. "Nf3", "exd5", "O-O", "e8=Q+".
    pub san: String,
    /// UCI with standard castling notation, e.g. "e1g1", "e7e8q".
    pub uci: String,
}

impl PlayedMove {
    /// The from square; None if `uci` is not a move (it may come from a file or a server).
    pub fn from(&self) -> Option<BoardSquare> {
        BoardSquare::parse(self.uci.get(0..2)?)
    }

    /// The to square; None if `uci` is not a move.
    pub fn to(&self) -> Option<BoardSquare> {
        BoardSquare::parse(self.uci.get(2..4)?)
    }
}

/// Immutable chess position with legal-move helpers.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ChessPosition {
    pos: Chess,
}

impl Default for ChessPosition {
    fn default() -> ChessPosition {
        ChessPosition::start()
    }
}

impl ChessPosition {
    pub const START_FEN: &'static str = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";

    pub fn start() -> ChessPosition {
        ChessPosition { pos: Chess::new() }
    }

    #[allow(clippy::result_large_err)] // shakmaty's PositionError carries the position
    pub fn from_fen(fen: &str) -> Option<ChessPosition> {
        let parsed = Fen::from_ascii(fen.trim().as_bytes()).ok()?;
        // Lenient like the previous chess library: positions from PGN setups may be odd.
        let pos: Chess = parsed
            .into_position(CastlingMode::Standard)
            .or_else(|e| e.ignore_invalid_castling_rights())
            .or_else(|e| e.ignore_invalid_ep_square())
            .or_else(|e| e.ignore_too_much_material())
            .or_else(|e| e.ignore_impossible_check())
            .ok()?;
        Some(ChessPosition { pos })
    }

    /// FEN with the en-passant square after every double pawn push.
    pub fn fen(&self) -> String {
        Fen::from_position(&self.pos, EnPassantMode::Always).to_string()
    }

    pub fn epd(&self) -> Epd {
        Epd::new(ShakmatyEpd::from_position(&self.pos, EnPassantMode::Legal).to_string())
    }

    pub fn side_to_move(&self) -> Side {
        self.pos.turn().into()
    }

    pub fn fullmove_number(&self) -> u32 {
        self.pos.fullmoves().get()
    }

    pub fn pieces(&self) -> Vec<BoardPiece> {
        self.pos
            .board()
            .iter()
            .map(|(square, piece)| BoardPiece {
                side: piece.color.into(),
                kind: piece.role.into(),
                square: square.into(),
            })
            .collect()
    }

    pub fn piece_at(&self, square: BoardSquare) -> Option<BoardPiece> {
        self.pos.board().piece_at(square.kit()).map(|p| BoardPiece {
            side: p.color.into(),
            kind: p.role.into(),
            square,
        })
    }

    /// Destinations of the piece on `square`, with castling as the king's target square.
    pub fn legal_destinations(&self, square: BoardSquare) -> Vec<BoardSquare> {
        let mut result: Vec<BoardSquare> = Vec::new();
        for m in self.pos.legal_moves() {
            if m.from() == Some(square.kit()) {
                let to = king_target(m);
                if !result.contains(&to) {
                    result.push(to);
                }
            }
        }
        result
    }

    pub fn is_promotion(&self, from: BoardSquare, to: BoardSquare) -> bool {
        matches!(self.piece_at(from), Some(p) if p.kind == PieceKind::Pawn)
            && (to.rank() == 0 || to.rank() == 7)
    }

    pub fn is_checkmate(&self) -> bool {
        self.pos.is_checkmate()
    }

    /// Plays a move given as UCI ("e2e4", "e7e8q"). Accepts king-takes-rook castling ("e1h1").
    pub fn play_uci(&self, uci: &str) -> Option<(PlayedMove, ChessPosition)> {
        if !(uci.len() == 4 || uci.len() == 5) || !uci.is_ascii() {
            return None;
        }
        let from = BoardSquare::parse(&uci[0..2])?;
        let mut to = BoardSquare::parse(&uci[2..4])?;
        if let (Some(p), Some(target)) = (self.piece_at(from), self.piece_at(to))
            && p.kind == PieceKind::King
            && target.kind == PieceKind::Rook
            && target.side == p.side
        {
            // Chess960-style castling as sent by some Lichess endpoints.
            to = BoardSquare::new(if to.file() > from.file() { 6 } else { 2 }, from.rank());
        }
        let promotion = match uci.chars().nth(4) {
            Some(c) => Some(PieceKind::from_char(c)?),
            None => None,
        };
        self.play(from, to, promotion)
    }

    /// Plays the piece on `from` to `to`; a promotion without a piece promotes to a queen.
    pub fn play(
        &self,
        from: BoardSquare,
        to: BoardSquare,
        promotion: Option<PieceKind>,
    ) -> Option<(PlayedMove, ChessPosition)> {
        let piece = self.piece_at(from)?;
        if piece.side != self.side_to_move() {
            return None;
        }
        if matches!(promotion, Some(PieceKind::Pawn | PieceKind::King)) {
            return None;
        }
        let wanted = Role::from(promotion.unwrap_or(PieceKind::Queen));
        let m = self.pos.legal_moves().into_iter().find(|&m| {
            m.from() == Some(from.kit())
                && king_target(m) == to
                && m.promotion().is_none_or(|role| role == wanted)
        })?;
        Some(self.apply(m))
    }

    fn apply(&self, m: Move) -> (PlayedMove, ChessPosition) {
        let san = SanPlus::from_move(self.pos.clone(), m).to_string();
        let from = BoardSquare::from(m.from().expect("standard chess move"));
        let mut uci = format!("{from}{}", king_target(m));
        if let Some(role) = m.promotion() {
            uci.push(role.char());
        }
        let mut next = self.pos.clone();
        next.play_unchecked(m);
        (PlayedMove { san, uci }, ChessPosition { pos: next })
    }

    /// Plays a SAN move. Tolerates annotation glyphs, missing or extra check marks, "e.p." and
    /// over-disambiguated moves like "Ngf3".
    pub fn play_san(&self, raw: &str) -> Option<(PlayedMove, ChessPosition)> {
        let wanted = san::loose(raw);
        if wanted.is_empty() {
            return None;
        }
        // Fast path: shakmaty finds the move; accept it only if its SAN matches loosely.
        if let Ok(parsed) = shakmaty::san::San::from_ascii(wanted.as_bytes())
            && let Ok(m) = parsed.to_move(&self.pos)
        {
            let result = self.apply(m);
            if san::loose(&result.0.san) == wanted {
                return Some(result);
            }
        }
        let legal = self.legal_moves();
        if let Some(m) = legal.iter().find(|m| san::loose(&m.san) == wanted) {
            return self.play_uci(&m.uci);
        }
        let parts = san::parts(&wanted)?;
        let matches: Vec<&PlayedMove> = legal
            .iter()
            .filter(|m| {
                let Some(mp) = san::parts(&san::loose(&m.san)) else {
                    return false;
                };
                let from = m.uci.get(0..2).unwrap_or("");
                mp.piece == parts.piece
                    && mp.destination == parts.destination
                    && mp.promotion == parts.promotion
                    && parts.disambiguation.chars().all(|c| from.contains(c))
            })
            .collect();
        match matches.as_slice() {
            [only] => self.play_uci(&only.uci),
            _ => None,
        }
    }

    /// All legal moves in this position.
    pub fn legal_moves(&self) -> Vec<PlayedMove> {
        self.pos
            .legal_moves()
            .into_iter()
            .map(|m| self.apply(m).0)
            .collect()
    }
}

/// Where the moving piece lands; for castling, the king's square (g- or c-file).
fn king_target(m: Move) -> BoardSquare {
    match m {
        Move::Castle { king, rook } => {
            let file = if rook.file() > king.file() {
                File::G
            } else {
                File::C
            };
            Square::from_coords(file, king.rank()).into()
        }
        _ => m.to().into(),
    }
}
