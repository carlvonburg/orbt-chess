use std::borrow::Cow;
use std::collections::{BTreeSet, HashMap, HashSet};

use super::{CoverageGap, CoverageSettings, GapKind, NodeCoverage, ReplyInfo, Status};
use crate::chess::Epd;
use crate::explorer::ExplorerStats;
use crate::repertoire::{NodeId, RepertoireNode, RepertoireTree};

/// Where the engine reads explorer stats for a position. Owned when decoded on demand (an
/// offline coverage table), borrowed from a cache otherwise.
pub trait StatsSource {
    fn stats(&self, epd: &Epd) -> Option<Cow<'_, ExplorerStats>>;
}

impl StatsSource for HashMap<Epd, ExplorerStats> {
    fn stats(&self, epd: &Epd) -> Option<Cow<'_, ExplorerStats>> {
        self.get(epd).map(Cow::Borrowed)
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Mode {
    Normal,
    Alternative,
}

/// Computes reach probability, completion and gaps for a repertoire.
///
/// Values are cached per node. After an edit only the edited subtree and its ancestors are
/// recomputed; when stats arrive for a position only the nodes with that EPD are. A full
/// recompute is needed only when settings or the database change.
#[derive(Clone, Debug)]
pub struct CoverageEngine {
    pub settings: CoverageSettings,
    info: HashMap<NodeId, NodeCoverage>,
    /// canonical node -> nodes whose completion depends on it through a transposition.
    referrers: HashMap<NodeId, BTreeSet<NodeId>>,
    /// node -> canonical nodes it references.
    references: HashMap<NodeId, BTreeSet<NodeId>>,
    /// (node, reply uci) -> EPD after the reply, cached because it needs a move replay.
    reply_epds: HashMap<(NodeId, String), Epd>,
    /// EPD after a reply -> the nodes with such a reply, for `refresh`.
    reply_epd_nodes: HashMap<Epd, BTreeSet<NodeId>>,
    changed_canonicals: BTreeSet<NodeId>,
}

impl CoverageEngine {
    pub fn new(settings: CoverageSettings) -> CoverageEngine {
        CoverageEngine {
            settings,
            info: HashMap::new(),
            referrers: HashMap::new(),
            references: HashMap::new(),
            reply_epds: HashMap::new(),
            reply_epd_nodes: HashMap::new(),
            changed_canonicals: BTreeSet::new(),
        }
    }

    pub fn get(&self, id: NodeId) -> Option<&NodeCoverage> {
        self.info.get(&id)
    }

    pub fn root(&self) -> Option<&NodeCoverage> {
        self.get(RepertoireTree::ROOT)
    }

    pub fn info(&self) -> &HashMap<NodeId, NodeCoverage> {
        &self.info
    }

    // Public updates

    pub fn recompute_all(&mut self, tree: &RepertoireTree, stats: &dyn StatsSource) {
        self.info.clear();
        self.referrers.clear();
        self.references.clear();
        self.changed_canonicals.clear();
        self.compute_subtree(RepertoireTree::ROOT, Some(1.0), Mode::Normal, tree, stats);
        // Canonical nodes may have been computed after the nodes that reference them.
        self.changed_canonicals = self.referrers.keys().copied().collect();
        self.propagate_transpositions(tree, stats);
    }

    /// Call after moves were added, deleted or promoted below `node` (pass the parent of a
    /// deleted node). `epds` are the positions of nodes that were added or removed, so
    /// transpositions into them elsewhere get refreshed.
    pub fn update(
        &mut self,
        node: NodeId,
        epds: &HashSet<Epd>,
        tree: &RepertoireTree,
        stats: &dyn StatsSource,
    ) {
        if tree.get(node).is_none() {
            self.recompute_all(tree, stats);
            return;
        }
        self.forget_missing(tree);
        let reach = self.info.get(&node).and_then(|c| c.reach);
        let mode = self.mode(node, tree);
        self.compute_subtree(node, reach, mode, tree, stats);
        self.refresh_ancestors(node, tree, stats);
        self.refresh(epds, node, tree, stats);
        self.propagate_transpositions(tree, stats);
    }

    /// Call when explorer stats for `epd` arrived.
    /// Returns whether the repertoire's totals (completion or gap count) changed.
    pub fn stats_arrived(
        &mut self,
        epd: &Epd,
        tree: &RepertoireTree,
        stats: &dyn StatsSource,
    ) -> bool {
        let ids = tree.nodes_at(epd);
        if ids.is_empty() {
            return false;
        }
        let before = self.root().map(|r| (r.completion, r.gap_count));
        for &id in ids {
            if let Some(reach) = self.info.get(&id).map(|c| c.reach) {
                let mode = self.mode(id, tree);
                self.compute_subtree(id, reach, mode, tree, stats);
                self.refresh_ancestors(id, tree, stats);
            }
        }
        // Missing replies that lead into this position may now have a different status.
        self.propagate_transpositions(tree, stats);
        self.root().map(|r| (r.completion, r.gap_count)) != before
    }

    /// Call after the excluded moves at `epd` changed in `settings`.
    pub fn exclusions_changed(
        &mut self,
        epd: &Epd,
        tree: &RepertoireTree,
        stats: &dyn StatsSource,
    ) {
        for &id in tree.nodes_at(epd) {
            if self.info.contains_key(&id) {
                self.aggregate(id, tree, stats);
                self.refresh_ancestors(id, tree, stats);
            }
        }
        self.propagate_transpositions(tree, stats);
    }

    /// Replies at a position that is not in the repertoire (a draft on the board), reached with
    /// probability `reach`. None of them is covered yet.
    pub fn draft_replies(
        &self,
        epd: &Epd,
        stats: &ExplorerStats,
        reach: Option<f64>,
    ) -> Vec<ReplyInfo> {
        let enough = stats.total() >= self.settings.min_games;
        stats
            .moves
            .iter()
            .map(|m| {
                let share = share_of(m.games(), stats.total());
                let r = reach.unwrap_or(0.0) * share;
                let excluded = self.settings.is_excluded(&m.uci, epd);
                let required =
                    enough && reach.is_some() && r >= self.settings.threshold() && !excluded;
                ReplyInfo {
                    uci: m.uci.clone(),
                    san: m.san.clone(),
                    share,
                    reach: r,
                    required,
                    excluded,
                    child: None,
                    transposes_to: None,
                    completion: 0.0,
                    games: m.games(),
                }
            })
            .collect()
    }

    /// Positions whose stats are needed, biggest reach first.
    pub fn pending_positions(&self, tree: &RepertoireTree) -> Vec<(Epd, f64)> {
        let mut best: HashMap<&Epd, f64> = HashMap::new();
        for (&id, c) in &self.info {
            if c.status != Status::Pending || !c.counts {
                continue;
            }
            let (Some(node), Some(r)) = (tree.get(id), c.reach) else {
                continue;
            };
            let entry = best.entry(&node.epd).or_insert(0.0);
            *entry = entry.max(r);
        }
        let mut result: Vec<(Epd, f64)> = best.into_iter().map(|(e, r)| (e.clone(), r)).collect();
        // Ties by EPD, so the order is stable.
        result.sort_by(|a, b| b.1.total_cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
        result
    }

    /// All gaps, biggest first.
    pub fn gaps(&self) -> Vec<CoverageGap> {
        let mut result: Vec<CoverageGap> = self
            .info
            .values()
            .filter(|c| c.counts)
            .flat_map(|c| c.local_gaps.iter().cloned())
            .collect();
        result.sort_by(|a, b| b.mass.total_cmp(&a.mass).then(a.node.cmp(&b.node)));
        result
    }

    // Computation

    fn mode(&self, id: NodeId, tree: &RepertoireTree) -> Mode {
        let mut cursor = id;
        while let Some(node) = tree.get(cursor)
            && let Some(parent) = node.parent
            && let Some(p) = tree.get(parent)
        {
            if p.side_to_move() == self.settings.color && p.children.first() != Some(&cursor) {
                return Mode::Alternative;
            }
            cursor = parent;
        }
        Mode::Normal
    }

    /// Sets reach and mode below `id`, then aggregates each node after its children, in the
    /// order a recursive depth-first walk would. A work stack, because lines can be very long.
    fn compute_subtree(
        &mut self,
        id: NodeId,
        reach: Option<f64>,
        mode: Mode,
        tree: &RepertoireTree,
        stats: &dyn StatsSource,
    ) {
        // Each frame: the node, its reach and mode, and the next child to visit.
        let mut stack: Vec<(&RepertoireNode, Option<f64>, Mode, usize)> = Vec::new();
        if let Some(node) = tree.get(id) {
            self.enter(node, reach, mode);
            stack.push((node, reach, mode, 0));
        }
        while let Some((node, reach, mode, next)) = stack.last_mut() {
            let (node, reach, mode) = (*node, *reach, *mode);
            let Some(&child) = node.children.get(*next) else {
                stack.pop();
                self.aggregate(node.id, tree, stats);
                continue;
            };
            let index = *next;
            *next += 1;
            let Some(child_node) = tree.get(child) else {
                continue;
            };
            let Some(mv) = child_node.mv.as_ref() else {
                continue;
            };
            let opponent_to_move = node.side_to_move() != self.settings.color;
            let child_reach = if opponent_to_move {
                let node_stats = stats.stats(&node.epd);
                match (reach, node_stats) {
                    (Some(r), Some(s)) => Some(r * s.share(&mv.uci)),
                    _ => None,
                }
            } else {
                reach
            };
            let child_mode = if mode == Mode::Alternative || (!opponent_to_move && index > 0) {
                Mode::Alternative
            } else {
                Mode::Normal
            };
            self.enter(child_node, child_reach, child_mode);
            stack.push((child_node, child_reach, child_mode, 0));
        }
    }

    fn enter(&mut self, node: &RepertoireNode, reach: Option<f64>, mode: Mode) {
        let c = self.info.entry(node.id).or_default();
        c.reach = reach;
        c.counts = mode == Mode::Normal;
    }

    fn refresh_ancestors(&mut self, id: NodeId, tree: &RepertoireTree, stats: &dyn StatsSource) {
        let mut cursor = tree.get(id).and_then(|n| n.parent);
        while let Some(c) = cursor {
            self.aggregate(c, tree, stats);
            cursor = tree.get(c).and_then(|n| n.parent);
        }
    }

    /// Recomputes one node from its own data and its children's cached values.
    fn aggregate(&mut self, id: NodeId, tree: &RepertoireTree, stats: &dyn StatsSource) {
        let Some(node) = tree.get(id) else { return };
        let Some(mut c) = self.info.get(&id).cloned() else {
            return;
        };
        let old = c.completion;
        let t = self.settings.threshold();
        self.set_references(id, BTreeSet::new());

        c.local_gaps.clear();
        c.replies.clear();
        c.gap_count = 0;
        c.gap_mass = 0.0;
        c.pending_count = 0;
        c.biggest_gap = None;

        let opponent_to_move = node.side_to_move() != self.settings.color;
        let node_stats = if opponent_to_move {
            stats.stats(&node.epd)
        } else {
            None
        };
        if let Some(s) = node_stats.as_deref() {
            c.replies = self.replies(node, s, c.reach, tree);
        }

        if !c.counts {
            c.status = Status::Alternative;
            c.completion = node
                .children
                .first()
                .and_then(|f| self.info.get(f))
                .map_or(0.0, |i| i.completion);
        } else if c.reach.is_none() {
            c.status = Status::Unknown;
            c.completion = 0.0;
        } else if c.reach.is_some_and(|r| r < t) {
            c.status = Status::BelowTarget;
            c.completion = 1.0;
        } else if let Some(canonical) = node
            .children
            .is_empty()
            .then(|| self.canonical_node(&node.epd, id, tree))
            .flatten()
        {
            // The lines continue at another node with this position (either side to move).
            c.status = Status::Transposition(canonical);
            c.completion = self.info.get(&canonical).map_or(0.0, |i| i.completion);
            self.set_references(id, BTreeSet::from([canonical]));
        } else if !opponent_to_move {
            match node.children.first().and_then(|m| self.info.get(m)) {
                Some(main) => {
                    c.status = Status::Required;
                    c.completion = main.completion;
                    add_child(&mut c, main);
                }
                None => {
                    c.status = Status::Gap;
                    c.completion = 0.0;
                    c.local_gaps = vec![CoverageGap {
                        node: id,
                        kind: GapKind::MissingMove,
                        mass: c.reach.expect("reach known"),
                    }];
                }
            }
        } else if let Some(s) = node_stats {
            c.status = Status::Required;
            for child in &node.children {
                if let Some(ci) = self.info.get(child) {
                    add_child(&mut c, ci);
                }
            }
            let mut weighted = 0.0;
            let mut total_share = 0.0;
            let mut refs = BTreeSet::new();
            if s.total() >= self.settings.min_games {
                for reply in c.replies.iter().filter(|r| r.required) {
                    total_share += reply.share;
                    if reply.child.is_some() {
                        weighted += reply.share * reply.completion;
                    } else if let Some(canonical) = reply.transposes_to {
                        refs.insert(canonical);
                        weighted += reply.share * reply.completion;
                    } else {
                        c.local_gaps.push(CoverageGap {
                            node: id,
                            kind: GapKind::MissingReply {
                                uci: reply.uci.clone(),
                                san: reply.san.clone(),
                            },
                            mass: reply.reach,
                        });
                    }
                }
            }
            self.set_references(id, refs);
            c.completion = if total_share > 0.0 {
                weighted / total_share
            } else {
                1.0
            };
        } else {
            c.status = Status::Pending;
            c.completion = 0.0;
            c.pending_count = 1;
        }

        for gap in &c.local_gaps {
            c.gap_count += 1;
            c.gap_mass += gap.mass;
            if gap.mass > c.biggest_gap.as_ref().map_or(-1.0, |g| g.mass) {
                c.biggest_gap = Some(gap.clone());
            }
        }
        let changed = old != c.completion;
        self.info.insert(id, c);
        if changed && self.referrers.get(&id).is_some_and(|r| !r.is_empty()) {
            self.changed_canonicals.insert(id);
        }
    }

    fn replies(
        &mut self,
        node: &RepertoireNode,
        stats: &ExplorerStats,
        reach: Option<f64>,
        tree: &RepertoireTree,
    ) -> Vec<ReplyInfo> {
        let t = self.settings.threshold();
        let enough = stats.total() >= self.settings.min_games;
        let mut result = Vec::with_capacity(stats.moves.len());
        let mut seen: HashSet<&str> = HashSet::new();
        for m in &stats.moves {
            seen.insert(&m.uci);
            let share = share_of(m.games(), stats.total());
            let r = reach.unwrap_or(0.0) * share;
            let child = tree.child_by_uci(node.id, &m.uci);
            let excluded = child.is_none() && self.settings.is_excluded(&m.uci, &node.epd);
            let required = enough && reach.is_some() && r >= t && !excluded;
            let mut transposes_to = None;
            let mut completion = child
                .and_then(|c| self.info.get(&c))
                .map_or(0.0, |i| i.completion);
            if child.is_none()
                && required
                && let Some(epd) = self.reply_epd(node, &m.uci)
            {
                transposes_to = self.canonical_node(&epd, node.id, tree);
                if let Some(tr) = transposes_to {
                    completion = self.info.get(&tr).map_or(0.0, |i| i.completion);
                }
            }
            result.push(ReplyInfo {
                uci: m.uci.clone(),
                san: m.san.clone(),
                share,
                reach: r,
                required,
                excluded,
                child,
                transposes_to,
                completion,
                games: m.games(),
            });
        }
        for &child_id in &node.children {
            let Some(mv) = tree.get(child_id).and_then(|n| n.mv.as_ref()) else {
                continue;
            };
            if seen.contains(mv.uci.as_str()) {
                continue;
            }
            result.push(ReplyInfo {
                uci: mv.uci.clone(),
                san: mv.san.clone(),
                share: 0.0,
                reach: 0.0,
                required: false,
                excluded: false,
                child: Some(child_id),
                transposes_to: None,
                completion: self.info.get(&child_id).map_or(0.0, |i| i.completion),
                games: 0,
            });
        }
        result
    }

    fn reply_epd(&mut self, node: &RepertoireNode, uci: &str) -> Option<Epd> {
        let key = (node.id, uci.to_owned());
        if let Some(cached) = self.reply_epds.get(&key) {
            return Some(cached.clone());
        }
        let (_, next) = node.position.play_uci(uci)?;
        let epd = next.epd();
        self.reply_epd_nodes
            .entry(epd.clone())
            .or_default()
            .insert(node.id);
        self.reply_epds.insert(key, epd.clone());
        Some(epd)
    }

    /// The node with this position where you have a move, if it is not `id` or above it.
    fn canonical_node(&self, epd: &Epd, id: NodeId, tree: &RepertoireTree) -> Option<NodeId> {
        let mut candidates = tree.nodes_at(epd).to_vec();
        candidates.sort_unstable();
        candidates.into_iter().find(|&candidate| {
            candidate != id
                && tree.get(candidate).is_some_and(|n| !n.children.is_empty())
                && !tree.is_ancestor(candidate, id)
                && self.info.get(&candidate).is_none_or(|i| i.counts)
        })
    }

    fn set_references(&mut self, id: NodeId, canonicals: BTreeSet<NodeId>) {
        if let Some(old) = self.references.remove(&id) {
            for o in old {
                if let Some(r) = self.referrers.get_mut(&o) {
                    r.remove(&id);
                }
            }
        }
        for &c in &canonicals {
            self.referrers.entry(c).or_default().insert(id);
        }
        if !canonicals.is_empty() {
            self.references.insert(id, canonicals);
        }
    }

    /// Re-aggregates nodes that reference a canonical node whose completion changed.
    fn propagate_transpositions(&mut self, tree: &RepertoireTree, stats: &dyn StatsSource) {
        let mut iterations = 0;
        while iterations < 10_000
            && let Some(canonical) = self.changed_canonicals.pop_first()
        {
            iterations += 1;
            let referrers: Vec<NodeId> = self
                .referrers
                .get(&canonical)
                .map(|r| r.iter().copied().collect())
                .unwrap_or_default();
            for referrer in referrers {
                if tree.get(referrer).is_some() {
                    self.aggregate(referrer, tree, stats);
                    self.refresh_ancestors(referrer, tree, stats);
                }
            }
        }
    }

    /// Re-aggregates nodes elsewhere whose transposition status may depend on `epds`.
    fn refresh(
        &mut self,
        epds: &HashSet<Epd>,
        excluding: NodeId,
        tree: &RepertoireTree,
        stats: &dyn StatsSource,
    ) {
        if epds.is_empty() {
            return;
        }
        let mut targets: BTreeSet<NodeId> = BTreeSet::new();
        for epd in epds {
            targets.extend(tree.nodes_at(epd).iter().filter(|&&id| id != excluding));
            // Opponent nodes with a required reply leading into one of these positions.
            if let Some(ids) = self.reply_epd_nodes.get(epd) {
                targets.extend(ids);
            }
        }
        for id in targets {
            if tree.get(id).is_some() && self.info.contains_key(&id) {
                self.aggregate(id, tree, stats);
                self.refresh_ancestors(id, tree, stats);
            }
        }
    }

    /// Drops cached values of deleted nodes.
    fn forget_missing(&mut self, tree: &RepertoireTree) {
        let missing: Vec<NodeId> = self
            .info
            .keys()
            .copied()
            .filter(|&id| tree.get(id).is_none())
            .collect();
        for id in missing {
            self.info.remove(&id);
            self.set_references(id, BTreeSet::new());
            self.referrers.remove(&id);
        }
    }
}

fn share_of(games: i64, total: i64) -> f64 {
    if total > 0 {
        games as f64 / total as f64
    } else {
        0.0
    }
}

fn add_child(c: &mut NodeCoverage, child: &NodeCoverage) {
    if !child.counts {
        return;
    }
    c.gap_count += child.gap_count;
    c.gap_mass += child.gap_mass;
    c.pending_count += child.pending_count;
    if let Some(g) = &child.biggest_gap
        && g.mass > c.biggest_gap.as_ref().map_or(-1.0, |b| b.mass)
    {
        c.biggest_gap = Some(g.clone());
    }
}
