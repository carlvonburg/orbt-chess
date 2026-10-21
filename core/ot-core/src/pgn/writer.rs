use super::{PgnGame, PgnMove, nag};

/// Writes PGN games with variations, comments and NAGs, wrapped at 80 columns.
pub fn write_games(games: &[PgnGame]) -> String {
    let parts: Vec<String> = games.iter().map(write_game).collect();
    parts.join("\n\n") + "\n"
}

pub fn write_game(game: &PgnGame) -> String {
    let mut out = String::new();
    for tag in &game.tags {
        let value = tag.value.replace('\\', "\\\\").replace('"', "\\\"");
        out += &format!("[{} \"{}\"]\n", tag.name, value);
    }
    if !game.tags.is_empty() {
        out.push('\n');
    }

    let mut tokens: Vec<String> = game.comments.iter().map(|c| comment_token(c)).collect();
    write_line(&game.moves, start_ply(game.start_fen()), true, &mut tokens);
    tokens.push(game.result.clone());
    out += &wrap(&tokens, 80);
    out
}

/// Ply index (0 = white's first move) of the first move after `fen`.
pub fn start_ply(fen: Option<&str>) -> usize {
    let Some(fen) = fen else { return 0 };
    let fields: Vec<&str> = fen.split(' ').filter(|f| !f.is_empty()).collect();
    let black = fields.get(1) == Some(&"b");
    let fullmove = fields
        .get(5)
        .and_then(|f| f.parse::<i64>().ok())
        .unwrap_or(1);
    (fullmove.max(1) as usize - 1) * 2 + usize::from(black)
}

/// Writes `alternatives[0]` with `alternatives[1..]` as variations, then continues the main line.
/// Uses a work stack rather than recursion: a line nests one level per ply.
fn write_line(alternatives: &[PgnMove], ply: usize, force_number: bool, tokens: &mut Vec<String>) {
    enum Task<'a> {
        Line(&'a [PgnMove], usize, bool),
        /// The first move of a variation, written after "(".
        Variation(&'a PgnMove, usize),
        Close,
    }
    let mut stack = vec![Task::Line(alternatives, ply, force_number)];
    while let Some(task) = stack.pop() {
        match task {
            Task::Line(alternatives, ply, force_number) => {
                let Some(main) = alternatives.first() else {
                    continue;
                };
                write_move(main, ply, force_number, tokens);
                let variations = &alternatives[1..];
                let needs_number = !main.comments.is_empty() || !variations.is_empty();
                stack.push(Task::Line(&main.children, ply + 1, needs_number));
                for variation in variations.iter().rev() {
                    stack.push(Task::Close);
                    stack.push(Task::Line(
                        &variation.children,
                        ply + 1,
                        !variation.comments.is_empty(),
                    ));
                    stack.push(Task::Variation(variation, ply));
                }
            }
            Task::Variation(variation, ply) => {
                let start = tokens.len();
                write_move(variation, ply, true, tokens);
                tokens[start].insert(0, '(');
            }
            Task::Close => tokens
                .last_mut()
                .expect("a variation wrote a move")
                .push(')'),
        }
    }
}

fn write_move(m: &PgnMove, ply: usize, force_number: bool, tokens: &mut Vec<String>) {
    for comment in &m.pre_comments {
        tokens.push(comment_token(comment));
    }
    let number = ply / 2 + 1;
    let mut text = String::new();
    if ply.is_multiple_of(2) {
        text = format!("{number}. ");
    } else if force_number || !m.pre_comments.is_empty() {
        text = format!("{number}... ");
    }
    text += &m.san;
    let mut nag_tokens: Vec<String> = Vec::new();
    for &n in &m.nags {
        match nag::symbol(n) {
            Some(symbol)
                if nag_tokens.is_empty() && !text.ends_with('!') && !text.ends_with('?') =>
            {
                text += symbol
            }
            _ => nag_tokens.push(format!("${n}")),
        }
    }
    tokens.push(text);
    tokens.extend(nag_tokens);
    for comment in &m.comments {
        tokens.push(comment_token(comment));
    }
}

/// `{ comment }`. A "}" would end the comment early (a `;` comment or a note can contain
/// one), so it is dropped, as python-chess does.
fn comment_token(comment: &str) -> String {
    if comment.contains('}') {
        format!("{{ {} }}", comment.replace('}', "").trim())
    } else {
        format!("{{ {comment} }}")
    }
}

/// Joins tokens with spaces, breaking lines before `width` characters.
fn wrap(tokens: &[String], width: usize) -> String {
    let mut lines: Vec<String> = Vec::new();
    let mut line = String::new();
    let mut line_len = 0;
    for token in tokens {
        let token_len = token.chars().count();
        // Keep move numbers attached to their move: tokens like "12. e4" contain one space.
        if line.is_empty() {
            line = token.clone();
            line_len = token_len;
        } else if line_len + 1 + token_len <= width {
            line.push(' ');
            line += token;
            line_len += 1 + token_len;
        } else {
            lines.push(std::mem::replace(&mut line, token.clone()));
            line_len = token_len;
        }
    }
    if !line.is_empty() {
        lines.push(line);
    }
    lines.join("\n")
}
