//! Plays study lines one after another (DrillView's model). Each card on a line is answered
//! like an Anki card: a wrong move, a hint or browsing is Again; a correct move is Good.
//!
//! The platform runs the timing: while `phase` is `Rewinding` or `Autoplay` it calls `step`
//! every 250 ms or 450 ms; on `LineDone` it waits 400 ms and calls `next_line`; 1.2 s after a
//! wrong move it calls `wrong_timeout`.

use std::collections::HashSet;
use std::sync::Arc;

use crate::builder::{Arrow, ArrowStyle};
use crate::chess::{BoardSquare, ChessPosition, Epd, PieceKind, PlayedMove};
use crate::document::{Changes, Repertoire};
use crate::repertoire::NodeId;
use crate::training::anki::{Counts, QueueKind, Rating, SchedTiming};
use crate::training::{AnswerKind, LineOutcome, LineRun, MoveRole, StudyLine, StudySession};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DrillMode {
    /// Today's cards (Anki's "Study Now").
    Study,
    /// Every card under a position (Anki's custom study, a filtered deck).
    Branch(NodeId),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Feedback {
    None,
    Correct,
    Wrong {
        expected: PlayedMove,
    },
    Alternative,
    /// A new card: its move is shown before you play it.
    NewMove(PlayedMove),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    /// Not started.
    Idle,
    /// Taking moves back to where the next line parts from the last one.
    Rewinding,
    /// Playing the opponent's moves and yours that are played for you.
    Autoplay,
    /// Your move.
    UserTurn,
    /// The line is done: the next one follows.
    LineDone,
    /// No more cards for now.
    Finished,
}

#[derive(Debug)]
pub struct Drill {
    pub mode: DrillMode,
    session: Option<StudySession>,
    line: Option<StudyLine>,
    run: Option<LineRun>,
    /// The line to start after rewinding, and where.
    pending: Option<(StudyLine, usize)>,
    pub feedback: Feedback,
    pub phase: Phase,
    pub show_hint: bool,
    /// Cards answered in this session.
    pub answered_count: i64,
    /// Of those, answered Good.
    pub correct_count: i64,
    /// Time spent answering: the sum of each answer's time, as in the review log.
    pub studied_millis: i64,
    /// Cards already answered on the current line (a wrong try answers once).
    answered_on_line: HashSet<Epd>,
    turn_started_ms: i64,
}

impl Drill {
    pub fn new(mode: DrillMode) -> Drill {
        Drill {
            mode,
            session: None,
            line: None,
            run: None,
            pending: None,
            feedback: Feedback::None,
            phase: Phase::Idle,
            show_hint: false,
            answered_count: 0,
            correct_count: 0,
            studied_millis: 0,
            answered_on_line: HashSet::new(),
            turn_started_ms: 0,
        }
    }

    pub fn is_filtered(&self) -> bool {
        matches!(self.mode, DrillMode::Branch(_))
    }

    /// Starts the session; `learn_more` new cards are added to today's limit first.
    pub fn start(
        &mut self,
        doc: &mut Repertoire,
        learn_more: i64,
        timing: &SchedTiming,
    ) -> Changes {
        let mut changes = Changes::default();
        if self.session.is_some() {
            return changes;
        }
        if learn_more > 0 {
            changes = doc.extend_limits_today(learn_more, 0, timing);
        }
        let branch = match self.mode {
            DrillMode::Branch(id) => Some(id),
            DrillMode::Study => None,
        };
        self.session = Some(doc.study_session(branch, timing));
        self.next_line(doc, timing);
        changes
    }

    // Reading

    pub fn counts(&self) -> Counts {
        self.session
            .as_ref()
            .map(|s| s.queue.counts)
            .unwrap_or_default()
    }

    /// Unix seconds of the next learning card later today.
    pub fn next_learning_due(&self) -> Option<i64> {
        self.session.as_ref()?.queue.next_learning_due()
    }

    pub fn run(&self) -> Option<&LineRun> {
        self.run.as_ref()
    }

    pub fn line(&self) -> Option<&StudyLine> {
        self.line.as_ref()
    }

    pub fn position(&self, doc: &Repertoire) -> ChessPosition {
        self.run
            .as_ref()
            .and_then(|r| doc.tree().get(r.current_node()))
            .map(|n| n.position.clone())
            .unwrap_or_default()
    }

    pub fn last_move(&self, doc: &Repertoire) -> Option<PlayedMove> {
        let run = self.run.as_ref()?;
        doc.tree().get(run.current_node())?.mv.clone()
    }

    /// The nodes of the moves on the board, from the start of the line.
    pub fn played_nodes(&self) -> Vec<NodeId> {
        self.run
            .as_ref()
            .map(|r| r.nodes[1..=r.index].to_vec())
            .unwrap_or_default()
    }

    fn current_role(&self) -> Option<MoveRole> {
        let run = self.run.as_ref()?;
        if !run.is_own_turn() {
            return None;
        }
        self.line.as_ref()?.roles.get(&run.index).copied()
    }

    fn current_epd(&self, doc: &Repertoire) -> Option<Epd> {
        let run = self.run.as_ref()?;
        Some(doc.tree().get(run.current_node())?.epd.clone())
    }

    pub fn is_user_turn(&self) -> bool {
        self.phase == Phase::UserTurn && self.current_role().is_some_and(|r| r != MoveRole::Auto)
    }

    /// The kind of card being asked, for highlighting its count.
    pub fn asked_kind(&self, doc: &Repertoire) -> Option<QueueKind> {
        if !self.is_user_turn() {
            return None;
        }
        let epd = self.current_epd(doc)?;
        self.session.as_ref()?.queue.kind_of(&epd)
    }

    pub fn arrows(&self) -> Vec<Arrow> {
        match &self.feedback {
            Feedback::Wrong { expected } | Feedback::NewMove(expected) => {
                Arrow::for_move(expected, ArrowStyle::Hint, 0.2, 1.0)
                    .into_iter()
                    .collect()
            }
            _ => match self.run.as_ref().and_then(|r| r.expected()) {
                Some(expected) if self.show_hint => {
                    Arrow::for_move(expected, ArrowStyle::Hint, 0.2, 0.6)
                        .into_iter()
                        .collect()
                }
                _ => Vec::new(),
            },
        }
    }

    // Playing

    /// One step of the rewind or autoplay; the platform calls it on its timer.
    pub fn step(&mut self, now_ms: i64) {
        match self.phase {
            Phase::Rewinding => {
                let Some((line, start)) = self.pending.clone() else {
                    self.phase = Phase::Autoplay;
                    return;
                };
                match &mut self.run {
                    Some(run) if run.index > start => run.take_back(),
                    _ => {
                        let Some(session) = &self.session else {
                            self.pending = None;
                            self.phase = Phase::Idle;
                            return;
                        };
                        let trainer = Arc::clone(&session.trainer);
                        self.run = Some(LineRun::new(trainer, line.nodes.clone(), start));
                        self.pending = None;
                        self.phase = Phase::Autoplay;
                    }
                }
            }
            Phase::Autoplay => {
                let auto = self.current_role() == Some(MoveRole::Auto);
                let Some(run) = &mut self.run else {
                    self.phase = Phase::LineDone;
                    return;
                };
                if run.is_finished() {
                    self.phase = Phase::LineDone;
                } else if !run.is_own_turn() || auto {
                    run.advance();
                    let finished = run.is_finished();
                    let user_turn =
                        run.is_own_turn() && self.current_role() != Some(MoveRole::Auto);
                    if finished {
                        self.phase = Phase::LineDone;
                    } else if user_turn {
                        self.prepare_user_turn(now_ms);
                    }
                } else {
                    self.prepare_user_turn(now_ms);
                }
            }
            _ => {}
        }
    }

    /// A New card is shown first (its answer), then the user plays it.
    fn prepare_user_turn(&mut self, now_ms: i64) {
        self.phase = Phase::UserTurn;
        self.turn_started_ms = now_ms;
        self.show_hint = false;
        if self.current_role() == Some(MoveRole::Answer(AnswerKind::Introduce))
            && let Some(expected) = self.run.as_ref().and_then(|r| r.expected())
        {
            self.feedback = Feedback::NewMove(expected.clone());
        } else if self.feedback != Feedback::Correct {
            self.feedback = Feedback::None;
        }
    }

    /// The user's move on the board.
    #[allow(clippy::too_many_arguments)]
    pub fn user_moved(
        &mut self,
        doc: &mut Repertoire,
        from: BoardSquare,
        to: BoardSquare,
        promotion: Option<PieceKind>,
        timing: &SchedTiming,
        now_ms: i64,
    ) -> Changes {
        let mut changes = Changes::default();
        if !self.is_user_turn() {
            return changes;
        }
        let (Some(epd), Some(role)) = (self.current_epd(doc), self.current_role()) else {
            return changes;
        };
        let Some((mv, _)) = self.position(doc).play(from, to, promotion) else {
            return changes;
        };
        let outcome = match &mut self.run {
            Some(run) => run.user_played(&mv.uci),
            None => return changes,
        };
        match outcome {
            LineOutcome::Correct => {
                if let MoveRole::Answer(kind) = role
                    && !self.answered_on_line.contains(&epd)
                {
                    changes = self.answer(doc, &epd, kind, Rating::Good, timing, now_ms);
                }
                if let Some(session) = &mut self.session {
                    session.did_play(&epd);
                }
                self.show_hint = false;
                self.feedback = Feedback::Correct;
                self.phase = Phase::Autoplay;
            }
            LineOutcome::Alternative => self.feedback = Feedback::Alternative,
            LineOutcome::Wrong { expected } => {
                if let MoveRole::Answer(kind) = role
                    && !self.answered_on_line.contains(&epd)
                {
                    changes = self.answer(doc, &epd, kind, Rating::Again, timing, now_ms);
                }
                self.feedback = Feedback::Wrong { expected };
            }
        }
        changes
    }

    /// 1.2 s after a wrong move: Anki shows the answer, so the arrow stays until it is played.
    pub fn wrong_timeout(&mut self) {
        if matches!(self.feedback, Feedback::Wrong { .. }) {
            self.feedback = Feedback::None;
            self.show_hint = true;
        }
    }

    /// The node to open when the user browses the repertoire mid-line. Browsing on your own
    /// turn reveals the answer, so it counts as Again.
    pub fn browse_node(
        &mut self,
        doc: &mut Repertoire,
        timing: &SchedTiming,
        now_ms: i64,
    ) -> (Option<NodeId>, Changes) {
        let node = self.run.as_ref().map(|r| r.current_node());
        let changes = self.fail_current_card(doc, timing, now_ms);
        (node, changes)
    }

    pub fn hint(&mut self, doc: &mut Repertoire, timing: &SchedTiming, now_ms: i64) -> Changes {
        let changes = self.fail_current_card(doc, timing, now_ms);
        self.show_hint = true;
        changes
    }

    /// The moves to the board, for Lichess analysis. Looking counts as Again, like browsing.
    pub fn analysis_moves(
        &mut self,
        doc: &mut Repertoire,
        timing: &SchedTiming,
        now_ms: i64,
    ) -> (Vec<PlayedMove>, Changes) {
        let changes = self.fail_current_card(doc, timing, now_ms);
        let moves = self
            .run
            .as_ref()
            .map(|r| doc.tree().moves(r.current_node()))
            .unwrap_or_default();
        (moves, changes)
    }

    /// Anki's custom study "Increase today's new/review card limit".
    pub fn extend_limits(
        &mut self,
        doc: &mut Repertoire,
        new: i64,
        review: i64,
        timing: &SchedTiming,
    ) -> Changes {
        let changes = doc.extend_limits_today(new, review, timing);
        let limits = doc.remaining_limits(timing);
        let learn_ahead = doc.deck_config().learn_ahead_secs;
        let cards = doc.sidecar().cards();
        if let Some(session) = &mut self.session {
            session.rebuild(&cards, limits, timing, learn_ahead);
        }
        self.next_line(doc, timing);
        changes
    }

    /// Looks for cards again (learning cards that became due).
    pub fn check_again(&mut self, doc: &Repertoire, timing: &SchedTiming) {
        self.next_line(doc, timing);
    }

    fn fail_current_card(
        &mut self,
        doc: &mut Repertoire,
        timing: &SchedTiming,
        now_ms: i64,
    ) -> Changes {
        if !self.is_user_turn() {
            return Changes::default();
        }
        let (Some(epd), Some(MoveRole::Answer(kind))) =
            (self.current_epd(doc), self.current_role())
        else {
            return Changes::default();
        };
        if self.answered_on_line.contains(&epd) {
            return Changes::default();
        }
        self.answer(doc, &epd, kind, Rating::Again, timing, now_ms)
    }

    fn answer(
        &mut self,
        doc: &mut Repertoire,
        epd: &Epd,
        kind: AnswerKind,
        rating: Rating,
        timing: &SchedTiming,
        now_ms: i64,
    ) -> Changes {
        let filtered = self.is_filtered() || kind == AnswerKind::ReviewAhead;
        let Some(session) = &mut self.session else {
            return Changes::default();
        };
        let taken = (now_ms - self.turn_started_ms).max(0);
        let (card, changes) =
            doc.answer(epd, session.position(epd), rating, filtered, taken, timing);
        session.did_answer(epd, &card, timing);
        self.answered_on_line.insert(epd.clone());
        self.answered_count += 1;
        if rating == Rating::Good {
            self.correct_count += 1;
        }
        self.studied_millis += taken;
        changes
    }

    /// The next line, or Finished. Takes moves back to where the lines part when that is
    /// shorter than replaying from move 1.
    pub fn next_line(&mut self, doc: &Repertoire, timing: &SchedTiming) {
        let cards = doc.sidecar().cards();
        let Some(session) = &mut self.session else {
            return;
        };
        session.update_learning_cutoff(timing.now);
        let trainer = Arc::clone(&session.trainer);
        let Some(next) = session.next_line(&cards) else {
            self.line = None;
            self.run = None;
            self.pending = None;
            self.phase = Phase::Finished;
            self.feedback = Feedback::None;
            return;
        };
        let previous = self.run.take();
        self.line = Some(next.clone());
        self.answered_on_line.clear();
        self.feedback = Feedback::None;
        self.show_hint = false;
        match previous
            .as_ref()
            .and_then(|p| next.resume_index(&p.nodes, p.index).map(|start| (p, start)))
        {
            Some((previous, start)) => {
                self.run = Some(previous.clone());
                self.pending = Some((next, start));
                self.phase = Phase::Rewinding;
            }
            None => {
                self.run = Some(LineRun::new(trainer, next.nodes, 0));
                self.phase = Phase::Autoplay;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use super::*;
    use crate::chess::Side;
    use crate::document::StudyDefaults;
    use crate::explorer::ExplorerStats;
    use crate::formats::{Sidecar, Timestamp};
    use crate::repertoire::RepertoireTree;

    fn doc() -> Repertoire {
        let sidecar = Sidecar::new("ID".into(), Side::White, Timestamp(0)).encoded();
        Repertoire::open(
            "1. e4 c5 2. Nf3 d6 3. d4 *",
            &sidecar,
            StudyDefaults::default(),
            &HashMap::<Epd, ExplorerStats>::new(),
        )
        .unwrap()
        .0
    }

    fn timing() -> SchedTiming {
        SchedTiming::new(100, 1_000_000 + 16 * 3600, 1_000_000)
    }

    fn sq(s: &str) -> BoardSquare {
        BoardSquare::parse(s).unwrap()
    }

    fn until_user_turn(d: &mut Drill) {
        for _ in 0..50 {
            if d.phase == Phase::UserTurn {
                return;
            }
            d.step(0);
        }
        panic!("no user turn: {:?}", d.phase);
    }

    #[test]
    fn a_rewind_without_a_session_stops_instead_of_panicking() {
        let mut d = Drill::new(DrillMode::Study);
        d.phase = Phase::Rewinding;
        let line = StudyLine {
            nodes: vec![RepertoireTree::ROOT],
            roles: Default::default(),
            target: ChessPosition::start().epd(),
        };
        d.pending = Some((line, 0));
        d.step(0);
        assert_eq!(d.phase, Phase::Idle);
    }

    #[test]
    fn a_new_line_is_shown_then_played_and_answered() {
        let mut doc = doc();
        let mut d = Drill::new(DrillMode::Study);
        d.start(&mut doc, 0, &timing());
        assert_eq!(d.counts().new, 3);
        until_user_turn(&mut d);
        // A new card: its move is shown first.
        assert!(matches!(d.feedback, Feedback::NewMove(ref m) if m.san == "e4"));
        assert!(d.is_user_turn());
        // A wrong move answers Again once.
        d.user_moved(&mut doc, sq("d2"), sq("d4"), None, &timing(), 5_000);
        assert!(matches!(d.feedback, Feedback::Wrong { .. }));
        assert_eq!((d.answered_count, d.correct_count), (1, 0));
        d.wrong_timeout();
        assert!(d.show_hint);
        d.user_moved(&mut doc, sq("e2"), sq("e4"), None, &timing(), 6_000);
        assert_eq!(d.feedback, Feedback::Correct);
        assert_eq!(d.answered_count, 1);
        until_user_turn(&mut d);
        d.user_moved(&mut doc, sq("g1"), sq("f3"), None, &timing(), 7_000);
        assert_eq!((d.answered_count, d.correct_count), (2, 1));
        assert!(doc.sidecar().study_cards.len() == 2);
    }

    #[test]
    fn hints_and_browsing_count_as_again() {
        let mut doc = doc();
        let mut d = Drill::new(DrillMode::Study);
        d.start(&mut doc, 0, &timing());
        until_user_turn(&mut d);
        d.hint(&mut doc, &timing(), 1_000);
        assert!(d.show_hint);
        assert_eq!(d.answered_count, 1);
        // Already answered on this line: browsing does not answer again.
        let (node, _) = d.browse_node(&mut doc, &timing(), 2_000);
        assert_eq!(node, Some(0));
        assert_eq!(d.answered_count, 1);
        assert_eq!(d.arrows().len(), 1);
    }
}
