//! PGN as written in the file, before any move is validated (see `repertoire` for that).
//!
//! Our own parser and writer, not pgn-reader: comment placement
//! (pre-comments after "(", "%" escape lines, glyphs as NAGs) and the writer's output are
//! the file format contract, and a re-save must not reformat existing repertoires.

mod parser;
mod writer;

pub use parser::parse;
pub use writer::{start_ply, write_game, write_games};

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct PgnTag {
    pub name: String,
    pub value: String,
}

impl PgnTag {
    pub fn new(name: impl Into<String>, value: impl Into<String>) -> PgnTag {
        PgnTag {
            name: name.into(),
            value: value.into(),
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
pub struct PgnMove {
    pub san: String,
    pub nags: Vec<i32>,
    /// Comments placed before the move, e.g. at the start of a variation.
    pub pre_comments: Vec<String>,
    /// Comments placed after the move.
    pub comments: Vec<String>,
    /// `children[0]` continues this line; the others are variations replacing `children[0]`.
    pub children: Vec<PgnMove>,
}

impl PgnMove {
    pub fn new(san: impl Into<String>) -> PgnMove {
        PgnMove {
            san: san.into(),
            ..PgnMove::default()
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct PgnGame {
    pub tags: Vec<PgnTag>,
    /// Comments before the first move.
    pub comments: Vec<String>,
    /// First moves: `moves[0]` is the main line, the others are variations of it.
    pub moves: Vec<PgnMove>,
    pub result: String,
}

impl Default for PgnGame {
    fn default() -> PgnGame {
        PgnGame {
            tags: Vec::new(),
            comments: Vec::new(),
            moves: Vec::new(),
            result: "*".to_owned(),
        }
    }
}

impl PgnGame {
    pub fn tag(&self, name: &str) -> Option<&str> {
        self.tags
            .iter()
            .find(|t| t.name == name)
            .map(|t| t.value.as_str())
    }

    pub fn set_tag(&mut self, name: &str, value: impl Into<String>) {
        let value = value.into();
        match self.tags.iter_mut().find(|t| t.name == name) {
            Some(tag) => tag.value = value,
            None => self.tags.push(PgnTag::new(name, value)),
        }
    }

    /// Starting FEN from the SetUp/FEN tags, or None for the standard position.
    pub fn start_fen(&self) -> Option<&str> {
        self.tag("FEN").filter(|fen| !fen.is_empty())
    }
}

pub(crate) mod nag {
    pub const GLYPHS: [(&str, i32); 6] = [
        ("!", 1),
        ("?", 2),
        ("!!", 3),
        ("??", 4),
        ("!?", 5),
        ("?!", 6),
    ];

    pub fn from_glyph(glyph: &str) -> Option<i32> {
        GLYPHS.iter().find(|(g, _)| *g == glyph).map(|&(_, n)| n)
    }

    pub fn symbol(nag: i32) -> Option<&'static str> {
        GLYPHS.iter().find(|&&(_, n)| n == nag).map(|&(g, _)| g)
    }
}
