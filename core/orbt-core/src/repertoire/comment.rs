//! Helpers for PGN comments with embedded commands like `[%cal Ge2e4,Rd7d5]`.

/// Byte ranges of `[%...]` commands (the regex `\[%[^\]]*\]`).
fn command_ranges(comment: &str) -> Vec<(usize, usize)> {
    let mut ranges = Vec::new();
    let mut from = 0;
    while let Some(start) = comment[from..].find("[%").map(|i| from + i) {
        match comment[start..].find(']') {
            Some(len) => {
                ranges.push((start, start + len + 1));
                from = start + len + 1;
            }
            None => break,
        }
    }
    ranges
}

pub fn commands(comment: &str) -> Vec<String> {
    command_ranges(comment)
        .into_iter()
        .map(|(a, b)| comment[a..b].to_owned())
        .collect()
}

/// The comment without its commands.
pub fn text(comment: &str) -> String {
    let mut out = String::new();
    let mut last = 0;
    for (a, b) in command_ranges(comment) {
        out += &comment[last..a];
        last = b;
    }
    out += &comment[last..];
    out.trim().to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_commands_and_text() {
        let c = "[%cal Ge2e4,Rd7d5] old idea [%csl Gd4]";
        assert_eq!(commands(c), ["[%cal Ge2e4,Rd7d5]", "[%csl Gd4]"]);
        assert_eq!(text(c), "old idea");
        assert_eq!(text("[%unclosed"), "[%unclosed");
    }
}
