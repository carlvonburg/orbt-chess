//! Loose SAN handling for moves typed in books, PGN files and other programs.

fn trim(s: &str) -> &str {
    // Swift's `.whitespaces`: spaces and tabs, not line breaks.
    s.trim_matches(|c: char| c.is_whitespace() && c != '\n' && c != '\r')
}

/// Strips annotation glyphs, "e.p." and surrounding whitespace; keeps check marks.
pub fn normalized(san: &str) -> String {
    let mut s = trim(san)
        .replace("e.p.", "")
        .replace("0-0-0", "O-O-O")
        .replace("0-0", "O-O");
    while s.ends_with(['!', '?']) {
        s.pop();
    }
    trim(&s).to_owned()
}

/// Normalized and without check/mate marks, for comparing moves.
pub fn loose(san: &str) -> String {
    normalized(san).replace(['+', '#'], "")
}

/// A loose SAN ("Ngf3", "exd5", "e8=Q") split into its parts.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Parts {
    pub piece: char,
    pub disambiguation: String,
    pub destination: String,
    pub promotion: String,
}

pub(crate) fn parts(san: &str) -> Option<Parts> {
    if san.starts_with("O-O") {
        return None;
    }
    let mut body: Vec<char> = san.chars().filter(|&c| c != 'x').collect();
    let mut promotion = String::new();
    if let Some(eq) = body.iter().position(|&c| c == '=') {
        promotion = body[eq + 1..].iter().collect();
        body.truncate(eq);
    }
    if body.len() < 2 {
        return None;
    }
    let destination: String = body[body.len() - 2..].iter().collect();
    let mut rest = &body[..body.len() - 2];
    let mut piece = 'P';
    if let Some(&first) = rest.first()
        && first.is_uppercase()
    {
        piece = first;
        rest = &rest[1..];
    }
    Some(Parts {
        piece,
        disambiguation: rest.iter().collect(),
        destination,
        promotion,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_glyphs_and_zeros() {
        assert_eq!(normalized(" Bb5!? "), "Bb5");
        assert_eq!(normalized("0-0-0+"), "O-O-O+");
        assert_eq!(normalized("exd6e.p."), "exd6");
        assert_eq!(loose("Qh5#"), "Qh5");
    }

    #[test]
    fn splits_parts() {
        let p = parts("Ngf3").unwrap();
        assert_eq!(
            (p.piece, p.disambiguation.as_str(), p.destination.as_str()),
            ('N', "g", "f3")
        );
        let p = parts("exd8=Q").unwrap();
        assert_eq!(
            (p.piece, p.disambiguation.as_str(), p.promotion.as_str()),
            ('P', "e", "Q")
        );
        assert_eq!(parts("O-O"), None);
    }
}
