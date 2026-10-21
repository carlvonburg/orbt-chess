use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard};

use ot_core::chess::{Epd, PlayedMove, Side};
use ot_core::coverage::{CoverageGap, NodeCoverage, ReplyInfo, StatsSource};
use ot_core::document::{Changes, OutlineItem, Repertoire, StudyDefaults};
use ot_core::explorer::{ExplorerDatabase, ExplorerStats};
use ot_core::formats::Timestamp;
use ot_core::repertoire::{NodeId, RepertoireTree};
use ot_core::statistics::GraphParts;
use ot_core::training::anki::{
    Card, Counts, DeckLimits, RemainingLimits, RevlogEntry, SchedTiming,
};
use ot_core::training::{PracticeMode, Progress};

use crate::explorer::Explorer;
use crate::position::Position;
use crate::types::Node;

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum DocumentError {
    #[error("{message}")]
    Unreadable { message: String },
}

/// Told about changes the core made by itself (stats arriving for this repertoire).
#[uniffi::export(with_foreign)]
pub trait DocumentListener: Send + Sync {
    fn changed(&self, changes: Changes);
}

#[derive(uniffi::Record)]
pub struct Opened {
    pub document: Arc<RepertoireDoc>,
    /// What to do right away (e.g. save a compacted PGN).
    pub changes: Changes,
}

#[derive(uniffi::Record)]
pub struct AddResult {
    pub node: Option<NodeId>,
    pub changes: Changes,
}

/// An open repertoire. The platform reads and writes its files; see `Changes`.
#[derive(uniffi::Object)]
pub struct RepertoireDoc {
    inner: Mutex<Repertoire>,
    pub(crate) explorer: Arc<Explorer>,
    listener: Mutex<Option<Arc<dyn DocumentListener>>>,
}

impl RepertoireDoc {
    pub(crate) fn lock(&self) -> MutexGuard<'_, Repertoire> {
        self.inner.lock().expect("document lock")
    }

    /// Runs `f` with the document and its database's stats, then queues the coverage
    /// requests it may have made necessary.
    pub(crate) fn edit<R>(
        &self,
        f: impl FnOnce(&mut Repertoire, &dyn StatsSource) -> (R, Changes),
    ) -> (R, Changes) {
        let mut doc = self.lock();
        let database = doc.database().clone();
        let (result, changes) = self
            .explorer
            .with_stats(&database, |stats| f(&mut doc, stats));
        let requests = changes.coverage_check.then(|| doc.coverage_requests());
        drop(doc);
        if let Some(requests) = requests {
            self.explorer.request_all(&database, requests);
        }
        (result, changes)
    }

    fn change(&self, f: impl FnOnce(&mut Repertoire, &dyn StatsSource) -> Changes) -> Changes {
        self.edit(|doc, stats| ((), f(doc, stats))).1
    }

    pub(crate) fn stats_arrived(&self, database: &ExplorerDatabase, epd: &Epd) {
        if self.lock().database() != database {
            return;
        }
        let changes = self.change(|doc, stats| doc.stats_arrived(epd, stats));
        let listener = self.listener.lock().expect("listener lock").clone();
        if let Some(l) = listener {
            l.changed(changes);
        }
    }

    /// An offline coverage table for this database was added: its positions need no fetching.
    pub(crate) fn table_added(&self, database: &ExplorerDatabase) {
        if self.lock().database() != database {
            return;
        }
        let changes = self.change(|doc, stats| doc.recompute_coverage(stats));
        let listener = self.listener.lock().expect("listener lock").clone();
        if let Some(l) = listener {
            l.changed(changes);
        }
    }

    fn read<R>(&self, f: impl FnOnce(&Repertoire, &dyn StatsSource) -> R) -> R {
        let doc = self.lock();
        let database = doc.database().clone();
        self.explorer.with_stats(&database, |stats| f(&doc, stats))
    }
}

#[uniffi::export]
/// Opens a repertoire from its files' contents.
pub fn open_repertoire(
    pgn_text: String,
    sidecar: Vec<u8>,
    defaults: StudyDefaults,
    explorer: Arc<Explorer>,
) -> Result<Opened, DocumentError> {
    let database = ot_core::formats::Sidecar::decode(&sidecar)
        .map_err(|e| DocumentError::Unreadable {
            message: e.to_string(),
        })?
        .database;
    let (doc, changes) = explorer
        .with_stats(&database, |stats| {
            Repertoire::open(&pgn_text, &sidecar, defaults, stats)
        })
        .map_err(|e| DocumentError::Unreadable {
            message: e.to_string(),
        })?;
    let document = Arc::new(RepertoireDoc {
        inner: Mutex::new(doc),
        explorer: Arc::clone(&explorer),
        listener: Mutex::new(None),
    });
    explorer.register(&document);
    Ok(Opened { document, changes })
}

#[uniffi::export]
impl RepertoireDoc {
    pub fn set_listener(&self, listener: Arc<dyn DocumentListener>) {
        *self.listener.lock().expect("listener lock") = Some(listener);
    }

    // Settings and state

    pub fn revision(&self) -> u64 {
        self.lock().revision()
    }

    pub fn color(&self) -> Side {
        self.lock().color()
    }

    pub fn database(&self) -> ExplorerDatabase {
        self.lock().database().clone()
    }

    pub fn target_games(&self) -> i64 {
        self.lock().sidecar().target_games
    }

    /// The repertoire's own practice mode, if it overrides the default.
    pub fn own_practice_mode(&self) -> Option<PracticeMode> {
        self.lock().sidecar().practice_mode
    }

    pub fn practice_mode(&self) -> PracticeMode {
        self.lock().practice_mode()
    }

    pub fn limits(&self) -> Option<DeckLimits> {
        self.lock().sidecar().limits
    }

    pub fn last_line(&self) -> Option<Vec<String>> {
        self.lock().sidecar().last_line.clone()
    }

    pub fn is_excluded(&self, uci: String, node: NodeId) -> bool {
        let doc = self.lock();
        doc.tree()
            .get(node)
            .is_some_and(|n| doc.sidecar().is_excluded(&uci, &n.epd))
    }

    pub fn can_undo(&self) -> bool {
        self.lock().can_undo()
    }

    pub fn load_warnings(&self) -> Vec<String> {
        self.lock().tree().load_warnings.clone()
    }

    // The tree

    pub fn count(&self) -> u32 {
        self.lock().tree().count() as u32
    }

    pub fn root(&self) -> Node {
        let doc = self.lock();
        Node::from_core(doc.tree().root(), doc.tree())
    }

    pub fn node(&self, id: NodeId) -> Option<Node> {
        let doc = self.lock();
        doc.tree().get(id).map(|n| Node::from_core(n, doc.tree()))
    }

    /// Every node, in id order (for the outline and search).
    pub fn all_nodes(&self) -> Vec<Node> {
        let doc = self.lock();
        doc.tree()
            .nodes()
            .map(|n| Node::from_core(n, doc.tree()))
            .collect()
    }

    pub fn position(&self, id: NodeId) -> Option<Arc<Position>> {
        self.lock()
            .tree()
            .get(id)
            .map(|n| Arc::new(Position(n.position.clone())))
    }

    pub fn child_by_uci(&self, id: NodeId, uci: String) -> Option<NodeId> {
        self.lock().tree().child_by_uci(id, &uci)
    }

    pub fn child_by_san(&self, id: NodeId, san: String) -> Option<NodeId> {
        self.lock().tree().child_by_san(id, &san)
    }

    /// Node ids from the root to `id`, inclusive.
    pub fn path(&self, id: NodeId) -> Vec<NodeId> {
        self.lock().tree().path(id)
    }

    pub fn moves(&self, id: NodeId) -> Vec<PlayedMove> {
        self.lock().tree().moves(id)
    }

    /// Depth-first order, parents before children.
    pub fn subtree(&self, id: NodeId) -> Vec<NodeId> {
        self.lock().tree().subtree(id)
    }

    pub fn leaves(&self, id: NodeId) -> Vec<NodeId> {
        self.lock().tree().leaves(id)
    }

    pub fn is_ancestor(&self, a: NodeId, b: NodeId) -> bool {
        self.lock().tree().is_ancestor(a, b)
    }

    pub fn transposition_target(&self, id: NodeId) -> Option<NodeId> {
        self.lock().tree().transposition_target(id)
    }

    pub fn nodes_at(&self, epd: Epd) -> Vec<NodeId> {
        self.lock().tree().nodes_at(&epd).to_vec()
    }

    pub fn node_following(&self, ucis: Vec<String>, start: NodeId) -> Option<NodeId> {
        self.lock().node_following(&ucis, start)
    }

    /// SAN line to a node, e.g. "1. e4 c5 2. Nf3".
    pub fn line_text(&self, id: NodeId) -> String {
        self.lock().line_text(id)
    }

    /// The outline rows below `id`: one per child, each a chain of moves without branching.
    pub fn outline_children(&self, id: NodeId) -> Vec<OutlineItem> {
        ot_core::document::outline_children(self.lock().tree(), id)
    }

    /// Nodes whose move (loose SAN) or note matches `query`, shallowest first.
    pub fn search(&self, query: String, limit: u32) -> Vec<NodeId> {
        ot_core::document::search(self.lock().tree(), &query, limit as usize)
    }

    /// A gap as a line of moves, e.g. "1. e4 c5 2. Nf3 Nc6".
    pub fn gap_text(&self, gap: CoverageGap) -> String {
        ot_core::document::gap_text(self.lock().tree(), &gap)
    }

    pub fn saved_move_count(&self) -> i64 {
        self.lock().saved_move_count()
    }

    // Stats and coverage

    pub fn stats(&self, epd: Epd) -> Option<ExplorerStats> {
        self.read(|_, stats| stats.stats(&epd).map(|s| s.into_owned()))
    }

    /// The opening name of a node, or of its nearest ancestor, from stats already loaded.
    pub fn opening_name(&self, id: NodeId) -> Option<String> {
        self.read(|doc, stats| doc.opening_name(id, stats))
    }

    pub fn coverage(&self, id: NodeId) -> Option<NodeCoverage> {
        self.lock().coverage().get(id).cloned()
    }

    pub fn coverage_root(&self) -> Option<NodeCoverage> {
        self.lock().coverage().root().cloned()
    }

    /// All gaps, biggest first.
    pub fn gaps(&self) -> Vec<CoverageGap> {
        self.lock().coverage().gaps()
    }

    /// Opponent positions above your target whose stats are not loaded yet.
    pub fn unchecked_positions(&self) -> i64 {
        self.lock().unchecked_positions()
    }

    /// Replies at a position that is not in the repertoire (a draft on the board).
    pub fn draft_replies(&self, epd: Epd, reach: Option<f64>) -> Option<Vec<ReplyInfo>> {
        self.read(|doc, stats| {
            let s = stats.stats(&epd)?;
            Some(doc.coverage().draft_replies(&epd, &s, reach))
        })
    }

    /// Fetches stats for the position on screen, ahead of the coverage check.
    pub fn request_stats(&self, epd: Epd, now_ms: i64) {
        let database = self.lock().database().clone();
        self.explorer.focus(epd, database, now_ms);
    }

    /// A screen of this repertoire appeared: the coverage check runs while any is showing.
    pub fn start_coverage_check(&self) -> Changes {
        self.change(|doc, _| doc.start_coverage_check())
    }

    pub fn stop_coverage_check(&self) {
        let (none_left, database) = {
            let mut doc = self.lock();
            (doc.stop_coverage_check(), doc.database().clone())
        };
        if none_left {
            self.explorer.cancel_all(database);
        }
    }

    // Edits

    pub fn add_move(&self, uci: String, parent: NodeId) -> AddResult {
        let (node, changes) = self.edit(|doc, stats| doc.add_move(&uci, parent, stats));
        AddResult { node, changes }
    }

    pub fn add_line(&self, ucis: Vec<String>, start: NodeId) -> AddResult {
        let (node, changes) = self.edit(|doc, stats| doc.add_line(&ucis, start, stats));
        AddResult { node, changes }
    }

    pub fn delete(&self, id: NodeId) -> Changes {
        self.change(|doc, stats| doc.delete(id, stats))
    }

    pub fn promote(&self, id: NodeId) -> Changes {
        self.change(|doc, stats| doc.promote(id, stats))
    }

    pub fn set_note(&self, text: String, id: NodeId) -> Changes {
        self.change(|doc, _| doc.set_note(&text, id))
    }

    pub fn undo(&self) -> Changes {
        self.change(|doc, stats| doc.undo(stats))
    }

    // Settings

    /// Changes the coverage settings (loading the new database's stats first).
    pub fn update_settings(
        &self,
        color: Side,
        database: ExplorerDatabase,
        target_games: i64,
        now: Timestamp,
    ) -> Changes {
        let old = self.lock().database().clone();
        if old != database {
            self.explorer.cancel_all(old);
        }
        self.explorer.ensure_loaded(database.clone());
        let mut doc = self.lock();
        let changes = self.explorer.with_stats(&database, |stats| {
            doc.update_settings(color, database.clone(), target_games, now, stats)
        });
        let requests = doc.coverage_requests();
        drop(doc);
        self.explorer.request_all(&database, requests);
        changes
    }

    pub fn set_excluded(
        &self,
        uci: String,
        node: NodeId,
        excluded: bool,
        now: Timestamp,
    ) -> Changes {
        self.change(|doc, stats| doc.set_excluded(&uci, node, excluded, now, stats))
    }

    pub fn remember_line(&self, ucis: Vec<String>) -> Changes {
        self.change(|doc, _| doc.remember_line(ucis))
    }

    pub fn update_study_settings(
        &self,
        limits: DeckLimits,
        practice_mode: Option<PracticeMode>,
        now: Timestamp,
    ) -> Changes {
        self.change(|doc, _| doc.update_study_settings(limits, practice_mode, now))
    }

    pub fn set_defaults(&self, defaults: StudyDefaults) -> Changes {
        self.change(|doc, _| doc.set_defaults(defaults))
    }

    // Training

    pub fn card(&self, epd: Epd) -> Option<Card> {
        self.lock().sidecar().study_cards.get(&epd).cloned()
    }

    pub fn cards(&self) -> HashMap<Epd, Card> {
        self.lock().sidecar().cards()
    }

    /// Your-turn nodes with a main move under `root`, where cards are asked.
    pub fn card_nodes(&self, root: NodeId) -> Vec<NodeId> {
        self.lock().trainer().card_nodes(root)
    }

    pub fn card_epds(&self, root: NodeId) -> Vec<Epd> {
        let trainer = self.lock().trainer();
        if root == RepertoireTree::ROOT {
            trainer.card_epd_set.iter().cloned().collect()
        } else {
            trainer.card_epds(root).into_iter().collect()
        }
    }

    pub fn suspended_card_epds(&self, root: NodeId) -> Vec<Epd> {
        self.lock()
            .trainer()
            .suspended_card_epds(root)
            .into_iter()
            .collect()
    }

    /// The opening branches for per-branch statistics.
    pub fn opening_branches(&self) -> Vec<NodeId> {
        let trainer = self.lock().trainer();
        ot_core::statistics::opening_branches(&trainer)
    }

    pub fn learning_progress(&self, node: NodeId) -> Progress {
        self.lock().learning_progress(node)
    }

    /// This repertoire's part of the statistics: of the whole collection (every stored card),
    /// or of this repertoire alone (only cards at its positions). `on_disk` is the review log file.
    pub fn graph_parts(&self, on_disk: Vec<u8>, whole_collection: bool) -> GraphParts {
        let mut doc = self.lock();
        let revlog = doc.review_log(&on_disk);
        if whole_collection {
            GraphParts::collection(&mut doc, revlog)
        } else {
            GraphParts::repertoire(&mut doc, revlog)
        }
    }

    /// The cards stored for this repertoire's positions.
    pub fn repertoire_cards(&self) -> HashMap<Epd, Card> {
        ot_core::statistics::repertoire_cards(&mut self.lock())
    }

    /// The reach of each card position, for expected recall.
    pub fn card_reach(&self) -> HashMap<Epd, f64> {
        ot_core::statistics::card_reach(&mut self.lock())
    }

    /// How often each position is reached.
    pub fn reach(&self) -> HashMap<NodeId, f64> {
        self.lock().reach()
    }

    pub fn study_counts(&self, timing: SchedTiming) -> Counts {
        self.lock().study_counts(&timing)
    }

    pub fn remaining_limits(&self, timing: SchedTiming) -> RemainingLimits {
        self.lock().remaining_limits(&timing)
    }

    pub fn reviews_beyond_limit(&self, timing: SchedTiming) -> i64 {
        self.lock().reviews_beyond_limit(&timing)
    }

    pub fn extend_limits_today(&self, new: i64, review: i64, timing: SchedTiming) -> Changes {
        self.change(|doc, _| doc.extend_limits_today(new, review, &timing))
    }

    /// Unix seconds when the next card falls due after today's are done.
    pub fn next_due(&self, timing: SchedTiming) -> Option<i64> {
        self.lock().sidecar().next_due(&timing)
    }

    pub fn later_learning_dues(&self, timing: SchedTiming) -> Vec<i64> {
        self.lock().sidecar().later_learning_dues(&timing)
    }

    pub fn due_tomorrow(&self, timing: SchedTiming) -> i64 {
        self.lock().sidecar().due_tomorrow(&timing)
    }

    /// The whole review log: the file's entries plus answers not written yet.
    pub fn review_log(&self, on_disk: Vec<u8>) -> Vec<RevlogEntry> {
        self.lock().review_log(&on_disk)
    }

    // Saving

    pub fn pgn_to_save(&self) -> Option<String> {
        self.lock().pgn_to_save()
    }

    pub fn pgn_saved(&self, text: String) {
        self.lock().pgn_saved(text)
    }

    pub fn sidecar_to_save(&self, timing: SchedTiming) -> Option<Vec<u8>> {
        self.lock().sidecar_to_save(&timing)
    }

    pub fn sidecar_saved(&self, data: Vec<u8>) {
        self.lock().sidecar_saved(data)
    }

    pub fn revlog_to_append(&self) -> Option<Vec<u8>> {
        self.lock().revlog_to_append()
    }

    pub fn revlog_appended(&self) {
        self.lock().revlog_appended()
    }

    // Changes from elsewhere

    pub fn remote_pgn(&self, text: String) -> Changes {
        self.change(|doc, stats| doc.remote_pgn(&text, stats))
    }

    pub fn merge_conflict_version(&self, text: String) -> Changes {
        self.change(|doc, stats| doc.merge_conflict_version(&text, stats))
    }

    /// The sidecar changed on disk; reloads stats and recomputes when settings changed.
    pub fn remote_sidecar(&self, data: Vec<u8>) -> Changes {
        let changes = self.change(|doc, _| doc.remote_sidecar(&data));
        if !changes.reload_stats {
            return changes;
        }
        let database = self.lock().database().clone();
        self.explorer.ensure_loaded(database);
        let mut recomputed = self.change(|doc, stats| doc.recompute_coverage(stats));
        recomputed.save_sidecar_after_ms = recomputed
            .save_sidecar_after_ms
            .or(changes.save_sidecar_after_ms);
        recomputed
    }
}
