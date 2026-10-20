//! Statistics that combine Anki's memory model with the repertoire tree (not in Anki).

use std::collections::HashMap;

use crate::chess::Epd;
use crate::repertoire::{NodeId, RepertoireTree};
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

/// The opening branches for per-branch statistics: the positions after the opponent's first
/// move (for White, after your first move and their reply).
pub fn opening_branches(trainer: &Trainer) -> Vec<NodeId> {
    let tree = &trainer.tree;
    let mut result = Vec::new();
    let mut stack = vec![RepertoireTree::ROOT];
    while let Some(id) = stack.pop() {
        let Some(node) = tree.get(id) else { continue };
        if node.mv.is_some() && node.side_to_move() == trainer.color {
            result.push(id);
            continue;
        }
        stack.extend(
            trainer
                .next_after(id)
                .into_iter()
                .filter(|n| trainer.trainable.contains(n)),
        );
    }
    result
}
