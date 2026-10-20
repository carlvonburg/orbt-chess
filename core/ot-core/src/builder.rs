//! The builder's navigation: the current node plus a draft of moves played on the board that
//! are not saved yet, and how they meet transpositions.

use crate::chess::{BoardSquare, ChessPosition, PieceKind, PlayedMove, Side};
use crate::coverage::{CoverageGap, GapKind, ReplyInfo, StatsSource};
use crate::document::{Changes, Repertoire};
use crate::repertoire::{NodeId, RepertoireTree};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ArrowStyle {
    /// Your saved moves.
    Mine,
    /// Opponent replies in the repertoire.
    Opponent,
    /// Required opponent replies that are missing.
    Gap,
    /// The move to play, in a drill.
    Hint,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Arrow {
    pub from: BoardSquare,
    pub to: BoardSquare,
    pub style: ArrowStyle,
    /// Fraction of a square.
    pub width: f64,
    pub opacity: f64,
    pub dashed: bool,
}

impl Arrow {
    pub fn new(
        from: BoardSquare,
        to: BoardSquare,
        style: ArrowStyle,
        width: f64,
        opacity: f64,
    ) -> Arrow {
        Arrow {
            from,
            to,
            style,
            width,
            opacity,
            dashed: false,
        }
    }

    /// An arrow for a move; None if its UCI is not a move.
    pub fn for_move(m: &PlayedMove, style: ArrowStyle, width: f64, opacity: f64) -> Option<Arrow> {
        Some(Arrow::new(m.from()?, m.to()?, style, width, opacity))
    }
}

/// Merges the changes of consecutive operations: later save requests replace earlier ones.
pub(crate) fn merge(into: &mut Changes, other: Changes) {
    into.revision = into.revision.max(other.revision);
    into.tree_changed |= other.tree_changed;
    into.reload_stats |= other.reload_stats;
    into.coverage_check |= other.coverage_check;
    if other.save_pgn_after_ms.is_some() {
        into.save_pgn_after_ms = other.save_pgn_after_ms;
    }
    if other.save_sidecar_after_ms.is_some() {
        into.save_sidecar_after_ms = other.save_sidecar_after_ms;
    }
}

#[derive(Clone, Debug)]
pub struct Builder {
    pub current: NodeId,
    /// Moves played past `current` that are not in the repertoire yet.
    draft: Vec<PlayedMove>,
    pub orientation: Side,
    /// False while browsing from a drill, so the builder's last position is not overwritten.
    remembers_position: bool,
}

impl Builder {
    /// Opens at `start`, or at the last position looked at.
    pub fn new(doc: &Repertoire, start: Option<NodeId>) -> Builder {
        let tree = doc.tree();
        let current = match start {
            Some(s) if tree.get(s).is_some() => s,
            _ => doc
                .sidecar()
                .last_line
                .as_ref()
                .and_then(|line| tree.node_following_uci(line))
                .unwrap_or(RepertoireTree::ROOT),
        };
        Builder {
            current,
            draft: Vec::new(),
            orientation: doc.color(),
            remembers_position: start.is_none(),
        }
    }

    pub fn draft(&self) -> &[PlayedMove] {
        &self.draft
    }

    pub fn has_draft(&self) -> bool {
        !self.draft.is_empty()
    }

    fn node_position(&self, doc: &Repertoire) -> ChessPosition {
        doc.tree()
            .get(self.current)
            .map(|n| n.position.clone())
            .unwrap_or_default()
    }

    /// Position on the board (after the draft).
    pub fn position(&self, doc: &Repertoire) -> ChessPosition {
        let mut p = self.node_position(doc);
        for m in &self.draft {
            if let Some((_, next)) = p.play_uci(&m.uci) {
                p = next;
            }
        }
        p
    }

    /// When the current position's lines are stored at another node (a transposition), that node.
    pub fn continuation(&self, doc: &Repertoire) -> Option<NodeId> {
        if self.draft.is_empty() {
            doc.tree().transposition_target(self.current)
        } else {
            None
        }
    }

    /// While a draft is on the board: a saved node with the same position whose lines continue
    /// from it, i.e. the draft transposes into your repertoire.
    pub fn draft_transposition(&self, doc: &Repertoire) -> Option<NodeId> {
        if self.draft.is_empty() {
            return None;
        }
        let tree = doc.tree();
        tree.nodes_at(&self.position(doc).epd())
            .iter()
            .copied()
            .filter(|&c| {
                c != self.current
                    && tree.get(c).is_some_and(|n| !n.children.is_empty())
                    && !tree.is_ancestor(c, self.current)
            })
            .min()
    }

    /// The node whose moves the panels show: the current one, or where its lines continue.
    pub fn shown_node(&self, doc: &Repertoire) -> NodeId {
        self.continuation(doc)
            .or_else(|| self.draft_transposition(doc))
            .unwrap_or(self.current)
    }

    /// The saved node with lines that `uci`, played on the board, leads into by another move
    /// order. None when the move is your saved line itself, or reaches nothing you have.
    pub fn transposition_after(&self, doc: &Repertoire, uci: &str) -> Option<NodeId> {
        let tree = doc.tree();
        let (_, next) = self.position(doc).play_uci(uci)?;
        let own_child = if self.draft.is_empty() || self.draft_transposition(doc).is_some() {
            tree.child_by_uci(self.shown_node(doc), uci)
        } else {
            None
        };
        tree.nodes_at(&next.epd())
            .iter()
            .copied()
            .filter(|&c| {
                Some(c) != own_child && tree.get(c).is_some_and(|n| !n.children.is_empty())
            })
            .min()
    }

    pub fn can_forward(&self, doc: &Repertoire) -> bool {
        (self.draft.is_empty() || self.draft_transposition(doc).is_some())
            && doc
                .tree()
                .get(self.shown_node(doc))
                .is_some_and(|n| !n.children.is_empty())
    }

    pub fn last_move(&self, doc: &Repertoire) -> Option<PlayedMove> {
        self.draft
            .last()
            .cloned()
            .or_else(|| doc.tree().get(self.current).and_then(|n| n.mv.clone()))
    }

    pub fn is_user_turn_on_board(&self, doc: &Repertoire) -> bool {
        self.position(doc).side_to_move() == doc.color()
    }

    /// Probability of reaching the board position: the current node's reach times the share of
    /// each opponent move in the draft. None while a needed statistic is missing.
    pub fn reach_on_board(&self, doc: &Repertoire, stats: &dyn StatsSource) -> Option<f64> {
        let mut reach = doc.coverage().get(self.current)?.reach?;
        let mut p = self.node_position(doc);
        for m in &self.draft {
            if p.side_to_move() != doc.color() {
                reach *= stats.stats(&p.epd())?.share(&m.uci);
            }
            if let Some((_, next)) = p.play_uci(&m.uci) {
                p = next;
            }
        }
        Some(reach)
    }

    /// Opponent replies at the board position while a draft is on it.
    pub fn draft_replies(
        &self,
        doc: &Repertoire,
        stats: &dyn StatsSource,
    ) -> Option<Vec<ReplyInfo>> {
        if !self.has_draft() || self.is_user_turn_on_board(doc) {
            return None;
        }
        let epd = self.position(doc).epd();
        let s = stats.stats(&epd)?;
        Some(
            doc.coverage()
                .draft_replies(&epd, s, self.reach_on_board(doc, stats)),
        )
    }

    /// Moves from the start to the board position, including the draft.
    pub fn moves_to_board(&self, doc: &Repertoire) -> Vec<PlayedMove> {
        let mut moves = doc.tree().moves(self.current);
        moves.extend(self.draft.iter().cloned());
        moves
    }

    // Navigation

    pub fn go(&mut self, doc: &mut Repertoire, id: NodeId, stats: &dyn StatsSource) -> Changes {
        let mut changes = Changes::default();
        let Some(parent) = doc.tree().get(id).map(|n| n.parent) else {
            return changes;
        };
        if let Some(target) = self.draft_transposition(doc)
            && parent == Some(target)
        {
            merge(&mut changes, self.save_transposing_draft(doc, stats));
        }
        self.draft.clear();
        self.current = id;
        merge(&mut changes, self.remember(doc));
        changes
    }

    pub fn back(&mut self, doc: &mut Repertoire) -> Changes {
        if self.draft.pop().is_some() {
            return Changes::default();
        }
        match doc.tree().get(self.current).and_then(|n| n.parent) {
            Some(parent) => {
                self.current = parent;
                self.remember(doc)
            }
            None => Changes::default(),
        }
    }

    pub fn forward(&mut self, doc: &mut Repertoire, stats: &dyn StatsSource) -> Changes {
        let mut changes = self.save_transposing_draft(doc, stats);
        if !self.draft.is_empty() {
            return changes;
        }
        if let Some(&main) = doc
            .tree()
            .get(self.shown_node(doc))
            .and_then(|n| n.children.first())
        {
            self.current = main;
            merge(&mut changes, self.remember(doc));
        }
        changes
    }

    /// Switch to the previous/next sibling line (↑/↓ keys).
    pub fn sibling(
        &mut self,
        doc: &mut Repertoire,
        offset: i64,
        stats: &dyn StatsSource,
    ) -> Changes {
        if !self.draft.is_empty() {
            return Changes::default();
        }
        let tree = doc.tree();
        let Some(siblings) = tree
            .get(self.current)
            .and_then(|n| n.parent)
            .and_then(|p| tree.get(p))
            .map(|p| p.children.clone())
        else {
            return Changes::default();
        };
        let Some(i) = siblings.iter().position(|&c| c == self.current) else {
            return Changes::default();
        };
        let n = siblings.len() as i64;
        let j = ((i as i64 + offset) % n + n) % n;
        self.go(doc, siblings[j as usize], stats)
    }

    /// A move made on the board: follows the repertoire if the move exists there, otherwise
    /// extends the draft.
    pub fn play(
        &mut self,
        doc: &mut Repertoire,
        from: BoardSquare,
        to: BoardSquare,
        promotion: Option<PieceKind>,
        stats: &dyn StatsSource,
    ) -> Changes {
        match self.position(doc).play(from, to, promotion) {
            Some((mv, _)) => self.play_move(doc, mv, stats),
            None => Changes::default(),
        }
    }

    pub fn play_uci(
        &mut self,
        doc: &mut Repertoire,
        uci: &str,
        stats: &dyn StatsSource,
    ) -> Changes {
        match self.position(doc).play_uci(uci) {
            Some((mv, _)) => self.play_move(doc, mv, stats),
            None => Changes::default(),
        }
    }

    fn play_move(
        &mut self,
        doc: &mut Repertoire,
        mv: PlayedMove,
        stats: &dyn StatsSource,
    ) -> Changes {
        let mut changes = self.save_transposing_draft(doc, stats);
        if self.draft.is_empty()
            && let Some(child) = doc.tree().child_by_uci(self.shown_node(doc), &mv.uci)
        {
            merge(&mut changes, self.go(doc, child, stats));
        } else {
            self.draft.push(mv);
        }
        changes
    }

    /// Previews a reply or candidate from the panel as a draft move.
    pub fn preview(&mut self, doc: &mut Repertoire, uci: &str, stats: &dyn StatsSource) -> Changes {
        if self.draft_transposition(doc).is_none() {
            self.draft.clear();
        }
        self.play_uci(doc, uci, stats)
    }

    /// Going on from a draft that transposes into your repertoire: saves the moves that reach
    /// the position (they now cover it as a transposition), so you continue where its lines
    /// are stored instead of copying them under the new move order.
    fn save_transposing_draft(&mut self, doc: &mut Repertoire, stats: &dyn StatsSource) -> Changes {
        if self.draft_transposition(doc).is_some() {
            self.save_draft(doc, stats)
        } else {
            Changes::default()
        }
    }

    // Editing

    pub fn save_draft(&mut self, doc: &mut Repertoire, stats: &dyn StatsSource) -> Changes {
        // New moves at a transposition go where that position's lines are stored.
        let parent = doc
            .tree()
            .transposition_target(self.current)
            .unwrap_or(self.current);
        if self.draft.is_empty() {
            return Changes::default();
        }
        let ucis: Vec<String> = self.draft.iter().map(|m| m.uci.clone()).collect();
        let (last, mut changes) = doc.add_line(&ucis, parent, stats);
        let Some(last) = last else {
            return changes;
        };
        self.draft.clear();
        self.current = last;
        merge(&mut changes, self.remember(doc));
        changes
    }

    pub fn discard_draft(&mut self) {
        self.draft.clear();
    }

    /// Deletes a move and everything below it; leaves it first if the board is there.
    pub fn delete(&mut self, doc: &mut Repertoire, id: NodeId, stats: &dyn StatsSource) -> Changes {
        let mut changes = Changes::default();
        let tree = doc.tree();
        if (id == self.current || tree.is_ancestor(id, self.current))
            && let Some(parent) = tree.get(id).and_then(|n| n.parent)
        {
            merge(&mut changes, self.go(doc, parent, stats));
        }
        merge(&mut changes, doc.delete(id, stats));
        changes
    }

    /// Undoes the last edit. When it removed the position on the board, goes back along the
    /// same moves as far as they are still saved.
    pub fn undo(&mut self, doc: &mut Repertoire, stats: &dyn StatsSource) -> Changes {
        let ucis: Vec<String> = doc
            .tree()
            .moves(self.current)
            .into_iter()
            .map(|m| m.uci)
            .collect();
        let mut changes = doc.undo(stats);
        let tree = doc.tree();
        let mut node = RepertoireTree::ROOT;
        for uci in &ucis {
            match tree.child_by_uci(node, uci) {
                Some(child) => node = child,
                None => break,
            }
        }
        if node != self.current || tree.get(self.current).is_none() {
            self.draft.clear();
            self.current = node;
            merge(&mut changes, self.remember(doc));
        }
        changes
    }

    /// Goes to the biggest gap below the current node, or in the whole repertoire.
    pub fn go_to_biggest_gap(&mut self, doc: &mut Repertoire, stats: &dyn StatsSource) -> Changes {
        let gap = doc
            .coverage()
            .get(self.current)
            .and_then(|c| c.biggest_gap.clone())
            .or_else(|| doc.coverage().root().and_then(|r| r.biggest_gap.clone()));
        match gap {
            Some(gap) => self.go_to_gap(doc, &gap, stats),
            None => Changes::default(),
        }
    }

    pub fn go_to_gap(
        &mut self,
        doc: &mut Repertoire,
        gap: &CoverageGap,
        stats: &dyn StatsSource,
    ) -> Changes {
        let mut changes = self.go(doc, gap.node, stats);
        if let GapKind::MissingReply { uci, .. } = &gap.kind {
            merge(&mut changes, self.play_uci(doc, uci, stats));
        }
        changes
    }

    fn remember(&self, doc: &mut Repertoire) -> Changes {
        if !self.remembers_position {
            return Changes::default();
        }
        let ucis = doc
            .tree()
            .moves(self.current)
            .into_iter()
            .map(|m| m.uci)
            .collect();
        doc.remember_line(ucis)
    }

    /// Arrows for the current node: your saved moves, or the opponent's replies sized by
    /// frequency with missing required replies as dashed arrows.
    pub fn arrows(&self, doc: &Repertoire) -> Vec<Arrow> {
        if !(self.draft.is_empty() || self.draft_transposition(doc).is_some()) {
            return Vec::new();
        }
        let tree = doc.tree();
        let Some(node) = tree.get(self.shown_node(doc)) else {
            return Vec::new();
        };
        let child_moves = || {
            node.children
                .iter()
                .filter_map(|&c| tree.get(c)?.mv.clone())
        };
        if node.side_to_move() == doc.color() {
            return child_moves()
                .enumerate()
                .filter_map(|(i, m)| {
                    let (width, opacity) = if i == 0 { (0.2, 0.85) } else { (0.12, 0.5) };
                    Arrow::for_move(&m, ArrowStyle::Mine, width, opacity)
                })
                .collect();
        }
        let replies = doc.coverage().get(node.id).map(|c| &c.replies);
        let Some(replies) = replies.filter(|r| !r.is_empty()) else {
            return child_moves()
                .filter_map(|m| Arrow::for_move(&m, ArrowStyle::Opponent, 0.12, 0.6))
                .collect();
        };
        let max_share = replies.iter().map(|r| r.share).fold(f64::MIN, f64::max);
        replies
            .iter()
            .take(6)
            .filter_map(|reply| {
                let from = BoardSquare::parse(reply.uci.get(0..2)?)?;
                let to = BoardSquare::parse(reply.uci.get(2..4)?)?;
                let in_repertoire = reply.child.is_some() || reply.transposes_to.is_some();
                if !in_repertoire && !reply.required {
                    return None;
                }
                let rel = if max_share > 0.0 {
                    reply.share / max_share
                } else {
                    0.0
                };
                Some(Arrow {
                    from,
                    to,
                    style: if in_repertoire {
                        ArrowStyle::Opponent
                    } else {
                        ArrowStyle::Gap
                    },
                    width: 0.04 + 0.14 * rel,
                    opacity: 0.3 + 0.6 * rel,
                    dashed: !in_repertoire,
                })
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use super::*;
    use crate::chess::Epd;
    use crate::document::StudyDefaults;
    use crate::explorer::ExplorerStats;
    use crate::formats::{Sidecar, Timestamp};

    fn doc(pgn: &str, color: Side) -> Repertoire {
        let sidecar = Sidecar::new("ID".into(), color, Timestamp(0)).encoded();
        Repertoire::open(
            pgn,
            &sidecar,
            StudyDefaults::default(),
            &HashMap::<Epd, ExplorerStats>::new(),
        )
        .unwrap()
        .0
    }

    fn none() -> HashMap<Epd, ExplorerStats> {
        HashMap::new()
    }

    #[test]
    fn drafts_follow_saved_moves_and_save_as_a_line() {
        let mut d = doc("1. e4 e5 2. Nf3 *", Side::White);
        let mut b = Builder::new(&d, None);
        assert_eq!(b.current, RepertoireTree::ROOT);
        b.play_uci(&mut d, "e2e4", &none());
        assert!(!b.has_draft());
        assert_eq!(d.tree()[b.current].mv.as_ref().unwrap().san, "e4");
        b.play_uci(&mut d, "c7c5", &none());
        b.play_uci(&mut d, "g1f3", &none());
        assert_eq!(b.draft().len(), 2);
        assert!(!b.is_user_turn_on_board(&d));
        let changes = b.save_draft(&mut d, &none());
        assert!(changes.tree_changed);
        assert!(!b.has_draft());
        assert_eq!(d.line_text(b.current), "1. e4 c5 2. Nf3");
        // Remembered as the last position.
        assert_eq!(
            d.sidecar().last_line.as_ref().unwrap(),
            &vec!["e2e4", "c7c5", "g1f3"]
        );
        b.back(&mut d);
        assert_eq!(d.line_text(b.current), "1. e4 c5");
        let reopened = Builder::new(&d, None);
        assert_eq!(d.line_text(reopened.current), "1. e4 c5");
    }

    #[test]
    fn undo_goes_back_to_a_saved_position() {
        let mut d = doc("1. e4 e5 *", Side::White);
        let mut b = Builder::new(&d, None);
        b.play_uci(&mut d, "e2e4", &none());
        b.play_uci(&mut d, "c7c5", &none());
        b.play_uci(&mut d, "g1f3", &none());
        b.save_draft(&mut d, &none());
        assert_eq!(d.line_text(b.current), "1. e4 c5 2. Nf3");
        let changes = b.undo(&mut d, &none());
        assert!(changes.tree_changed);
        assert_eq!(d.line_text(b.current), "1. e4");
        assert!(d.tree().get(b.current).is_some());
    }

    #[test]
    fn a_draft_that_transposes_continues_where_the_lines_are() {
        let mut d = doc("1. d4 Nf6 2. c4 e6 3. Nc3 *", Side::White);
        let mut b = Builder::new(&d, None);
        for uci in ["c2c4", "e7e6", "d2d4", "g8f6"] {
            b.play_uci(&mut d, uci, &none());
        }
        let target = b.draft_transposition(&d).expect("transposes");
        assert_eq!(d.line_text(target), "1. d4 Nf6 2. c4 e6");
        assert!(b.can_forward(&d));
        // Going on saves the transposing move order and continues at the stored lines.
        b.forward(&mut d, &none());
        assert!(!b.has_draft());
        assert_eq!(d.line_text(b.current), "1. d4 Nf6 2. c4 e6 3. Nc3");
        assert!(d.tree().find_san("c4 e6 d4 Nf6").is_some());
    }

    #[test]
    fn arrows_show_your_moves() {
        let d = doc("1. e4 (1. d4) *", Side::White);
        let b = Builder::new(&d, None);
        let arrows = b.arrows(&d);
        assert_eq!(arrows.len(), 2);
        assert_eq!(arrows[0].style, ArrowStyle::Mine);
        assert_eq!(arrows[0].from.to_string(), "e2");
        assert!(arrows[0].width > arrows[1].width);
    }
}
