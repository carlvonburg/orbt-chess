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

/// One move and everything after it. A line nests one level per ply, so Clone, Drop,
/// PartialEq, Hash and Debug are written with an explicit stack: derived ones recurse per ply
/// and overflow the stack on a long line from a corrupt or hostile file.
#[derive(Default)]
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
            nags: Vec::new(),
            pre_comments: Vec::new(),
            comments: Vec::new(),
            children: Vec::new(),
        }
    }

    /// A copy without the children.
    fn shallow_clone(&self) -> PgnMove {
        PgnMove {
            san: self.san.clone(),
            nags: self.nags.clone(),
            pre_comments: self.pre_comments.clone(),
            comments: self.comments.clone(),
            children: Vec::with_capacity(self.children.len()),
        }
    }

    fn same_fields(&self, other: &PgnMove) -> bool {
        self.san == other.san
            && self.nags == other.nags
            && self.pre_comments == other.pre_comments
            && self.comments == other.comments
            && self.children.len() == other.children.len()
    }
}

impl Drop for PgnMove {
    fn drop(&mut self) {
        let mut stack = std::mem::take(&mut self.children);
        while let Some(mut m) = stack.pop() {
            stack.append(&mut m.children);
        }
    }
}

impl Clone for PgnMove {
    fn clone(&self) -> PgnMove {
        // Each frame: the source, its copy so far, and the next child to copy.
        let mut stack: Vec<(&PgnMove, PgnMove, usize)> = vec![(self, self.shallow_clone(), 0)];
        loop {
            let (source, _, next) = stack.last_mut().expect("non-empty until the root is done");
            let source: &PgnMove = source;
            if let Some(child) = source.children.get(*next) {
                *next += 1;
                stack.push((child, child.shallow_clone(), 0));
                continue;
            }
            let (_, done, _) = stack.pop().expect("non-empty");
            match stack.last_mut() {
                Some((_, parent, _)) => parent.children.push(done),
                None => return done,
            }
        }
    }
}

impl PartialEq for PgnMove {
    fn eq(&self, other: &PgnMove) -> bool {
        let mut stack = vec![(self, other)];
        while let Some((a, b)) = stack.pop() {
            if !a.same_fields(b) {
                return false;
            }
            stack.extend(a.children.iter().zip(&b.children));
        }
        true
    }
}

impl Eq for PgnMove {}

impl std::hash::Hash for PgnMove {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        let mut stack = vec![self];
        while let Some(m) = stack.pop() {
            m.san.hash(state);
            m.nags.hash(state);
            m.pre_comments.hash(state);
            m.comments.hash(state);
            m.children.len().hash(state);
            stack.extend(m.children.iter().rev());
        }
    }
}

/// Same output as the derived Debug (without `{:#?}` pretty-printing).
impl std::fmt::Debug for PgnMove {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        enum Item<'a> {
            Move(&'a PgnMove),
            Text(&'static str),
        }
        let mut stack = vec![Item::Move(self)];
        while let Some(item) = stack.pop() {
            let m = match item {
                Item::Text(text) => {
                    f.write_str(text)?;
                    continue;
                }
                Item::Move(m) => m,
            };
            write!(
                f,
                "PgnMove {{ san: {:?}, nags: {:?}, pre_comments: {:?}, comments: {:?}, children: [",
                m.san, m.nags, m.pre_comments, m.comments
            )?;
            stack.push(Item::Text("] }"));
            for (index, child) in m.children.iter().enumerate().rev() {
                stack.push(Item::Move(child));
                if index > 0 {
                    stack.push(Item::Text(", "));
                }
            }
        }
        Ok(())
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
