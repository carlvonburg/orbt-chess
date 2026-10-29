//! Text views of the move tree for the builder's sheets: the outline, search and gap names.

use crate::chess::san;
use crate::coverage::{CoverageGap, GapKind};
use crate::repertoire::{NodeId, RepertoireTree};

use super::repertoire::line_text;

/// One row of the outline: a chain of moves without branching, e.g. "3. Bb5 a6 4. Ba4".
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OutlineItem {
    /// The last node of the chain.
    pub id: NodeId,
    /// The first node of the chain.
    pub first: NodeId,
    pub text: String,
    /// The chain ends where the line branches (not at a leaf).
    pub has_children: bool,
}

/// The outline rows below `id`, one per child, each following its single-child chain.
pub fn outline_children(tree: &RepertoireTree, id: NodeId) -> Vec<OutlineItem> {
    let Some(node) = tree.get(id) else {
        return Vec::new();
    };
    node.children.iter().map(|&c| chain(tree, c)).collect()
}

fn chain(tree: &RepertoireTree, start: NodeId) -> OutlineItem {
    let mut cursor = start;
    let mut parts: Vec<String> = Vec::new();
    let mut first = true;
    while let Some(node) = tree.get(cursor) {
        let Some(mv) = &node.mv else { break };
        let ply = node.ply as i64 - 1;
        if ply % 2 == 0 {
            parts.push(format!("{}.", ply / 2 + 1));
        } else if first {
            parts.push(format!("{}...", ply / 2 + 1));
        }
        parts.push(mv.san.clone());
        first = false;
        if node.children.len() != 1 {
            break;
        }
        cursor = node.children[0];
    }
    OutlineItem {
        id: cursor,
        first: start,
        text: parts.join(" "),
        has_children: tree.get(cursor).is_some_and(|n| !n.children.is_empty()),
    }
}

/// Nodes whose move is `query` (SAN, loosely: "nf3" finds "Nf3+") or whose note contains it,
/// shallowest first, at most `limit`.
pub fn search(tree: &RepertoireTree, query: &str, limit: usize) -> Vec<NodeId> {
    let query = san::loose(query.trim()).to_lowercase();
    if query.is_empty() {
        return Vec::new();
    }
    let mut found: Vec<(u32, NodeId)> = tree
        .nodes()
        .filter(|n| {
            n.mv.as_ref()
                .is_some_and(|m| san::loose(&m.san).to_lowercase() == query)
                || n.note().to_lowercase().contains(&query)
        })
        .map(|n| (n.ply, n.id))
        .collect();
    found.sort();
    found.into_iter().take(limit).map(|(_, id)| id).collect()
}

/// A gap as a line, e.g. "1. e4 c5 2. Nf3 — your move?" or "1. e4 c5 2. Nf3 Nc6".
pub fn gap_text(tree: &RepertoireTree, gap: &CoverageGap) -> String {
    let line = line_text(tree, gap.node);
    match &gap.kind {
        GapKind::MissingMove => {
            format!(
                "{} — your move?",
                if line.is_empty() { "Start" } else { &line }
            )
        }
        GapKind::MissingReply { san, .. } => {
            let ply = tree.get(gap.node).map_or(0, |n| n.ply);
            let number = if ply.is_multiple_of(2) {
                format!("{}. ", ply / 2 + 1)
            } else if line.is_empty() {
                format!("{}... ", ply / 2 + 1)
            } else {
                String::new()
            };
            [line, number + san]
                .into_iter()
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
                .join(" ")
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tree() -> RepertoireTree {
        RepertoireTree::from_pgn("1. e4 e5 2. Nf3 (2. Nc3 Nf6 {Vienna}) 2... Nc6 3. Bb5 *")
    }

    #[test]
    fn outline_follows_chains_to_branches() {
        let t = tree();
        let top = outline_children(&t, RepertoireTree::ROOT);
        assert_eq!(top.len(), 1);
        assert_eq!(top[0].text, "1. e4 e5");
        assert!(top[0].has_children);
        let below = outline_children(&t, top[0].id);
        let texts: Vec<&str> = below.iter().map(|i| i.text.as_str()).collect();
        assert_eq!(texts, ["2. Nf3 Nc6 3. Bb5", "2. Nc3 Nf6"]);
        assert!(!below[0].has_children);
    }

    #[test]
    fn search_matches_moves_loosely_and_notes() {
        let t = tree();
        let nf3 = search(&t, " nf3 ", 100);
        assert_eq!(nf3.len(), 1);
        assert_eq!(t.get(nf3[0]).unwrap().mv.as_ref().unwrap().san, "Nf3");
        assert_eq!(search(&t, "vienna", 100).len(), 1);
        assert!(search(&t, "", 100).is_empty());
    }

    #[test]
    fn gap_text_names_the_missing_move() {
        let t = tree();
        let e5 = t
            .child_by_san(t.child_by_san(RepertoireTree::ROOT, "e4").unwrap(), "e5")
            .unwrap();
        let reply = CoverageGap {
            node: t.child_by_san(e5, "Nf3").unwrap(),
            kind: GapKind::MissingReply {
                uci: "d7d6".into(),
                san: "d6".into(),
            },
            mass: 0.1,
        };
        assert_eq!(gap_text(&t, &reply), "1. e4 e5 2. Nf3 d6");
        let own = CoverageGap {
            node: RepertoireTree::ROOT,
            kind: GapKind::MissingMove,
            mass: 1.0,
        };
        assert_eq!(gap_text(&t, &own), "Start — your move?");
    }
}
