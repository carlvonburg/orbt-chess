//! What the Statistics tab counts: one repertoire's cards and reviews, or every repertoire's
//! (Anki's whole collection), read from open repertoires or from sidecars alone.

use std::collections::{HashMap, HashSet};

use crate::chess::Epd;
use crate::document::Repertoire;
use crate::formats::Sidecar;
use crate::repertoire::RepertoireTree;
use crate::training::anki::{Card, CardQueue, RevlogEntry, SchedTiming};

use super::GraphsContext;

/// The part of the statistics one repertoire contributes.
#[derive(Clone, Debug, Default)]
pub struct GraphParts {
    pub cards: Vec<Card>,
    pub new_count: i64,
    pub suspended_new_count: i64,
    pub revlog: Vec<RevlogEntry>,
}

impl GraphParts {
    /// An open repertoire as part of the whole collection: every stored card and the whole
    /// review log.
    pub fn collection(doc: &mut Repertoire, revlog: Vec<RevlogEntry>) -> GraphParts {
        let progress = doc.learning_progress(RepertoireTree::ROOT);
        let trainer = doc.trainer();
        let cards = doc.sidecar().cards();
        let suspended_new = trainer
            .suspended_card_epds(RepertoireTree::ROOT)
            .iter()
            .filter(|e| !cards.contains_key(*e))
            .count() as i64;
        GraphParts {
            cards: cards.into_values().collect(),
            new_count: progress.cards - (progress.learning + progress.young + progress.mature),
            suspended_new_count: suspended_new,
            revlog,
        }
    }

    /// A repertoire not opened, from its sidecar: counts estimated from the last summary.
    pub fn collection_estimate(sidecar: &Sidecar, revlog: Vec<RevlogEntry>) -> GraphParts {
        let progress = sidecar.estimated_progress();
        let stored_suspended = sidecar
            .study_cards
            .values()
            .filter(|c| c.queue == CardQueue::Suspended)
            .count() as i64;
        GraphParts {
            cards: sidecar.study_cards.values().cloned().collect(),
            new_count: progress.cards - (progress.learning + progress.young + progress.mature),
            suspended_new_count: (progress.suspended - stored_suspended).max(0),
            revlog,
        }
    }

    /// One repertoire on its own: only the cards at its positions (cards left over from
    /// deleted lines are not counted), and their reviews.
    pub fn repertoire(doc: &mut Repertoire, revlog: Vec<RevlogEntry>) -> GraphParts {
        let trainer = doc.trainer();
        let epds = &trainer.card_epd_set;
        let suspended = trainer.suspended_card_epds(RepertoireTree::ROOT);
        let cards = &doc.sidecar().study_cards;
        let studied: Vec<Card> = cards
            .iter()
            .filter(|(e, _)| epds.contains(*e))
            .map(|(_, c)| c.clone())
            .collect();
        let studied_suspended: Vec<Card> = cards
            .iter()
            .filter(|(e, _)| suspended.contains(*e))
            .map(|(_, c)| c.clone())
            .collect();
        GraphParts {
            new_count: epds.len() as i64 - studied.len() as i64,
            suspended_new_count: suspended.len() as i64 - studied_suspended.len() as i64,
            cards: studied.into_iter().chain(studied_suspended).collect(),
            revlog: revlog
                .into_iter()
                .filter(|e| epds.contains(&e.cid) || suspended.contains(&e.cid))
                .collect(),
        }
    }
}

impl GraphsContext {
    pub fn from_parts(
        parts: Vec<GraphParts>,
        timing: SchedTiming,
        local_offset_secs: i64,
    ) -> GraphsContext {
        let mut all = GraphParts::default();
        for p in parts {
            all.cards.extend(p.cards);
            all.new_count += p.new_count;
            all.suspended_new_count += p.suspended_new_count;
            all.revlog.extend(p.revlog);
        }
        GraphsContext::new(
            all.cards,
            all.new_count,
            all.suspended_new_count,
            all.revlog,
            timing,
            local_offset_secs,
        )
    }
}

/// The reach of each card position (the highest where a position occurs more than once),
/// for expected recall.
pub fn card_reach(doc: &mut Repertoire) -> HashMap<Epd, f64> {
    let trainer = doc.trainer();
    let reach = doc.reach();
    let mut result: HashMap<Epd, f64> = HashMap::new();
    for id in trainer.card_nodes(RepertoireTree::ROOT) {
        let (Some(node), Some(&r)) = (doc.tree().get(id), reach.get(&id)) else {
            continue;
        };
        let entry = result.entry(node.epd.clone()).or_insert(0.0);
        *entry = entry.max(r);
    }
    result
}

/// The cards stored for a repertoire's positions only.
pub fn repertoire_cards(doc: &mut Repertoire) -> HashMap<Epd, Card> {
    let epds: HashSet<Epd> = doc.trainer().card_epd_set.clone();
    doc.sidecar()
        .study_cards
        .iter()
        .filter(|(e, _)| epds.contains(*e))
        .map(|(e, c)| (e.clone(), c.clone()))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::chess::{ChessPosition, Side};
    use crate::document::StudyDefaults;
    use crate::explorer::ExplorerStats;
    use crate::formats::Timestamp;

    fn doc() -> Repertoire {
        let mut sidecar = Sidecar::new("ID".into(), Side::White, Timestamp(0));
        // A card at the start (your move) and one left over from a deleted line.
        sidecar
            .study_cards
            .insert(ChessPosition::start().epd(), Card::new(1, 0, 0));
        sidecar
            .study_cards
            .insert(Epd::new("8/8/8/8/8/8/8/K6k w - -"), Card::new(2, 1, 0));
        Repertoire::open(
            "1. e4 e5 2. Nf3 Nc6 *",
            &sidecar.encoded(),
            StudyDefaults::default(),
            &HashMap::<Epd, ExplorerStats>::new(),
        )
        .unwrap()
        .0
    }

    #[test]
    fn repertoire_scope_counts_only_its_positions() {
        let mut d = doc();
        let parts = GraphParts::repertoire(&mut d, Vec::new());
        assert_eq!(parts.cards.len(), 1);
        // Your moves 1. e4 and 2. Nf3: one studied, one new.
        assert_eq!(parts.new_count, 1);
        assert_eq!(repertoire_cards(&mut d).len(), 1);
    }

    #[test]
    fn collection_scope_counts_every_stored_card() {
        let mut d = doc();
        let parts = GraphParts::collection(&mut d, Vec::new());
        assert_eq!(parts.cards.len(), 2);
        // From the learning progress: the stored card was never answered, so it is new too.
        assert_eq!(parts.new_count, 2);
        let ctx = GraphsContext::from_parts(
            vec![parts.clone(), parts],
            SchedTiming::new(100, 1_000_000, 900_000),
            0,
        );
        assert_eq!(ctx.cards.len(), 4);
        assert_eq!(ctx.new_count, 4);
    }
}
