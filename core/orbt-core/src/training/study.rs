//! Study sessions over Anki's queue. Chess additions to Anki, kept minimal:
//! - lines start at move 1 (or take back to where they part from the last line, when
//!   shorter), and the practice mode decides who plays your earlier moves; when not taken
//!   back, a line whose moves were already shown this session starts five half-moves before
//!   the first move you play;
//! - one line answers every queued card on it;
//! - moves you play that aren't due are reviews ahead (filtered deck);
//! - new cards are introduced a line at a time, each to its end with the most reached reply
//!   at every opponent move: the most likely line anywhere next, or depth first (the new move
//!   order); a started line is finished past the daily limit;
//! - reviews due the same day are ordered by reach.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::Arc;

use serde::{Deserialize, Serialize};

use super::anki::{Card, CardQueue, CardQueues, RemainingLimits, SchedTiming};
use super::trainer::{Trainer, first_max_by, first_min_by};
use crate::chess::Epd;
use crate::repertoire::{NodeId, RepertoireTree};

/// Who plays your moves on the way to the move being asked (Chessbook's practice options).
/// Every line starts from the initial position and shows every move; the next line takes moves
/// back to where it parts from the last one when that is shorter than replaying from move 1,
/// else skips the moves already shown this session, up to five half-moves before the first move
/// you play.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PracticeMode {
    /// The app plays all moves up to the ones being asked.
    #[default]
    IndividualMoves,
    /// You play all your moves, every line.
    CompleteLinesEveryTime,
    /// You play all your moves the first time they come up in a session; then the app does.
    CompleteLinesOncePerSession,
}

impl PracticeMode {
    pub const ALL: [PracticeMode; 3] = [
        PracticeMode::IndividualMoves,
        PracticeMode::CompleteLinesEveryTime,
        PracticeMode::CompleteLinesOncePerSession,
    ];

    pub fn title(self) -> &'static str {
        match self {
            PracticeMode::IndividualMoves => "Individual moves",
            PracticeMode::CompleteLinesEveryTime => "Complete lines (every time)",
            PracticeMode::CompleteLinesOncePerSession => "Complete lines (once per session)",
        }
    }
}

/// Which line of new moves comes next (like Anki's new card gather order). Either way a line
/// is learned to its end, the most reached reply at each opponent move.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum NewMoveOrder {
    /// The line starting with the most reached opponent reply not learned yet, anywhere.
    #[default]
    MostLikelyFirst,
    /// Depth first: every line below a branch before the next branch.
    OneOpeningAtATime,
}

impl NewMoveOrder {
    pub const ALL: [NewMoveOrder; 2] = [
        NewMoveOrder::MostLikelyFirst,
        NewMoveOrder::OneOpeningAtATime,
    ];

    pub fn title(self) -> &'static str {
        match self {
            NewMoveOrder::MostLikelyFirst => "Most likely first",
            NewMoveOrder::OneOpeningAtATime => "One opening at a time",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AnswerKind {
    /// In today's queue: answered normally.
    Queued,
    /// A New card: shown first, then answered.
    Introduce,
    /// Not due: answered early, like a card in an Anki filtered deck.
    ReviewAhead,
}

/// How one of your moves on a study line is handled.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MoveRole {
    /// Played for you.
    Auto,
    /// You play it; nothing is recorded (it was answered earlier this session).
    Practice,
    /// You play it and it is answered as an Anki card.
    Answer(AnswerKind),
}

impl MoveRole {
    pub fn is_asked(self) -> bool {
        matches!(self, MoveRole::Answer(_))
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StudyLine {
    pub nodes: Vec<NodeId>,
    /// The role of your move from `nodes[i]`, for each index where it's your turn.
    pub roles: BTreeMap<usize, MoveRole>,
    /// The queued card the line was built for.
    pub target: Epd,
}

impl StudyLine {
    /// Half-moves still played before your move when a line skips what was already shown.
    pub const SKIP_LEAD: usize = 5;

    /// Where to start this line when the board shows `previous[shown]`: the index to take
    /// moves back to, when that is fewer moves than replaying from move 1 to the same point.
    /// None starts from move 1. The point is where the lines part, or earlier if one of your
    /// moves before it is asked or practiced (you play it, so it must be replayed).
    pub fn resume_index(&self, previous: &[NodeId], shown: usize) -> Option<usize> {
        if shown >= previous.len() {
            return None;
        }
        let shared = self
            .nodes
            .iter()
            .zip(&previous[..=shown])
            .take_while(|(a, b)| a == b)
            .count();
        if shared == 0 {
            return None;
        }
        let mut start = shared - 1;
        if let Some(played) = self.first_played() {
            start = start.min(played);
        }
        (shown - start < start).then_some(start)
    }

    /// Index of the first move you play on the line (asked or practiced).
    pub fn first_played(&self) -> Option<usize> {
        self.roles
            .iter()
            .find(|(_, r)| **r != MoveRole::Auto)
            .map(|(&i, _)| i)
    }

    /// Where to start this line when it isn't taken back to: `SKIP_LEAD` half-moves before
    /// the first move you play when the board already showed that position this session (and so every
    /// move to it), else move 1.
    pub fn skip_index(&self, shown: &HashSet<NodeId>) -> usize {
        let Some(start) = self
            .first_played()
            .and_then(|i| i.checked_sub(Self::SKIP_LEAD))
        else {
            return 0;
        };
        match self.nodes.get(start) {
            Some(node) if start > 0 && shown.contains(node) => start,
            _ => 0,
        }
    }
}

/// A study session over Anki's queue: picks the next card, builds a line to it, and keeps
/// track of what was answered and played in this session.
#[derive(Clone, Debug)]
pub struct StudySession {
    pub trainer: Arc<Trainer>,
    pub mode: PracticeMode,
    /// A branch session (Anki filtered deck with rescheduling): no daily limits, cards
    /// answered with their real due date.
    pub is_filtered: bool,
    pub root: NodeId,
    pub queue: CardQueues,
    /// Cards answered this session.
    pub answered: HashSet<Epd>,
    /// Cards the user played correctly this session.
    pub played: HashSet<Epd>,
    new_index: HashMap<Epd, usize>,
    reach: HashMap<NodeId, f64>,
}

fn index_of(order: &[Epd]) -> HashMap<Epd, usize> {
    let mut index = HashMap::new();
    for (i, epd) in order.iter().enumerate() {
        index.entry(epd.clone()).or_insert(i);
    }
    index
}

fn daily_queue(
    trainer: &Trainer,
    cards: &HashMap<Epd, Card>,
    order: &[Epd],
    limits: RemainingLimits,
    timing: &SchedTiming,
    learn_ahead_secs: i64,
    reach: &HashMap<NodeId, f64>,
) -> CardQueues {
    let epd_reach = trainer.reach_by_epd(reach);
    let active: HashMap<Epd, Card> = cards
        .iter()
        .filter(|(e, _)| trainer.card_epd_set.contains(*e))
        .map(|(e, c)| (e.clone(), c.clone()))
        .collect();
    CardQueues::new(&active, order, limits, timing, learn_ahead_secs, &|e| {
        epd_reach.get(e).copied().unwrap_or(0.0)
    })
}

impl StudySession {
    /// A daily session over the whole repertoire.
    #[allow(clippy::too_many_arguments)]
    pub fn daily(
        trainer: Arc<Trainer>,
        mode: PracticeMode,
        new_move_order: NewMoveOrder,
        cards: &HashMap<Epd, Card>,
        limits: RemainingLimits,
        timing: &SchedTiming,
        learn_ahead_secs: i64,
        reach: HashMap<NodeId, f64>,
    ) -> StudySession {
        let order = trainer.new_card_order(RepertoireTree::ROOT, &reach, new_move_order);
        let queue = daily_queue(
            &trainer,
            cards,
            &order,
            limits,
            timing,
            learn_ahead_secs,
            &reach,
        );
        StudySession {
            new_index: index_of(&order),
            trainer,
            mode,
            is_filtered: false,
            root: RepertoireTree::ROOT,
            queue,
            answered: HashSet::new(),
            played: HashSet::new(),
            reach,
        }
    }

    /// A branch session: every card under `root`, in random order, without limits.
    #[allow(clippy::too_many_arguments)]
    pub fn branch(
        trainer: Arc<Trainer>,
        mode: PracticeMode,
        new_move_order: NewMoveOrder,
        root: NodeId,
        cards: &HashMap<Epd, Card>,
        timing: &SchedTiming,
        learn_ahead_secs: i64,
        reach: HashMap<NodeId, f64>,
    ) -> StudySession {
        let order = trainer.new_card_order(root, &reach, new_move_order);
        let queue = CardQueues::filtered(&order, cards, timing, learn_ahead_secs);
        StudySession {
            new_index: index_of(&order),
            trainer,
            mode,
            is_filtered: true,
            root,
            queue,
            answered: HashSet::new(),
            played: HashSet::new(),
            reach,
        }
    }

    fn reach_of(&self, id: NodeId) -> f64 {
        self.reach.get(&id).copied().unwrap_or(0.0)
    }

    // Lines

    /// The line for the next card in the queue, or None when the session is done.
    pub fn next_line(&mut self, cards: &HashMap<Epd, Card>) -> Option<StudyLine> {
        while let Some((epd, _)) = self.queue.next() {
            let epd = epd.clone();
            if let Some(line) = self.line_to(&epd, cards) {
                return Some(line);
            }
            // the position is no longer in the repertoire
            self.queue.remove(&epd);
        }
        None
    }

    pub(crate) fn line_to(&self, target: &Epd, cards: &HashMap<Epd, Card>) -> Option<StudyLine> {
        let trainer = &self.trainer;
        let tree = &trainer.tree;
        let candidates = tree.nodes_at(target).iter().copied().filter(|&id| {
            trainer.trainable.contains(&id)
                && tree
                    .get(id)
                    .is_some_and(|n| n.side_to_move() == trainer.color)
                && (id == self.root || tree.is_ancestor(self.root, id))
        });
        // prefer a path whose earlier moves have all been introduced, then the likeliest
        let is_new = |epd: &Epd| !cards.contains_key(epd);
        let start = first_min_by(candidates, |&a, &b| {
            let (na, nb) = (
                self.new_moves_before(a, &is_new),
                self.new_moves_before(b, &is_new),
            );
            if na != nb {
                na < nb
            } else {
                self.reach_of(a) > self.reach_of(b)
            }
        })?;

        let mut nodes = tree.path(start);
        let mut visited: HashSet<NodeId> = nodes.iter().copied().collect();
        let new_line = is_new(target);
        let mut queued_below: HashMap<NodeId, usize> = HashMap::new();
        let mut first_new_below: HashMap<NodeId, usize> = HashMap::new();
        let mut cursor = start;
        loop {
            let options: Vec<NodeId> = trainer
                .next_after(cursor)
                .into_iter()
                .filter(|n| trainer.trainable.contains(n) && !visited.contains(n))
                .collect();
            if options.is_empty() {
                break;
            }
            let next = if tree
                .get(cursor)
                .is_some_and(|n| n.side_to_move() == trainer.color)
                || options.len() == 1
            {
                options[0]
            } else if new_line {
                // follow the new-card order: the continuation with the next new card
                for &o in &options {
                    self.first_new(o, &is_new, &mut first_new_below);
                }
                first_min_by(options.iter().copied(), |&a, &b| {
                    let (fa, fb) = (first_new_below[&a], first_new_below[&b]);
                    if fa != fb {
                        fa < fb
                    } else {
                        self.reach_of(a) > self.reach_of(b)
                    }
                })
                .expect("options not empty")
            } else {
                // the continuation with the most cards waiting
                for &o in &options {
                    self.queued(o, &mut queued_below);
                }
                first_max_by(options.iter().copied(), |&a, &b| {
                    let (qa, qb) = (queued_below[&a], queued_below[&b]);
                    if qa != qb {
                        qa < qb
                    } else {
                        self.reach_of(a) < self.reach_of(b)
                    }
                })
                .expect("options not empty")
            };
            nodes.push(next);
            visited.insert(next);
            cursor = next;
        }

        let mut roles: BTreeMap<usize, MoveRole> = BTreeMap::new();
        let root_index = nodes.iter().position(|&n| n == self.root).unwrap_or(0);
        for (i, &id) in nodes.iter().enumerate().take(nodes.len().saturating_sub(1)) {
            let Some(node) = tree.get(id) else {
                continue;
            };
            if node.side_to_move() != trainer.color {
                continue;
            }
            let role = if i < root_index {
                MoveRole::Auto
            } else {
                self.role(&node.epd, cards)
            };
            roles.insert(i, role);
        }
        // end after the last move that is answered (a queued or new card)
        let last = roles
            .iter()
            .filter(|(_, r)| {
                matches!(
                    r,
                    MoveRole::Answer(AnswerKind::Queued) | MoveRole::Answer(AnswerKind::Introduce)
                )
            })
            .map(|(&i, _)| i)
            .max()?;
        nodes.truncate(last + 2);
        roles.retain(|&i, _| i <= last);
        Some(StudyLine {
            nodes,
            roles,
            target: target.clone(),
        })
    }

    pub(crate) fn role(&self, epd: &Epd, cards: &HashMap<Epd, Card>) -> MoveRole {
        let card = cards.get(epd);
        if card.is_some_and(|c| c.queue == CardQueue::Suspended) {
            return MoveRole::Auto;
        }
        if self.queue.contains(epd) {
            return MoveRole::Answer(if card.is_none() {
                AnswerKind::Introduce
            } else {
                AnswerKind::Queued
            });
        }
        if card.is_none() {
            return if self.is_filtered {
                MoveRole::Auto
            } else {
                MoveRole::Answer(AnswerKind::Introduce)
            };
        }
        let practice_or_ahead = || {
            if self.answered.contains(epd) || self.is_filtered {
                MoveRole::Practice
            } else {
                MoveRole::Answer(AnswerKind::ReviewAhead)
            }
        };
        match self.mode {
            PracticeMode::IndividualMoves => MoveRole::Auto,
            PracticeMode::CompleteLinesEveryTime => practice_or_ahead(),
            PracticeMode::CompleteLinesOncePerSession => {
                if self.played.contains(epd) {
                    MoveRole::Auto
                } else {
                    practice_or_ahead()
                }
            }
        }
    }

    fn new_moves_before(&self, id: NodeId, is_new: &dyn Fn(&Epd) -> bool) -> usize {
        let tree = &self.trainer.tree;
        let path = tree.path(id);
        path[..path.len().saturating_sub(1)]
            .iter()
            .filter(|&&n| {
                tree.get(n).is_some_and(|node| {
                    node.side_to_move() == self.trainer.color
                        && !node.children.is_empty()
                        && is_new(&node.epd)
                })
            })
            .count()
    }

    fn queued(&self, id: NodeId, memo: &mut HashMap<NodeId, usize>) -> usize {
        if let Some(&v) = memo.get(&id) {
            return v;
        }
        let tree = &self.trainer.tree;
        let v = self
            .trainer
            .reachable(id)
            .into_iter()
            .filter(|&n| {
                tree.get(n).is_some_and(|node| {
                    node.side_to_move() == self.trainer.color && self.queue.contains(&node.epd)
                })
            })
            .count();
        memo.insert(id, v);
        v
    }

    fn first_new(
        &self,
        id: NodeId,
        is_new: &dyn Fn(&Epd) -> bool,
        memo: &mut HashMap<NodeId, usize>,
    ) -> usize {
        if let Some(&v) = memo.get(&id) {
            return v;
        }
        let tree = &self.trainer.tree;
        let v = self
            .trainer
            .reachable(id)
            .into_iter()
            .filter_map(|n| {
                let epd = &tree.get(n)?.epd;
                if is_new(epd) {
                    self.new_index.get(epd).copied()
                } else {
                    None
                }
            })
            .min()
            .unwrap_or(usize::MAX);
        memo.insert(id, v);
        v
    }

    /// A new card's position in the new-card order.
    pub fn position(&self, epd: &Epd) -> i64 {
        self.new_index
            .get(epd)
            .copied()
            .unwrap_or(self.new_index.len()) as i64
    }

    // Recording

    /// After a card was answered: removes it from the queue and requeues it if it's
    /// still learning today.
    pub fn did_answer(&mut self, epd: &Epd, card: &Card, timing: &SchedTiming) {
        self.queue.remove(epd);
        self.queue.answered(card, epd, timing);
        self.answered.insert(epd.clone());
    }

    pub fn did_play(&mut self, epd: &Epd) {
        self.played.insert(epd.clone());
    }

    pub fn update_learning_cutoff(&mut self, now: i64) {
        self.queue.update_learning_cutoff(now);
    }

    /// Custom study "increase today's new limit": rebuilds the queue with the new limits.
    pub fn rebuild(
        &mut self,
        cards: &HashMap<Epd, Card>,
        limits: RemainingLimits,
        timing: &SchedTiming,
        learn_ahead_secs: i64,
    ) {
        if self.is_filtered {
            return;
        }
        let mut order: Vec<(&Epd, usize)> = self.new_index.iter().map(|(e, &i)| (e, i)).collect();
        order.sort_by_key(|&(_, i)| i);
        let order: Vec<Epd> = order.into_iter().map(|(e, _)| e.clone()).collect();
        self.queue = daily_queue(
            &self.trainer,
            cards,
            &order,
            limits,
            timing,
            learn_ahead_secs,
            &self.reach,
        );
    }
}
