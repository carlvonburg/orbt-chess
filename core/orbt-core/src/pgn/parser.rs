use super::{PgnGame, PgnMove, PgnTag, nag};

/// Parses PGN text with any number of games, `{}` and `;` comments, nested variations,
/// NAGs and `!?`-style glyphs. Moves are not validated here.
pub fn parse(text: &str) -> Vec<PgnGame> {
    let mut parser = Parser {
        chars: text.chars().collect(),
        i: 0,
        variation_just_opened: false,
    };
    parser.parse_games()
}

/// A move under construction; the tree lives in an arena, index 0 is the root.
#[derive(Default)]
struct Builder {
    san: String,
    nags: Vec<i32>,
    pre_comments: Vec<String>,
    comments: Vec<String>,
    children: Vec<usize>,
    parent: Option<usize>,
}

const ROOT: usize = 0;

/// Turns the arena into moves. Children always come after their parent in the arena, so
/// building from the back finds every child done (no recursion: lines can be very long).
fn build(arena: &mut [Builder]) -> Vec<PgnMove> {
    let mut built: Vec<Option<PgnMove>> = Vec::new();
    built.resize_with(arena.len(), || None);
    for index in (ROOT + 1..arena.len()).rev() {
        let b = &mut arena[index];
        let children = std::mem::take(&mut b.children)
            .into_iter()
            .filter_map(|c| built[c].take())
            .collect();
        built[index] = Some(PgnMove {
            san: std::mem::take(&mut b.san),
            nags: std::mem::take(&mut b.nags),
            pre_comments: std::mem::take(&mut b.pre_comments),
            comments: std::mem::take(&mut b.comments),
            children,
        });
    }
    std::mem::take(&mut arena[ROOT].children)
        .into_iter()
        .filter_map(|c| built[c].take())
        .collect()
}

struct Parser {
    chars: Vec<char>,
    i: usize,
    variation_just_opened: bool,
}

fn is_whitespace(c: char) -> bool {
    c.is_whitespace()
}

impl Parser {
    fn at_end(&self) -> bool {
        self.i >= self.chars.len()
    }

    fn current(&self) -> char {
        self.chars[self.i]
    }

    fn parse_games(&mut self) -> Vec<PgnGame> {
        let mut games = Vec::new();
        loop {
            self.skip_whitespace();
            if self.at_end() {
                break;
            }
            let before = self.i;
            if let Some(game) = self.parse_game() {
                games.push(game);
            }
            if self.i == before {
                self.i += 1; // never loop on garbage
            }
        }
        games
    }

    fn parse_game(&mut self) -> Option<PgnGame> {
        let mut game = PgnGame::default();
        let mut saw_content = false;

        // Tags
        loop {
            self.skip_whitespace();
            if self.at_end() {
                break;
            }
            if self.current() == '%' && self.at_line_start() {
                self.skip_line();
                continue;
            }
            if self.current() != '[' {
                break;
            }
            if let Some(tag) = self.parse_tag() {
                game.tags.push(tag);
                saw_content = true;
            }
        }

        // Movetext
        let mut arena = vec![Builder::default()];
        let mut cursor = ROOT;
        let mut stack: Vec<usize> = Vec::new();
        let mut pending_pre: Vec<String> = Vec::new();

        loop {
            self.skip_whitespace();
            if self.at_end() {
                break;
            }
            match self.current() {
                '[' => {
                    // Next game starts without a result token.
                    if stack.is_empty() {
                        break;
                    }
                    self.i += 1;
                }
                '%' if self.at_line_start() => self.skip_line(),
                '{' => {
                    let comment = self.read_brace_comment();
                    saw_content = true;
                    self.attach(comment, &mut arena, cursor, &mut pending_pre);
                }
                ';' => {
                    let comment = self.read_line_comment();
                    saw_content = true;
                    self.attach(comment, &mut arena, cursor, &mut pending_pre);
                }
                '(' => {
                    self.i += 1;
                    stack.push(cursor);
                    cursor = arena[cursor].parent.unwrap_or(ROOT);
                    // A comment directly after "(" belongs before the first move of the variation.
                    pending_pre.clear();
                    self.variation_just_opened = true;
                }
                ')' => {
                    self.i += 1;
                    if let Some(top) = stack.pop() {
                        cursor = top;
                    }
                    pending_pre.clear();
                    self.variation_just_opened = false;
                }
                '$' => {
                    self.i += 1;
                    let digits = self.read_while(char::is_numeric);
                    if let Ok(n) = digits.parse::<i32>()
                        && cursor != ROOT
                    {
                        arena[cursor].nags.push(n);
                    }
                }
                '*' => {
                    self.i += 1;
                    game.result = "*".to_owned();
                    if stack.is_empty() {
                        break;
                    }
                }
                _ => {
                    let token = self.read_token();
                    if token.is_empty() {
                        self.i += 1;
                        continue;
                    }
                    if ["1-0", "0-1", "1/2-1/2", "½-½"].contains(&token.as_str()) {
                        game.result = if token == "½-½" {
                            "1/2-1/2".to_owned()
                        } else {
                            token
                        };
                        if stack.is_empty() {
                            break;
                        }
                        continue;
                    }
                    if let Some((san, nag)) = parse_move_token(&token) {
                        if san.is_empty() {
                            // A lone glyph; before any move there is nothing to attach it to.
                            if let Some(nag) = nag
                                && cursor != ROOT
                            {
                                arena[cursor].nags.push(nag);
                            }
                            continue;
                        }
                        saw_content = true;
                        let node = arena.len();
                        arena.push(Builder {
                            san,
                            nags: nag.into_iter().collect(),
                            pre_comments: std::mem::take(&mut pending_pre),
                            parent: Some(cursor),
                            ..Builder::default()
                        });
                        self.variation_just_opened = false;
                        arena[cursor].children.push(node);
                        cursor = node;
                    }
                }
            }
        }

        game.comments = std::mem::take(&mut arena[ROOT].comments);
        self.variation_just_opened = false;
        game.moves = build(&mut arena);
        saw_content.then_some(game)
    }

    fn attach(
        &self,
        comment: String,
        arena: &mut [Builder],
        cursor: usize,
        pending_pre: &mut Vec<String>,
    ) {
        if self.variation_just_opened {
            pending_pre.push(comment);
        } else {
            arena[cursor].comments.push(comment);
        }
    }

    fn at_line_start(&self) -> bool {
        self.i == 0 || matches!(self.chars[self.i - 1], '\n' | '\r')
    }

    fn skip_whitespace(&mut self) {
        while !self.at_end() && (is_whitespace(self.current()) || self.current() == '\u{FEFF}') {
            self.i += 1;
        }
    }

    fn skip_line(&mut self) {
        while !self.at_end() && self.current() != '\n' {
            self.i += 1;
        }
    }

    fn read_while(&mut self, predicate: impl Fn(char) -> bool) -> String {
        let start = self.i;
        while !self.at_end() && predicate(self.current()) {
            self.i += 1;
        }
        self.chars[start..self.i].iter().collect()
    }

    fn read_token(&mut self) -> String {
        self.read_while(|c| !is_whitespace(c) && !"{}();[]$".contains(c))
    }

    fn read_brace_comment(&mut self) -> String {
        self.i += 1;
        let body = self.read_while(|c| c != '}');
        if !self.at_end() {
            self.i += 1;
        }
        body.trim().to_owned()
    }

    fn read_line_comment(&mut self) -> String {
        self.i += 1;
        let body = self.read_while(|c| c != '\n');
        body.trim().to_owned()
    }

    fn parse_tag(&mut self) -> Option<PgnTag> {
        self.i += 1; // [
        self.skip_whitespace();
        let name = self.read_while(|c| !is_whitespace(c) && c != ']' && c != '"');
        self.skip_whitespace();
        let mut value = String::new();
        if !self.at_end() && self.current() == '"' {
            self.i += 1;
            while !self.at_end() && self.current() != '"' {
                if self.current() == '\\' && self.i + 1 < self.chars.len() {
                    self.i += 1;
                }
                value.push(self.current());
                self.i += 1;
            }
            if !self.at_end() {
                self.i += 1;
            }
        }
        while !self.at_end() && self.current() != ']' && self.current() != '\n' {
            self.i += 1;
        }
        if !self.at_end() && self.current() == ']' {
            self.i += 1;
        }
        (!name.is_empty()).then(|| PgnTag::new(name, value))
    }
}

/// Strips move numbers ("12.", "12...", "12.e4") and glyphs. Returns san "" for a lone glyph.
fn parse_move_token(token: &str) -> Option<(String, Option<i32>)> {
    let replaced;
    let mut t: &str = token;
    if t.starts_with("0-0") {
        replaced = t.replace('0', "O");
        t = &replaced;
    }
    // Move number prefix
    let digits_len: usize = t
        .chars()
        .take_while(|c| c.is_numeric())
        .map(char::len_utf8)
        .sum();
    if digits_len > 0 {
        let after = &t[digits_len..];
        if after.starts_with('.') {
            t = after.trim_start_matches('.');
        } else if after.is_empty() {
            return None; // a bare number
        }
    }
    t = t.trim_start_matches('.');
    if t.is_empty() {
        return None;
    }
    let mut glyph_start = t.len();
    while glyph_start > 0 && matches!(t.as_bytes()[glyph_start - 1], b'!' | b'?') {
        glyph_start -= 1;
    }
    let nag = nag::from_glyph(&t[glyph_start..]);
    let san = &t[..glyph_start];
    if san == "--" || san == "Z0" {
        return None; // null moves are not supported
    }
    if let Some(first) = san.chars().next()
        && !first.is_alphabetic()
    {
        return None; // "+-", "=", "∞" evaluation symbols
    }
    Some((san.to_owned(), nag))
}

#[cfg(test)]
mod tests {
    use super::parse_move_token;

    #[test]
    fn move_tokens() {
        assert_eq!(parse_move_token("12.e4"), Some(("e4".into(), None)));
        assert_eq!(parse_move_token("12..."), None);
        assert_eq!(parse_move_token("Nf3!?"), Some(("Nf3".into(), Some(5))));
        assert_eq!(parse_move_token("!!"), Some(("".into(), Some(3))));
        assert_eq!(parse_move_token("0-0-0"), Some(("O-O-O".into(), None)));
        assert_eq!(parse_move_token("12"), None);
        assert_eq!(parse_move_token("+-"), None);
        assert_eq!(parse_move_token("--"), None);
    }
}
