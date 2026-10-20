use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use super::save_delay;
use crate::chess::{Epd, Side};
use crate::coverage::{CoverageEngine, StatsSource};
use crate::explorer::ExplorerDatabase;
use crate::formats::{Sidecar, Summary, Timestamp, revlog};
use crate::repertoire::{NodeId, RepertoireTree};
use crate::training::anki::{
    Card, CardQueue, Counts, DeckConfig, DeckLimits, Rating, RemainingLimits, RevlogEntry,
    SchedTiming, Scheduler,
};
use crate::training::{PracticeMode, Progress, StudySession, Trainer};

/// The study defaults from the app's settings; a repertoire's options override them.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct StudyDefaults {
    pub new_per_day: i64,
    pub reviews_per_day: i64,
    pub practice_mode: PracticeMode,
}

impl Default for StudyDefaults {
    fn default() -> StudyDefaults {
        let config = DeckConfig::default();
        StudyDefaults {
            new_per_day: config.new_per_day,
            reviews_per_day: config.reviews_per_day,
            practice_mode: PracticeMode::default(),
        }
    }
}

/// What an operation changed, and what the platform should do about it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Changes {
    /// Bumped on every change, so views can refresh derived values.
    pub revision: u64,
    /// The move tree changed (so card positions and lines may have).
    pub tree_changed: bool,
    /// Save the PGN after this many milliseconds (replaces an earlier request).
    pub save_pgn_after_ms: Option<u32>,
    /// Save the sidecar after this many milliseconds (replaces an earlier request).
    pub save_sidecar_after_ms: Option<u32>,
    /// The coverage database or settings changed: load that database's stats, then call
    /// `recompute_coverage`.
    pub reload_stats: bool,
    /// Positions needing stats may have changed: ask `coverage_requests` again.
    pub coverage_check: bool,
}

#[derive(Debug, thiserror::Error)]
pub enum OpenError {
    #[error("the sidecar could not be read: {0}")]
    Sidecar(#[from] serde_json::Error),
}

const UNDO_LIMIT: usize = 100;

/// An open repertoire. See the module documentation.
#[derive(Debug)]
pub struct Repertoire {
    tree: Arc<RepertoireTree>,
    sidecar: Sidecar,
    coverage: CoverageEngine,
    undo: Vec<Arc<RepertoireTree>>,
    defaults: StudyDefaults,
    revision: u64,
    tree_version: u64,
    changes: Changes,
    /// Answers not yet appended to the review log.
    pending_revlog: Vec<RevlogEntry>,
    last_written_pgn: String,
    last_written_sidecar: Vec<u8>,
    /// A local change since the last sidecar write may have changed the summary. Without one,
    /// a summary that differs from the file's is not written (see `sidecar_to_save`).
    summary_dirty: bool,
    /// Local edits not written to the PGN yet.
    pgn_dirty: bool,
    /// Screens of this repertoire showing (overview, builder, study): the coverage check runs
    /// while any is.
    coverage_viewers: u32,
    trainer_cache: Option<(u64, Side, Arc<Trainer>)>,
    suspended_cache: Option<(u64, Side, i64)>,
    progress_cache: Option<(u64, Progress)>,
    counts_cache: Option<(u64, i64, Counts)>,
}

impl Repertoire {
    /// Opens a repertoire from its files. `stats` are the cached explorer stats of the
    /// sidecar's database.
    pub fn open(
        pgn_text: &str,
        sidecar_bytes: &[u8],
        defaults: StudyDefaults,
        stats: &dyn StatsSource,
    ) -> Result<(Repertoire, Changes), OpenError> {
        let sidecar = Sidecar::decode(sidecar_bytes)?;
        let tree = RepertoireTree::from_pgn(pgn_text);
        let coverage = CoverageEngine::new(sidecar.coverage_settings());
        let mut doc = Repertoire {
            tree: Arc::new(tree),
            sidecar,
            coverage,
            undo: Vec::new(),
            defaults,
            revision: 0,
            tree_version: 0,
            changes: Changes::default(),
            pending_revlog: Vec::new(),
            last_written_pgn: pgn_text.to_owned(),
            last_written_sidecar: sidecar_bytes.to_vec(),
            summary_dirty: false,
            pgn_dirty: false,
            coverage_viewers: 0,
            trainer_cache: None,
            suspended_cache: None,
            progress_cache: None,
            counts_cache: None,
        };
        // The file repeats lines under every move order (e.g. a Chessbook export): write the
        // compact version, so later loads are fast.
        if doc.tree.merged_transpositions > 0 {
            doc.request_pgn_save();
        }
        doc.recompute_coverage_inner(stats);
        let changes = doc_changes(&mut doc);
        Ok((doc, changes))
    }

    // Reading

    pub fn tree(&self) -> &Arc<RepertoireTree> {
        &self.tree
    }

    pub fn sidecar(&self) -> &Sidecar {
        &self.sidecar
    }

    pub fn coverage(&self) -> &CoverageEngine {
        &self.coverage
    }

    pub fn revision(&self) -> u64 {
        self.revision
    }

    pub fn color(&self) -> Side {
        self.sidecar.color
    }

    pub fn database(&self) -> &ExplorerDatabase {
        &self.sidecar.database
    }

    pub fn can_undo(&self) -> bool {
        !self.undo.is_empty()
    }

    /// Every move in the PGN, both sides.
    pub fn saved_move_count(&self) -> i64 {
        self.tree.count() as i64 - 1
    }

    /// Opponent positions above your target whose stats are not loaded yet.
    pub fn unchecked_positions(&self) -> i64 {
        self.coverage.root().map_or(0, |r| r.pending_count)
    }

    /// The opening name of a node, or of its nearest ancestor, from stats already loaded.
    pub fn opening_name(&self, id: NodeId, stats: &dyn StatsSource) -> Option<String> {
        let mut cursor = Some(id);
        while let Some(node) = cursor.and_then(|c| self.tree.get(c)) {
            if let Some(opening) = stats.stats(&node.epd).and_then(|s| s.opening.as_ref()) {
                return Some(opening.name.clone());
            }
            cursor = node.parent;
        }
        None
    }

    /// Follows UCI moves from `start`; None if any is missing.
    pub fn node_following(&self, ucis: &[String], start: NodeId) -> Option<NodeId> {
        let mut cursor = start;
        for uci in ucis {
            cursor = self.tree.child_by_uci(cursor, uci)?;
        }
        Some(cursor)
    }

    /// SAN line to a node, e.g. "1. e4 c5 2. Nf3".
    pub fn line_text(&self, id: NodeId) -> String {
        line_text(&self.tree, id)
    }

    // Coverage check

    /// A screen of this repertoire appeared: the coverage check runs while any is showing.
    pub fn start_coverage_check(&mut self) -> Changes {
        self.coverage_viewers += 1;
        self.changes.coverage_check = true;
        doc_changes(self)
    }

    /// A screen disappeared. Returns true when none is left, so the platform can cancel the
    /// requests for this database.
    pub fn stop_coverage_check(&mut self) -> bool {
        self.coverage_viewers = self.coverage_viewers.saturating_sub(1);
        self.coverage_viewers == 0
    }

    /// Opponent positions you would meet at least once in N games whose stats are needed,
    /// most frequent first; empty while no screen of this repertoire is showing.
    pub fn coverage_requests(&self) -> Vec<(Epd, f64)> {
        if self.coverage_viewers == 0 {
            return Vec::new();
        }
        self.coverage.pending_positions(&self.tree)
    }

    /// Stats arrived for a position of this repertoire's database.
    pub fn stats_arrived(&mut self, epd: &Epd, stats: &dyn StatsSource) -> Changes {
        let totals_changed = self.coverage.stats_arrived(epd, &self.tree, stats);
        self.bump();
        self.changes.coverage_check = true;
        // The sidecar's summary (shown in the library) only holds the totals.
        if totals_changed {
            self.request_sidecar_save(save_delay::NOW);
        }
        doc_changes(self)
    }

    /// Recomputes coverage from scratch (after the database's stats were loaded).
    pub fn recompute_coverage(&mut self, stats: &dyn StatsSource) -> Changes {
        self.recompute_coverage_inner(stats);
        doc_changes(self)
    }

    fn recompute_coverage_inner(&mut self, stats: &dyn StatsSource) {
        self.coverage = CoverageEngine::new(self.sidecar.coverage_settings());
        self.coverage.recompute_all(&self.tree, stats);
        self.bump();
        self.sync_suspension();
        self.changes.coverage_check = true;
    }

    // Edits

    /// Adds a move after `parent`; an existing move is reused.
    pub fn add_move(
        &mut self,
        uci: &str,
        parent: NodeId,
        stats: &dyn StatsSource,
    ) -> (Option<NodeId>, Changes) {
        if let Some(existing) = self.tree.child_by_uci(parent, uci) {
            return (Some(existing), Changes::default());
        }
        let mut result = None;
        self.perform(parent, stats, |tree| {
            result = tree.add_move(uci, parent);
            result
                .and_then(|id| tree.get(id))
                .map(|n| HashSet::from([n.epd.clone()]))
                .unwrap_or_default()
        });
        (result, doc_changes(self))
    }

    /// Adds moves one after another; returns the last node.
    pub fn add_line(
        &mut self,
        ucis: &[String],
        start: NodeId,
        stats: &dyn StatsSource,
    ) -> (Option<NodeId>, Changes) {
        if ucis.is_empty() {
            return (Some(start), Changes::default());
        }
        if let Some(existing) = self.node_following(ucis, start) {
            return (Some(existing), Changes::default());
        }
        let mut result = None;
        self.perform(start, stats, |tree| {
            result = tree.add_line(ucis, start);
            subtree_epds(tree, start)
        });
        (result, doc_changes(self))
    }

    pub fn delete(&mut self, id: NodeId, stats: &dyn StatsSource) -> Changes {
        let Some(parent) = self.tree.get(id).and_then(|n| n.parent) else {
            return Changes::default();
        };
        self.perform(parent, stats, |tree| {
            let removed = subtree_epds(tree, id);
            tree.delete(id);
            removed
        });
        doc_changes(self)
    }

    pub fn promote(&mut self, id: NodeId, stats: &dyn StatsSource) -> Changes {
        let Some(parent) = self.tree.get(id).and_then(|n| n.parent) else {
            return Changes::default();
        };
        self.perform(parent, stats, |tree| {
            tree.promote(id);
            subtree_epds(tree, parent)
        });
        doc_changes(self)
    }

    pub fn set_note(&mut self, text: &str, id: NodeId) -> Changes {
        if self.tree.get(id).is_none_or(|n| n.note() == text) {
            return Changes::default();
        }
        self.push_undo(Arc::clone(&self.tree));
        Arc::make_mut(&mut self.tree).set_note(text, id);
        self.tree_did_change();
        self.did_edit();
        doc_changes(self)
    }

    pub fn undo(&mut self, stats: &dyn StatsSource) -> Changes {
        let Some(previous) = self.undo.pop() else {
            return Changes::default();
        };
        self.tree = previous;
        self.tree_did_change();
        self.coverage.recompute_all(&self.tree, stats);
        self.bump();
        self.sync_suspension();
        self.changes.coverage_check = true;
        self.request_pgn_save();
        doc_changes(self)
    }

    fn perform(
        &mut self,
        node: NodeId,
        stats: &dyn StatsSource,
        edit: impl FnOnce(&mut RepertoireTree) -> HashSet<Epd>,
    ) {
        let before = Arc::clone(&self.tree);
        let mut working = (*before).clone();
        let epds = edit(&mut working);
        let changed = working.count() != before.count()
            || working.root().children != before.root().children
            || working.get(node).map(|n| &n.children) != before.get(node).map(|n| &n.children);
        if !changed {
            return;
        }
        self.push_undo(before);
        self.tree = Arc::new(working);
        self.tree_did_change();
        self.coverage.update(node, &epds, &self.tree, stats);
        self.did_edit();
    }

    fn push_undo(&mut self, tree: Arc<RepertoireTree>) {
        self.undo.push(tree);
        if self.undo.len() > UNDO_LIMIT {
            self.undo.remove(0);
        }
    }

    fn tree_did_change(&mut self) {
        self.tree_version += 1;
        self.changes.tree_changed = true;
    }

    fn did_edit(&mut self) {
        self.bump();
        self.sync_suspension();
        self.changes.coverage_check = true;
        self.request_pgn_save();
        self.request_sidecar_save(save_delay::SIDECAR_AFTER_EDIT_MS);
    }

    // Settings

    /// Changes the coverage settings. When the database changes, load its stats before calling
    /// (they are what `stats` reads).
    pub fn update_settings(
        &mut self,
        color: Side,
        database: ExplorerDatabase,
        target_games: i64,
        min_games: i64,
        now: Timestamp,
        stats: &dyn StatsSource,
    ) -> Changes {
        self.sidecar.color = color;
        self.sidecar.database = database;
        self.sidecar.target_games = target_games;
        self.sidecar.min_games = min_games;
        self.sidecar.settings_modified = now;
        self.recompute_coverage_inner(stats);
        self.request_sidecar_save(save_delay::SIDECAR_AFTER_SETTINGS_MS);
        doc_changes(self)
    }

    /// Excludes an opponent move at `node`'s position from coverage, or includes it again.
    /// Applies wherever the position occurs.
    pub fn set_excluded(
        &mut self,
        uci: &str,
        node: NodeId,
        excluded: bool,
        now: Timestamp,
        stats: &dyn StatsSource,
    ) -> Changes {
        let Some(epd) = self.tree.get(node).map(|n| n.epd.clone()) else {
            return Changes::default();
        };
        if self.sidecar.is_excluded(uci, &epd) == excluded {
            return Changes::default();
        }
        self.sidecar.set_excluded(uci, &epd, excluded, now);
        self.coverage.settings = self.sidecar.coverage_settings();
        self.coverage.exclusions_changed(&epd, &self.tree, stats);
        self.bump();
        self.request_sidecar_save(save_delay::SIDECAR_AFTER_SETTINGS_MS);
        doc_changes(self)
    }

    /// The last position the user looked at in the builder.
    pub fn remember_line(&mut self, ucis: Vec<String>) -> Changes {
        if self.sidecar.last_line.as_ref() == Some(&ucis) {
            return Changes::default();
        }
        self.sidecar.last_line = Some(ucis);
        self.request_sidecar_save(save_delay::SIDECAR_AFTER_EDIT_MS);
        doc_changes(self)
    }

    /// Daily limits ("This deck") and practice mode for this repertoire.
    pub fn update_study_settings(
        &mut self,
        limits: DeckLimits,
        practice_mode: Option<PracticeMode>,
        now: Timestamp,
    ) -> Changes {
        self.sidecar.limits = (!limits.is_empty()).then_some(limits);
        self.sidecar.practice_mode = practice_mode;
        self.sidecar.settings_modified = now;
        self.bump();
        self.request_sidecar_save(save_delay::SIDECAR_AFTER_SETTINGS_MS);
        doc_changes(self)
    }

    /// The app's study defaults changed.
    pub fn set_defaults(&mut self, defaults: StudyDefaults) -> Changes {
        if self.defaults == defaults {
            return Changes::default();
        }
        self.defaults = defaults;
        self.bump();
        doc_changes(self)
    }

    // Training

    /// The trainer for the current tree and color, computed once per tree change.
    pub fn trainer(&mut self) -> Arc<Trainer> {
        let color = self.sidecar.color;
        if let Some((version, c, trainer)) = &self.trainer_cache
            && *version == self.tree_version
            && *c == color
        {
            return Arc::clone(trainer);
        }
        let trainer = Arc::new(Trainer::new(Arc::clone(&self.tree), color));
        self.trainer_cache = Some((self.tree_version, color, Arc::clone(&trainer)));
        trainer
    }

    /// Anki's preset with the app's daily limits.
    pub fn deck_config(&self) -> DeckConfig {
        DeckConfig {
            new_per_day: self.defaults.new_per_day,
            reviews_per_day: self.defaults.reviews_per_day,
            ..DeckConfig::default()
        }
    }

    pub fn practice_mode(&self) -> PracticeMode {
        self.sidecar
            .practice_mode
            .unwrap_or(self.defaults.practice_mode)
    }

    pub fn remaining_limits(&self, timing: &SchedTiming) -> RemainingLimits {
        RemainingLimits::new(
            &self.deck_config(),
            &self.sidecar.limits.unwrap_or_default(),
            &self.sidecar.study_stats.unwrap_or_default(),
            timing.days_elapsed,
        )
    }

    /// How often each position is reached, for ordering new cards and reviews.
    pub fn reach(&self) -> HashMap<NodeId, f64> {
        self.coverage
            .info()
            .iter()
            .filter(|(id, _)| self.tree.get(**id).is_some())
            .filter_map(|(&id, c)| c.reach.map(|r| (id, r)))
            .collect()
    }

    /// The whole repertoire's progress is read by the list, the overview and every save, so
    /// it is computed once per change; the card positions behind it once per tree change.
    pub fn learning_progress(&mut self, node: NodeId) -> Progress {
        let trainer = self.trainer();
        if node != RepertoireTree::ROOT {
            return trainer.progress(node, &self.sidecar.cards());
        }
        if let Some((revision, progress)) = self.progress_cache
            && revision == self.revision
        {
            return progress;
        }
        let color = self.sidecar.color;
        let suspended = match self.suspended_cache {
            Some((version, c, n)) if version == self.tree_version && c == color => n,
            _ => {
                let n = trainer.suspended_card_epds(RepertoireTree::ROOT).len() as i64;
                self.suspended_cache = Some((self.tree_version, color, n));
                n
            }
        };
        let mut progress = Progress {
            suspended,
            ..Progress::default()
        };
        for epd in &trainer.card_epd_set {
            progress.cards += 1;
            if let Some(card) = self.sidecar.study_cards.get(epd) {
                progress.add(card);
            }
        }
        self.progress_cache = Some((self.revision, progress));
        progress
    }

    /// Today's session, or one over a branch (a filtered deck).
    pub fn study_session(&mut self, branch: Option<NodeId>, timing: &SchedTiming) -> StudySession {
        let trainer = self.trainer();
        let cards = self.sidecar.cards();
        let learn_ahead = self.deck_config().learn_ahead_secs;
        match branch {
            Some(root) => StudySession::branch(
                trainer,
                self.practice_mode(),
                root,
                &cards,
                timing,
                learn_ahead,
                self.reach(),
            ),
            None => StudySession::daily(
                trainer,
                self.practice_mode(),
                &cards,
                self.remaining_limits(timing),
                timing,
                learn_ahead,
                self.reach(),
            ),
        }
    }

    /// Today's New / Learning / To Review counts, as on Anki's deck overview.
    pub fn study_counts(&mut self, timing: &SchedTiming) -> Counts {
        let minute = timing.now / 60;
        if let Some((revision, m, counts)) = self.counts_cache
            && revision == self.revision
            && m == minute
        {
            return counts;
        }
        let counts = self.study_session(None, timing).queue.counts;
        self.counts_cache = Some((self.revision, minute, counts));
        counts
    }

    /// Answers a card and logs it. Answers outside today's queue (a branch session or a review
    /// ahead) don't count toward the daily limits, as in an Anki filtered deck.
    #[allow(clippy::too_many_arguments)]
    pub fn answer(
        &mut self,
        epd: &Epd,
        position: i64,
        rating: Rating,
        filtered: bool,
        taken_millis: i64,
        timing: &SchedTiming,
    ) -> (Card, Changes) {
        let scheduler = Scheduler::new(self.deck_config());
        let result = scheduler.answer(
            self.sidecar.study_cards.get(epd),
            epd,
            position,
            rating,
            timing,
            filtered,
            taken_millis,
            None,
        );
        self.sidecar
            .study_cards
            .insert(epd.clone(), result.card.clone());
        if !filtered {
            let mut stats = self.sidecar.study_stats.unwrap_or_default();
            stats.record_answer(result.from_queue, result.revlog.time, timing.days_elapsed);
            self.sidecar.study_stats = Some(stats);
        }
        self.pending_revlog.push(result.revlog);
        self.bump();
        self.request_sidecar_save(save_delay::SIDECAR_AFTER_ANSWER_MS);
        (result.card, doc_changes(self))
    }

    /// Anki's custom study "Increase today's new/review card limit".
    pub fn extend_limits_today(&mut self, new: i64, review: i64, timing: &SchedTiming) -> Changes {
        let mut stats = self.sidecar.study_stats.unwrap_or_default();
        stats.extend_limits(timing.days_elapsed, new, review);
        self.sidecar.study_stats = Some(stats);
        self.bump();
        self.request_sidecar_save(save_delay::SIDECAR_AFTER_SETTINGS_MS);
        doc_changes(self)
    }

    /// Reviews due today beyond today's review limit (what Anki's custom study shows as
    /// "N more available").
    pub fn reviews_beyond_limit(&mut self, timing: &SchedTiming) -> i64 {
        let trainer = self.trainer();
        let due = self
            .sidecar
            .study_cards
            .iter()
            .filter(|(epd, card)| {
                matches!(card.queue, CardQueue::Review | CardQueue::DayLearn)
                    && card.due <= timing.days_elapsed
                    && trainer.card_epd_set.contains(*epd)
            })
            .count() as i64;
        (due - self.study_counts(timing).review).max(0)
    }

    /// Suspends cards below alternative moves and restores the main line's (Anki's suspend).
    fn sync_suspension(&mut self) {
        let trainer = self.trainer();
        if self.sidecar.sync_suspension(&trainer.card_epd_set) {
            self.bump();
            self.request_sidecar_save(save_delay::SIDECAR_AFTER_ANSWER_MS);
        }
    }

    // Saving

    /// The PGN to write, or None when the file already has it.
    pub fn pgn_to_save(&mut self) -> Option<String> {
        let text = self.tree.pgn_text();
        if text == self.last_written_pgn {
            self.pgn_dirty = false;
            return None;
        }
        Some(text)
    }

    /// The PGN was written.
    pub fn pgn_saved(&mut self, text: String) {
        self.last_written_pgn = text;
        self.pgn_dirty = false;
    }

    /// The sidecar to write (with a fresh summary for the library), or None when unchanged.
    /// A summary that differs from the file's is written only after a local change (edit,
    /// answer, settings, stats): each device computes its own, and writing it on every save or
    /// remote change would have devices rewrite the file for each other.
    pub fn sidecar_to_save(&mut self, timing: &SchedTiming) -> Option<Vec<u8>> {
        let progress = self.learning_progress(RepertoireTree::ROOT);
        let due_count = self.study_counts(timing).review;
        let root = self.coverage.root();
        self.sidecar.summary = Some(Summary {
            card_count: progress.cards,
            completion: root.map_or(0.0, |r| r.completion),
            config_key: self.sidecar.config_key(),
            due_count,
            gap_count: root.map_or(0, |r| r.gap_count),
            mature_count: progress.mature,
            saved_move_count: Some(self.saved_move_count()),
            suspended_count: Some(progress.suspended),
        });
        let data = self.sidecar.encoded();
        if data == self.last_written_sidecar {
            return None;
        }
        if !self.summary_dirty
            && Sidecar::decode(&self.last_written_sidecar)
                .is_ok_and(|on_disk| self.sidecar.same_content(&on_disk))
        {
            return None;
        }
        Some(data)
    }

    /// The sidecar was written.
    pub fn sidecar_saved(&mut self, data: Vec<u8>) {
        self.last_written_sidecar = data;
        self.summary_dirty = false;
    }

    /// Review log lines to append, or None when there are none.
    pub fn revlog_to_append(&self) -> Option<Vec<u8>> {
        (!self.pending_revlog.is_empty()).then(|| revlog::encode(&self.pending_revlog))
    }

    /// The lines from `revlog_to_append` were appended.
    pub fn revlog_appended(&mut self) {
        self.pending_revlog.clear();
    }

    /// The whole review log: the file's entries plus answers not written yet.
    pub fn review_log(&self, on_disk: &[u8]) -> Vec<RevlogEntry> {
        revlog::merged(&revlog::decode(on_disk), &self.pending_revlog)
    }

    // Changes from elsewhere

    /// The PGN changed on disk (another device, or another app).
    pub fn remote_pgn(&mut self, text: &str, stats: &dyn StatsSource) -> Changes {
        if text == self.last_written_pgn {
            return Changes::default();
        }
        let remote = RepertoireTree::from_pgn(text);
        if self.pgn_dirty {
            // Local edits not written yet: keep both sides.
            Arc::make_mut(&mut self.tree).merge_tree(&remote);
        } else {
            self.tree = Arc::new(remote);
            self.last_written_pgn = text.to_owned();
        }
        self.after_remote_tree(stats, text);
        doc_changes(self)
    }

    /// A conflicting version of the PGN (iCloud): merged in, never lost.
    pub fn merge_conflict_version(&mut self, text: &str, stats: &dyn StatsSource) -> Changes {
        Arc::make_mut(&mut self.tree).merge_tree(&RepertoireTree::from_pgn(text));
        self.pgn_dirty = true;
        self.after_remote_tree(stats, "");
        doc_changes(self)
    }

    fn after_remote_tree(&mut self, stats: &dyn StatsSource, remote_text: &str) {
        self.tree_did_change();
        self.undo.clear();
        self.coverage.recompute_all(&self.tree, stats);
        self.bump();
        self.sync_suspension();
        self.changes.coverage_check = true;
        if self.pgn_dirty || self.tree.pgn_text() != remote_text {
            self.request_pgn_save();
        }
    }

    /// The sidecar changed on disk. When `reload_stats` is set in the result, load the
    /// database's stats and call `recompute_coverage`.
    pub fn remote_sidecar(&mut self, data: &[u8]) -> Changes {
        if data == self.last_written_sidecar.as_slice() {
            return Changes::default();
        }
        let Ok(remote) = Sidecar::decode(data) else {
            return Changes::default();
        };
        let config_before = self.sidecar.config_key();
        let excluded_before = self.sidecar.excluded_moves.clone();
        self.sidecar = self.sidecar.merged(&remote);
        self.last_written_sidecar = data.to_vec();
        if self.sidecar.config_key() != config_before
            || self.sidecar.excluded_moves != excluded_before
        {
            self.changes.reload_stats = true;
        } else {
            self.bump();
        }
        // The other device's cards may have been suspended against its own copy of the PGN.
        self.sync_suspension();
        // Write back only what the remote copy lacks (cards, settings): rewriting it for a
        // summary of our own would have two devices answer each other's writes forever.
        self.changes.save_sidecar_after_ms =
            (!self.sidecar.same_content(&remote)).then_some(save_delay::NOW);
        doc_changes(self)
    }

    // Bookkeeping

    fn bump(&mut self) {
        self.revision += 1;
    }

    fn request_pgn_save(&mut self) {
        self.pgn_dirty = true;
        self.changes.save_pgn_after_ms = Some(save_delay::PGN_MS);
    }

    fn request_sidecar_save(&mut self, after_ms: u32) {
        self.summary_dirty = true;
        self.changes.save_sidecar_after_ms = Some(after_ms);
    }
}

/// Takes the changes collected by an operation.
fn doc_changes(doc: &mut Repertoire) -> Changes {
    let mut changes = std::mem::take(&mut doc.changes);
    changes.revision = doc.revision;
    changes
}

fn subtree_epds(tree: &RepertoireTree, id: NodeId) -> HashSet<Epd> {
    tree.subtree(id)
        .into_iter()
        .filter_map(|n| tree.get(n).map(|n| n.epd.clone()))
        .collect()
}

/// SAN line to a node, e.g. "1. e4 c5 2. Nf3".
pub fn line_text(tree: &RepertoireTree, id: NodeId) -> String {
    let mut parts: Vec<String> = Vec::new();
    for n in tree.path(id).into_iter().skip(1) {
        let Some(node) = tree.get(n) else { continue };
        let Some(mv) = &node.mv else { continue };
        let ply = node.ply as i64 - 1;
        if ply % 2 == 0 {
            parts.push(format!("{}.", ply / 2 + 1));
        } else if parts.is_empty() {
            parts.push(format!("{}...", ply / 2 + 1));
        }
        parts.push(mv.san.clone());
    }
    parts.join(" ")
}
