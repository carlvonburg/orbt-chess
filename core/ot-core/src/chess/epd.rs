use std::fmt;

use serde::{Deserialize, Serialize};

use super::Side;

/// Position key: FEN without move counters. The en-passant square is kept only when an
/// en-passant capture is legal, so transpositions are not split by irrelevant ep squares.
/// Used for the stats cache, transpositions, training cards and cloud-eval caching.
#[derive(Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Epd(String);

impl Epd {
    pub fn new(raw: impl Into<String>) -> Epd {
        Epd(raw.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// FEN to send to Lichess: EPD with neutral move counters.
    pub fn query_fen(&self) -> String {
        format!("{} 0 1", self.0)
    }

    /// The letter after the board field. Read in place: card walks call this for every node.
    pub fn side_to_move(&self) -> Side {
        let bytes = self.0.as_bytes();
        match bytes.iter().position(|&b| b == b' ') {
            Some(space) if bytes.get(space + 1) == Some(&b'b') => Side::Black,
            _ => Side::White,
        }
    }
}

impl fmt::Display for Epd {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl fmt::Debug for Epd {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Epd({})", self.0)
    }
}
