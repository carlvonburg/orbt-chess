//! The builder and drill sessions over an open repertoire.

use std::sync::{Arc, Mutex};

use orbt_core::builder::{Arrow, Builder};
use orbt_core::chess::{BoardSquare, PieceKind, PlayedMove, Side};
use orbt_core::coverage::{CoverageGap, ReplyInfo};
use orbt_core::document::Changes;
use orbt_core::drill::{Drill, DrillMode, Feedback, Phase};
use orbt_core::repertoire::NodeId;
use orbt_core::training::anki::{Counts, QueueKind, SchedTiming};

use crate::document::RepertoireDoc;
use crate::position::Position;
use crate::types::StudyLineRecord;

/// The builder's navigation over a repertoire.
#[derive(uniffi::Object)]
pub struct BuilderSession {
    doc: Arc<RepertoireDoc>,
    state: Mutex<Builder>,
}

impl BuilderSession {
    fn act(
        &self,
        f: impl FnOnce(
            &mut Builder,
            &mut orbt_core::document::Repertoire,
            &dyn orbt_core::coverage::StatsSource,
        ) -> Changes,
    ) -> Changes {
        let mut b = self.state.lock().expect("builder lock");
        self.doc.edit(|doc, stats| ((), f(&mut b, doc, stats))).1
    }

    fn view<R>(&self, f: impl FnOnce(&Builder, &orbt_core::document::Repertoire) -> R) -> R {
        let b = self.state.lock().expect("builder lock");
        let doc = self.doc.lock();
        f(&b, &doc)
    }
}

#[uniffi::export]
impl BuilderSession {
    /// Opens at `start`, or at the last position looked at.
    #[uniffi::constructor]
    pub fn new(doc: Arc<RepertoireDoc>, start: Option<NodeId>) -> Arc<BuilderSession> {
        let state = Builder::new(&doc.lock(), start);
        Arc::new(BuilderSession {
            doc,
            state: Mutex::new(state),
        })
    }

    pub fn current(&self) -> NodeId {
        self.state.lock().expect("builder lock").current
    }

    pub fn orientation(&self) -> Side {
        self.state.lock().expect("builder lock").orientation
    }

    pub fn set_orientation(&self, side: Side) {
        self.state.lock().expect("builder lock").orientation = side;
    }

    pub fn draft(&self) -> Vec<PlayedMove> {
        self.state.lock().expect("builder lock").draft().to_vec()
    }

    pub fn has_draft(&self) -> bool {
        self.state.lock().expect("builder lock").has_draft()
    }

    /// Position on the board (after the draft).
    pub fn position(&self) -> Arc<Position> {
        self.view(|b, doc| Arc::new(Position(b.position(doc))))
    }

    pub fn continuation(&self) -> Option<NodeId> {
        self.view(|b, doc| b.continuation(doc))
    }

    pub fn draft_transposition(&self) -> Option<NodeId> {
        self.view(|b, doc| b.draft_transposition(doc))
    }

    /// The node whose moves the panels show.
    pub fn shown_node(&self) -> NodeId {
        self.view(|b, doc| b.shown_node(doc))
    }

    pub fn transposition_after(&self, uci: String) -> Option<NodeId> {
        self.view(|b, doc| b.transposition_after(doc, &uci))
    }

    pub fn can_forward(&self) -> bool {
        self.view(|b, doc| b.can_forward(doc))
    }

    pub fn line_ahead(&self, limit: u32) -> Vec<NodeId> {
        self.view(|b, doc| b.line_ahead(doc, limit as usize))
    }

    pub fn last_move(&self) -> Option<PlayedMove> {
        self.view(|b, doc| b.last_move(doc))
    }

    pub fn is_user_turn_on_board(&self) -> bool {
        self.view(|b, doc| b.is_user_turn_on_board(doc))
    }

    pub fn moves_to_board(&self) -> Vec<PlayedMove> {
        self.view(|b, doc| b.moves_to_board(doc))
    }

    pub fn arrows(&self) -> Vec<Arrow> {
        self.view(|b, doc| b.arrows(doc))
    }

    pub fn reach_on_board(&self) -> Option<f64> {
        let b = self.state.lock().expect("builder lock");
        self.doc
            .edit(|doc, stats| (b.reach_on_board(doc, stats), Changes::default()))
            .0
    }

    pub fn draft_replies(&self) -> Option<Vec<ReplyInfo>> {
        let b = self.state.lock().expect("builder lock");
        self.doc
            .edit(|doc, stats| (b.draft_replies(doc, stats), Changes::default()))
            .0
    }

    // Navigation and edits

    pub fn go(&self, id: NodeId) -> Changes {
        self.act(|b, doc, stats| b.go(doc, id, stats))
    }

    pub fn back(&self) -> Changes {
        self.act(|b, doc, _| b.back(doc))
    }

    pub fn forward(&self) -> Changes {
        self.act(|b, doc, stats| b.forward(doc, stats))
    }

    pub fn sibling(&self, offset: i64) -> Changes {
        self.act(|b, doc, stats| b.sibling(doc, offset, stats))
    }

    pub fn play(
        &self,
        from: BoardSquare,
        to: BoardSquare,
        promotion: Option<PieceKind>,
    ) -> Changes {
        self.act(|b, doc, stats| b.play(doc, from, to, promotion, stats))
    }

    pub fn play_uci(&self, uci: String) -> Changes {
        self.act(|b, doc, stats| b.play_uci(doc, &uci, stats))
    }

    pub fn preview(&self, uci: String) -> Changes {
        self.act(|b, doc, stats| b.preview(doc, &uci, stats))
    }

    pub fn save_draft(&self) -> Changes {
        self.act(|b, doc, stats| b.save_draft(doc, stats))
    }

    pub fn discard_draft(&self) {
        self.state.lock().expect("builder lock").discard_draft();
    }

    /// A line from the analysis board: saved moves are followed, the rest is the draft.
    pub fn set_line(&self, moves: Vec<String>) -> Changes {
        self.act(|b, doc, _| b.set_line(doc, &moves))
    }

    pub fn delete(&self, id: NodeId) -> Changes {
        self.act(|b, doc, stats| b.delete(doc, id, stats))
    }

    /// Undoes the last edit, keeping the board on a saved position.
    pub fn undo(&self) -> Changes {
        self.act(|b, doc, stats| b.undo(doc, stats))
    }

    pub fn go_to_biggest_gap(&self) -> Changes {
        self.act(|b, doc, stats| b.go_to_biggest_gap(doc, stats))
    }

    pub fn go_to_gap(&self, gap: CoverageGap) -> Changes {
        self.act(|b, doc, stats| b.go_to_gap(doc, &gap, stats))
    }
}

/// A study session played line by line. See orbt_core::drill for the timing.
#[derive(uniffi::Object)]
pub struct DrillSession {
    doc: Arc<RepertoireDoc>,
    state: Mutex<Drill>,
}

impl DrillSession {
    fn act(
        &self,
        f: impl FnOnce(&mut Drill, &mut orbt_core::document::Repertoire) -> Changes,
    ) -> Changes {
        let mut d = self.state.lock().expect("drill lock");
        self.doc.edit(|doc, _| ((), f(&mut d, doc))).1
    }

    fn view<R>(&self, f: impl FnOnce(&Drill, &orbt_core::document::Repertoire) -> R) -> R {
        let d = self.state.lock().expect("drill lock");
        let doc = self.doc.lock();
        f(&d, &doc)
    }
}

#[derive(uniffi::Record)]
pub struct NodeAndChanges {
    pub node: Option<NodeId>,
    pub changes: Changes,
}

#[derive(uniffi::Record)]
pub struct MovesAndChanges {
    pub moves: Vec<PlayedMove>,
    pub changes: Changes,
}

#[uniffi::export]
impl DrillSession {
    #[uniffi::constructor]
    pub fn new(doc: Arc<RepertoireDoc>, mode: DrillMode) -> Arc<DrillSession> {
        Arc::new(DrillSession {
            doc,
            state: Mutex::new(Drill::new(mode)),
        })
    }

    /// Starts the session; `learn_more` new cards are added to today's limit first.
    pub fn start(&self, learn_more: i64, timing: SchedTiming) -> Changes {
        self.act(|d, doc| d.start(doc, learn_more, &timing))
    }

    pub fn phase(&self) -> Phase {
        self.state.lock().expect("drill lock").phase
    }

    pub fn feedback(&self) -> Feedback {
        self.state.lock().expect("drill lock").feedback.clone()
    }

    pub fn show_hint(&self) -> bool {
        self.state.lock().expect("drill lock").show_hint
    }

    pub fn is_filtered(&self) -> bool {
        self.state.lock().expect("drill lock").is_filtered()
    }

    pub fn answered_count(&self) -> i64 {
        self.state.lock().expect("drill lock").answered_count
    }

    pub fn correct_count(&self) -> i64 {
        self.state.lock().expect("drill lock").correct_count
    }

    pub fn studied_millis(&self) -> i64 {
        self.state.lock().expect("drill lock").studied_millis
    }

    pub fn counts(&self) -> Counts {
        self.state.lock().expect("drill lock").counts()
    }

    pub fn next_learning_due(&self) -> Option<i64> {
        self.state.lock().expect("drill lock").next_learning_due()
    }

    pub fn is_user_turn(&self) -> bool {
        self.state.lock().expect("drill lock").is_user_turn()
    }

    pub fn asked_kind(&self) -> Option<QueueKind> {
        self.view(|d, doc| d.asked_kind(doc))
    }

    pub fn arrows(&self) -> Vec<Arrow> {
        self.state.lock().expect("drill lock").arrows()
    }

    pub fn position(&self) -> Arc<Position> {
        self.view(|d, doc| Arc::new(Position(d.position(doc))))
    }

    pub fn last_move(&self) -> Option<PlayedMove> {
        self.view(|d, doc| d.last_move(doc))
    }

    /// The nodes of the moves on the board, from the start of the line.
    pub fn played_nodes(&self) -> Vec<NodeId> {
        self.state.lock().expect("drill lock").played_nodes()
    }

    pub fn current_node(&self) -> Option<NodeId> {
        self.state
            .lock()
            .expect("drill lock")
            .run()
            .map(|r| r.current_node())
    }

    pub fn line(&self) -> Option<StudyLineRecord> {
        self.state
            .lock()
            .expect("drill lock")
            .line()
            .map(StudyLineRecord::from)
    }

    /// One step of the rewind or autoplay.
    pub fn step(&self, now_ms: i64) {
        self.state.lock().expect("drill lock").step(now_ms);
    }

    pub fn next_line(&self, timing: SchedTiming) {
        let mut d = self.state.lock().expect("drill lock");
        let doc = self.doc.lock();
        d.next_line(&doc, &timing);
    }

    pub fn user_moved(
        &self,
        from: BoardSquare,
        to: BoardSquare,
        promotion: Option<PieceKind>,
        timing: SchedTiming,
        now_ms: i64,
    ) -> Changes {
        self.act(|d, doc| d.user_moved(doc, from, to, promotion, &timing, now_ms))
    }

    pub fn wrong_timeout(&self) {
        self.state.lock().expect("drill lock").wrong_timeout();
    }

    pub fn browse_node(&self, timing: SchedTiming, now_ms: i64) -> NodeAndChanges {
        let mut d = self.state.lock().expect("drill lock");
        let (node, changes) = self.doc.edit(|doc, _| d.browse_node(doc, &timing, now_ms));
        NodeAndChanges { node, changes }
    }

    pub fn hint(&self, timing: SchedTiming, now_ms: i64) -> Changes {
        self.act(|d, doc| d.hint(doc, &timing, now_ms))
    }

    pub fn analysis_moves(&self, timing: SchedTiming, now_ms: i64) -> MovesAndChanges {
        let mut d = self.state.lock().expect("drill lock");
        let (moves, changes) = self
            .doc
            .edit(|doc, _| d.analysis_moves(doc, &timing, now_ms));
        MovesAndChanges { moves, changes }
    }

    pub fn extend_limits(&self, new: i64, review: i64, timing: SchedTiming) -> Changes {
        self.act(|d, doc| d.extend_limits(doc, new, review, &timing))
    }

    pub fn check_again(&self, timing: SchedTiming) {
        let mut d = self.state.lock().expect("drill lock");
        let doc = self.doc.lock();
        d.check_again(&doc, &timing);
    }
}
