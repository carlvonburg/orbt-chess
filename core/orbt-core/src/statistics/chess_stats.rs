//! Statistics that combine Anki's memory model with the repertoire tree (not in Anki).

use std::collections::{HashMap, HashSet};

use crate::chess::Epd;
use crate::repertoire::NodeId;
use crate::training::Trainer;
use crate::training::anki::Card;

/// Expected recall in games: the chance you know your move in the positions you will actually
/// meet. Σ reach × R over your card positions, divided by Σ reach; a card never studied
/// counts as R = 0. `now` is unix seconds.
pub fn expected_recall(
    cards: &HashMap<Epd, Card>,
    reach: &HashMap<Epd, f64>,
    now: f64,
) -> Option<f64> {
    let (mut weighted, mut total) = (0.0, 0.0);
    for (epd, &r) in reach {
        if r <= 0.0 {
            continue;
        }
        total += r;
        weighted += r * cards
            .get(epd)
            .and_then(|c| c.retrievability(now))
            .unwrap_or(0.0);
    }
    (total > 0.0).then(|| weighted / total)
}

#[derive(Clone, Debug, PartialEq)]
pub struct WeakMove {
    pub epd: Epd,
    pub lapses: i64,
    pub retrievability: Option<f64>,
    pub leech: bool,
}

/// Moves you forget most: leeches and most lapses first, then lowest recall.
pub fn weakest_moves(cards: &HashMap<Epd, Card>, now: f64, limit: usize) -> Vec<WeakMove> {
    let mut moves: Vec<WeakMove> = cards
        .iter()
        .filter_map(|(epd, card)| {
            let r = card.retrievability(now);
            (card.lapses > 0 || r.unwrap_or(1.0) < 0.85).then(|| WeakMove {
                epd: epd.clone(),
                lapses: card.lapses,
                retrievability: r,
                leech: card.leech == Some(true),
            })
        })
        .collect();
    moves.sort_by(|a, b| {
        b.leech
            .cmp(&a.leech)
            .then(b.lapses.cmp(&a.lapses))
            .then(
                a.retrievability
                    .unwrap_or(1.0)
                    .total_cmp(&b.retrievability.unwrap_or(1.0)),
            )
            .then(a.epd.cmp(&b.epd))
    });
    moves.truncate(limit);
    moves
}

/// Where a line branches, for per-branch statistics: `point` is the first position from
/// `from` where the opponent has more than one reply, and `branches` the positions after
/// each reply. A single line is followed until then (your main move, an only reply, through
/// transpositions), so a repertoire against one first move branches where it really does.
/// Replies with no move of yours below (gaps) have nothing to learn and are left out. No
/// branches when the line ends first.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BranchPoint {
    pub point: NodeId,
    pub branches: Vec<Branch>,
}

/// A reply where a line branches, e.g. "2. Nf3" or "4... Nf6".
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Branch {
    pub id: NodeId,
    pub text: String,
}

pub fn branch_point(trainer: &Trainer, from: NodeId) -> BranchPoint {
    let mut id = from;
    let mut seen = HashSet::new();
    while seen.insert(id) {
        let Some(node) = trainer.tree.get(id) else {
            break;
        };
        let next: Vec<NodeId> = trainer
            .next_after(id)
            .into_iter()
            .filter(|&n| trainer.trainable.contains(&n) && !trainer.card_nodes(n).is_empty())
            .collect();
        match next.as_slice() {
            [only] => id = *only,
            [_, _, ..] if node.side_to_move() != trainer.color => {
                let branches = next
                    .into_iter()
                    .filter_map(|n| {
                        let node = trainer.tree.get(n)?;
                        let ply = node.ply as i64 - 1;
                        let number = ply / 2 + 1;
                        let dots = if ply % 2 == 0 { "." } else { "..." };
                        Some(Branch {
                            id: n,
                            text: format!("{number}{dots} {}", node.mv.as_ref()?.san),
                        })
                    })
                    .collect();
                return BranchPoint {
                    point: id,
                    branches,
                };
            }
            _ => break,
        }
    }
    BranchPoint {
        point: id,
        branches: Vec::new(),
    }
}
