use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use super::anki::{Card, CardQueue, CardType};
use crate::chess::{Epd, PlayedMove, Side};
use crate::repertoire::{NodeId, RepertoireTree};

/// Anki: a review card with an interval of 21 days or more is mature.
pub const MATURE_INTERVAL: i64 = 21;

/// Card bookkeeping and line selection for a repertoire.
///
/// A card is a position (EPD) where it is your move and the repertoire has a main move.
/// Transposed positions share one card. Alternative moves of yours (not the first) and
/// everything below them are not trained. A line that ends in a position whose moves are
/// stored at another node continues there.
#[derive(Clone, Debug)]
pub struct Trainer {
    pub tree: Arc<RepertoireTree>,
    pub color: Side,
    /// Nodes on main lines (not below an alternative move of yours).
    pub trainable: HashSet<NodeId>,
    /// All card positions, computed once: study sessions test every card against it.
    pub card_epd_set: HashSet<Epd>,
}

/// Returns the first of the maximal elements, like Swift's `max(by:)` (Rust's `max_by`
/// returns the last).
pub(crate) fn first_max_by<T: Copy>(
    items: impl IntoIterator<Item = T>,
    mut less: impl FnMut(&T, &T) -> bool,
) -> Option<T> {
    let mut best: Option<T> = None;
    for item in items {
        match &best {
            Some(b) if !less(b, &item) => {}
            _ => best = Some(item),
        }
    }
    best
}

/// Returns the first of the minimal elements, like Swift's `min(by:)`.
pub(crate) fn first_min_by<T: Copy>(
    items: impl IntoIterator<Item = T>,
    mut less: impl FnMut(&T, &T) -> bool,
) -> Option<T> {
    let mut best: Option<T> = None;
    for item in items {
        match &best {
            Some(b) if !less(&item, b) => {}
            _ => best = Some(item),
        }
    }
    best
}

impl Trainer {
    pub fn new(tree: Arc<RepertoireTree>, color: Side) -> Trainer {
        let mut trainable = HashSet::new();
        let mut stack = vec![RepertoireTree::ROOT];
        while let Some(id) = stack.pop() {
            if tree.get(id).is_none() || !trainable.insert(id) {
                continue;
            }
            stack.extend(next_after(&tree, color, id));
        }
        let mut trainer = Trainer {
            tree,
            color,
            trainable,
            card_epd_set: HashSet::new(),
        };
        trainer.card_epd_set = trainer.card_epds(RepertoireTree::ROOT);
        trainer
    }

    pub(crate) fn next_after(&self, id: NodeId) -> Vec<NodeId> {
        next_after(&self.tree, self.color, id)
    }

    /// Trainable nodes below `root`, following transpositions, each once.
    pub(crate) fn reachable(&self, root: NodeId) -> Vec<NodeId> {
        let mut result = Vec::new();
        let mut seen = HashSet::new();
        let mut stack = vec![root];
        while let Some(id) = stack.pop() {
            if !self.trainable.contains(&id) || !seen.insert(id) {
                continue;
            }
            result.push(id);
            stack.extend(self.next_after(id).into_iter().rev());
        }
        result
    }

    /// Your-turn nodes with a main move, i.e. where a card is asked.
    pub fn card_nodes(&self, root: NodeId) -> Vec<NodeId> {
        self.reachable(root)
            .into_iter()
            .filter(|&id| {
                self.tree
                    .get(id)
                    .is_some_and(|n| n.side_to_move() == self.color && !n.children.is_empty())
            })
            .collect()
    }

    pub fn card_epds(&self, root: NodeId) -> HashSet<Epd> {
        self.card_nodes(root)
            .into_iter()
            .map(|id| self.tree[id].epd.clone())
            .collect()
    }

    /// Your-turn positions with a move saved that are only reached below an alternative move
    /// of yours. Their cards are suspended (as in Anki), so a line keeps its progress when it
    /// stops being the main line and gets it back when it is the main line again.
    pub fn suspended_card_epds(&self, root: NodeId) -> HashSet<Epd> {
        let mut result = HashSet::new();
        for id in self.tree.subtree(root) {
            if self.trainable.contains(&id) {
                continue;
            }
            let Some(node) = self.tree.get(id) else {
                continue;
            };
            if node.side_to_move() == self.color
                && !node.children.is_empty()
                && !self.card_epd_set.contains(&node.epd)
            {
                result.insert(node.epd.clone());
            }
        }
        result
    }

    /// The main move for a card position (first node with that EPD that has one).
    pub fn expected_move(&self, id: NodeId) -> Option<&PlayedMove> {
        let node = self.tree.get(id)?;
        if let Some(&main) = node.children.first() {
            return self.tree.get(main)?.mv.as_ref();
        }
        for &other in self.tree.nodes_at(&node.epd) {
            if self.trainable.contains(&other)
                && let Some(&main) = self.tree.get(other).and_then(|n| n.children.first())
            {
                return self.tree.get(main)?.mv.as_ref();
            }
        }
        None
    }

    pub fn progress(&self, root: NodeId, cards: &HashMap<Epd, Card>) -> Progress {
        let mut p = Progress::default();
        for epd in self.card_epds(root) {
            p.cards += 1;
            if let Some(card) = cards.get(&epd) {
                p.add(card);
            }
        }
        p.suspended = self.suspended_card_epds(root).len() as i64;
        p
    }

    /// Every line below `root` once (for "train this branch").
    pub fn all_lines(&self, root: NodeId) -> Vec<Vec<NodeId>> {
        if !self.trainable.contains(&root) {
            return Vec::new();
        }
        let mut lines = Vec::new();
        // A transposed position's continuation is drilled once: lines into a position stored
        // inside this branch end there, and one stored elsewhere is entered by one line only.
        let mut continued: HashSet<NodeId> = HashSet::new();
        let mut stack: Vec<Vec<NodeId>> = vec![self.tree.path(root)];
        while let Some(line) = stack.pop() {
            let id = *line.last().expect("non-empty line");
            let mut next_nodes: Vec<NodeId> = self
                .next_after(id)
                .into_iter()
                .filter(|n| self.trainable.contains(n))
                .collect();
            if self.tree.get(id).is_some_and(|n| n.children.is_empty())
                && let Some(target) = self.tree.transposition_target(id)
                && (target == root
                    || self.tree.is_ancestor(root, target)
                    || !continued.insert(target))
            {
                next_nodes.clear();
            }
            if next_nodes.is_empty() {
                lines.push(line);
            } else {
                for &n in next_nodes.iter().rev() {
                    let mut extended = line.clone();
                    extended.push(n);
                    stack.push(extended);
                }
            }
        }
        lines
    }

    /// Path to `target`, continued to a leaf choosing opponent moves by `score`.
    pub fn line_through(&self, target: NodeId, score: &dyn Fn(NodeId) -> f64) -> Vec<NodeId> {
        let mut nodes = self.tree.path(target);
        let mut visited: HashSet<NodeId> = nodes.iter().copied().collect();
        let mut cursor = target;
        loop {
            let options = self
                .next_after(cursor)
                .into_iter()
                .filter(|n| self.trainable.contains(n) && !visited.contains(n));
            let Some(next) = first_max_by(options, |a, b| score(*a) < score(*b)) else {
                break;
            };
            nodes.push(next);
            visited.insert(next);
            cursor = next;
        }
        nodes
    }

    /// New-card order: depth first, the most reached continuation first, so a line is
    /// learned before the next one.
    pub fn new_card_order(&self, root: NodeId, reach: &HashMap<NodeId, f64>) -> Vec<Epd> {
        let mut order = Vec::new();
        let mut seen: HashSet<Epd> = HashSet::new();
        let mut visited: HashSet<NodeId> = HashSet::new();
        let mut stack = vec![root];
        while let Some(id) = stack.pop() {
            if !self.trainable.contains(&id) || !visited.insert(id) {
                continue;
            }
            let Some(node) = self.tree.get(id) else {
                continue;
            };
            let mut nexts = self.next_after(id);
            if node.side_to_move() == self.color {
                if !nexts.is_empty() && seen.insert(node.epd.clone()) {
                    order.push(node.epd.clone());
                }
            } else {
                let r = |n: &NodeId| reach.get(n).copied().unwrap_or(0.0);
                // Stable: equal reach keeps the stored move order.
                nexts.sort_by(|a, b| r(b).total_cmp(&r(a)));
            }
            stack.extend(nexts.into_iter().rev());
        }
        order
    }

    /// The highest reach of any node with each position.
    pub fn reach_by_epd(&self, reach: &HashMap<NodeId, f64>) -> HashMap<Epd, f64> {
        let mut result: HashMap<Epd, f64> = HashMap::new();
        for (&id, &r) in reach {
            if let Some(node) = self.tree.get(id) {
                let e = result.entry(node.epd.clone()).or_insert(0.0);
                *e = e.max(r);
            }
        }
        result
    }
}

/// Nodes a line continues to: your main move, every opponent reply, or for a position
/// whose moves are stored elsewhere, that node's continuations.
fn next_after(tree: &RepertoireTree, color: Side, id: NodeId) -> Vec<NodeId> {
    let Some(node) = tree.get(id) else {
        return Vec::new();
    };
    let holder = if node.children.is_empty() {
        match tree.transposition_target(id).and_then(|t| tree.get(t)) {
            Some(h) => h,
            None => return Vec::new(),
        }
    } else {
        node
    };
    if holder.side_to_move() == color {
        holder.children.iter().take(1).copied().collect()
    } else {
        holder.children.clone()
    }
}

/// Your moves by Anki's card-count groups: learning (learn and relearn), young (review
/// interval under 21 days) and mature.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Progress {
    pub cards: i64,
    pub learning: i64,
    pub young: i64,
    pub mature: i64,
    /// Positions below your alternative moves; not part of `cards`.
    pub suspended: i64,
}

impl Progress {
    pub fn studied(&self) -> i64 {
        self.learning + self.young + self.mature
    }

    pub fn not_studied(&self) -> i64 {
        self.cards - self.studied()
    }

    pub fn add(&mut self, card: &Card) {
        if card.queue == CardQueue::Suspended {
            return;
        }
        match card.ctype {
            CardType::New => {}
            CardType::Learn | CardType::Relearn => self.learning += 1,
            CardType::Review if card.interval < MATURE_INTERVAL => self.young += 1,
            CardType::Review => self.mature += 1,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LineOutcome {
    Correct,
    /// A saved alternative move of yours, not the main one. Try again, no penalty.
    Alternative,
    Wrong {
        expected: PlayedMove,
    },
}

/// Plays one line: the app plays the opponent's moves, the user plays theirs.
/// Modeled on the Lichess gamebook flow (play / good / bad / end).
#[derive(Clone, Debug)]
pub struct LineRun {
    pub trainer: Arc<Trainer>,
    pub nodes: Vec<NodeId>,
    /// Index into `nodes` of the position on the board.
    pub index: usize,
}

impl LineRun {
    pub fn new(trainer: Arc<Trainer>, nodes: Vec<NodeId>, index: usize) -> LineRun {
        let index = index.min(nodes.len().saturating_sub(1));
        LineRun {
            trainer,
            nodes,
            index,
        }
    }

    pub fn current_node(&self) -> NodeId {
        self.nodes[self.index]
    }

    pub fn is_finished(&self) -> bool {
        self.index + 1 >= self.nodes.len()
    }

    /// Your move is next on the line (it may still be played for you).
    pub fn is_own_turn(&self) -> bool {
        !self.is_finished()
            && self
                .trainer
                .tree
                .get(self.current_node())
                .is_some_and(|n| n.side_to_move() == self.trainer.color)
    }

    /// The move to play now.
    pub fn expected(&self) -> Option<&PlayedMove> {
        if self.is_finished() {
            return None;
        }
        self.trainer
            .tree
            .get(self.nodes[self.index + 1])?
            .mv
            .as_ref()
    }

    /// Plays the next move on the line (opponent's, or yours played for you).
    pub fn advance(&mut self) -> Option<PlayedMove> {
        if self.is_finished() {
            return None;
        }
        self.index += 1;
        self.trainer.tree.get(self.current_node())?.mv.clone()
    }

    /// Takes back the last move on the board.
    pub fn take_back(&mut self) {
        self.index = self.index.saturating_sub(1);
    }

    /// Checks the user's move; advances when it is the expected one.
    pub fn user_played(&mut self, uci: &str) -> LineOutcome {
        let tree = &self.trainer.tree;
        let (Some(expected), Some(node)) =
            (self.expected().cloned(), tree.get(self.current_node()))
        else {
            return LineOutcome::Correct;
        };
        if uci == expected.uci {
            self.index += 1;
            return LineOutcome::Correct;
        }
        let holder = if node.children.is_empty() {
            tree.transposition_target(node.id)
                .and_then(|t| tree.get(t))
                .unwrap_or(node)
        } else {
            node
        };
        let is_alternative = holder.children.iter().skip(1).any(|&c| {
            tree.get(c)
                .and_then(|n| n.mv.as_ref())
                .is_some_and(|m| m.uci == uci)
        });
        if is_alternative {
            LineOutcome::Alternative
        } else {
            LineOutcome::Wrong { expected }
        }
    }
}
