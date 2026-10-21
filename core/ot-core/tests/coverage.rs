//! Ported from CoverageTests.swift and the coverage part of TranspositionTests.swift.

mod common;

use std::collections::{BTreeSet, HashMap, HashSet};

use common::{FixtureStats, Rng, TreeExt, make_synthetic};
use ot_core::chess::{Epd, Side};
use ot_core::coverage::{CoverageEngine, CoverageSettings, GapKind, StatsSource, Status};
use ot_core::explorer::{ExplorerDatabase, ExplorerStats};
use ot_core::formats::{Sidecar, Timestamp};
use ot_core::repertoire::RepertoireTree;

fn close(a: f64, b: f64) -> bool {
    (a - b).abs() < 1e-9
}

fn fixture() -> (RepertoireTree, FixtureStats) {
    let mut tree = RepertoireTree::default();
    tree.add("e4 c5 Nf3 d6 d4 cxd4 Nxd4");
    tree.add("e4 e5 Nf3");
    let mut stats = FixtureStats::default();
    stats.set("e4", &[("c5", 500), ("e5", 300), ("e6", 150), ("c6", 50)]);
    stats.set("e4 c5 Nf3", &[("d6", 600), ("Nc6", 400)]);
    stats.set("e4 c5 Nf3 d6 d4", &[("cxd4", 1000)]);
    stats.set("e4 c5 Nf3 d6 d4 cxd4 Nxd4", &[("Nf6", 5)]); // below minGames
    (tree, stats)
}

fn white(target: i64, min: i64) -> CoverageEngine {
    CoverageEngine::new(CoverageSettings::new(Side::White, target, min))
}

#[test]
fn completion_gaps_and_pending() {
    let (tree, stats) = fixture();
    let mut engine = white(10, 10);
    engine.recompute_all(&tree, &stats.by_epd);
    let root = engine.root().unwrap();
    assert!(close(root.completion, 0.3 / 0.95));
    assert_eq!(root.gap_count, 2);
    assert!(close(root.gap_mass, 0.35));
    assert_eq!(root.pending_count, 1);
    assert_eq!(
        root.biggest_gap.as_ref().unwrap().kind,
        GapKind::MissingReply {
            uci: "b8c6".into(),
            san: "Nc6".into()
        }
    );
    let nf3 = tree.find("e4 c5 Nf3").unwrap();
    assert!(close(engine.get(nf3).unwrap().completion, 0.6));
    let sans: Vec<&str> = engine
        .get(nf3)
        .unwrap()
        .replies
        .iter()
        .map(|r| r.san.as_str())
        .collect();
    assert_eq!(sans, ["d6", "Nc6"]);
    assert_eq!(
        engine.get(tree.find("e4 e5 Nf3").unwrap()).unwrap().status,
        Status::Pending
    );
    assert_eq!(engine.pending_positions(&tree).len(), 1);
    let e4 = engine.get(tree.find("e4").unwrap()).unwrap();
    assert!(!e4.replies.iter().find(|r| r.san == "c6").unwrap().required);
    let seen: Vec<i64> = engine.gaps().iter().map(|g| g.seen_every()).collect();
    assert_eq!(seen, [5, 7]);
}

#[test]
fn min_games_follows_the_database() {
    // What the offline tables are built for: Classical stops below 10 games, Lichess below 25.
    let mut sidecar = Sidecar::new("id".into(), Side::White, Timestamp(0));
    assert_eq!(sidecar.coverage_settings().min_games, 25);
    sidecar.database = ExplorerDatabase::Otb {
        ratings: vec![1600],
    };
    assert_eq!(sidecar.coverage_settings().min_games, 10);
    sidecar.database = ExplorerDatabase::masters();
    assert_eq!(sidecar.coverage_settings().min_games, 25);
}

#[test]
fn excluded_replies_are_not_gaps() {
    let (mut tree, mut stats) = fixture();
    let mut engine = white(10, 10);
    engine.recompute_all(&tree, &stats.by_epd);
    let e4 = tree.find("e4").unwrap();
    let epd = tree[e4].epd.clone();

    engine.settings.excluded = HashMap::from([(epd.clone(), BTreeSet::from(["e7e6".to_owned()]))]);
    engine.exclusions_changed(&epd, &tree, &stats.by_epd);
    assert_eq!(engine.root().unwrap().gap_count, 1);
    assert!(close(engine.root().unwrap().completion, 0.3 / 0.8));
    let e6 = engine
        .get(e4)
        .unwrap()
        .replies
        .iter()
        .find(|r| r.san == "e6")
        .unwrap()
        .clone();
    assert!(e6.excluded && !e6.required);

    // A move you save anyway is covered as usual.
    let leaf = tree.add("e4 e6 d4");
    stats.set("e4 e6 d4", &[("d5", 5)]);
    engine.update(
        e4,
        &HashSet::from([tree[leaf].epd.clone()]),
        &tree,
        &stats.by_epd,
    );
    assert!(
        !engine
            .get(e4)
            .unwrap()
            .replies
            .iter()
            .find(|r| r.san == "e6")
            .unwrap()
            .excluded
    );
    assert!(close(engine.root().unwrap().completion, 0.45 / 0.95));

    engine.settings.excluded.clear();
    engine.exclusions_changed(&epd, &tree, &stats.by_epd);
    assert_eq!(engine.root().unwrap().gap_count, 1);
}

#[test]
fn replies_at_unsaved_position() {
    let (tree, stats) = fixture();
    let mut engine = white(10, 10);
    engine.recompute_all(&tree, &stats.by_epd);
    let epd = tree[tree.find("e4").unwrap()].epd.clone();
    engine.settings.excluded = HashMap::from([(epd.clone(), BTreeSet::from(["c7c6".to_owned()]))]);
    let replies = engine.draft_replies(&epd, stats.lookup(&epd).unwrap(), Some(0.5));
    let sans: Vec<&str> = replies.iter().map(|r| r.san.as_str()).collect();
    assert_eq!(sans, ["c5", "e5", "e6", "c6"]);
    let required: Vec<bool> = replies.iter().map(|r| r.required).collect();
    assert_eq!(required, [true, true, false, false]);
    assert!(close(replies[1].reach, 0.15));
    assert!(replies[3].excluded && replies.iter().all(|r| r.child.is_none()));
}

#[test]
fn incremental_add_and_stats_arrival() {
    let (mut tree, mut stats) = fixture();
    let mut engine = white(10, 10);
    engine.recompute_all(&tree, &stats.by_epd);

    stats.set("e4 e5 Nf3", &[("Nc6", 1000)]);
    let e5nf3 = tree.find("e4 e5 Nf3").unwrap();
    let epd = tree[e5nf3].epd.clone();
    assert!(engine.stats_arrived(&epd, &tree, &stats.by_epd));
    assert_eq!(engine.root().unwrap().gap_count, 3);
    assert_eq!(engine.root().unwrap().pending_count, 0);
    // The same answer again changes nothing.
    assert!(!engine.stats_arrived(&epd, &tree, &stats.by_epd));

    stats.set("e4 e5 Nf3 Nc6 Bb5", &[("a6", 5)]);
    let leaf = tree.add("e4 e5 Nf3 Nc6 Bb5");
    engine.update(
        e5nf3,
        &HashSet::from([tree[leaf].epd.clone()]),
        &tree,
        &stats.by_epd,
    );
    assert!(close(engine.root().unwrap().completion, 0.6 / 0.95));
    assert_eq!(engine.root().unwrap().gap_count, 2);
}

#[test]
fn transposition_counts_as_covered() {
    let mut tree = RepertoireTree::default();
    tree.add("d4 Nf6 c4 e6 Nc3");
    tree.add("d4 e6 c4 Nf6");
    let mut stats = FixtureStats::default();
    stats.set("d4", &[("Nf6", 50), ("e6", 50)]);
    stats.set("d4 Nf6 c4", &[("e6", 100)]);
    stats.set("d4 Nf6 c4 e6 Nc3", &[("Bb4", 5)]);
    stats.set("d4 e6 c4", &[("Nf6", 100)]);
    let mut engine = white(10, 10);
    engine.recompute_all(&tree, &stats.by_epd);
    let transposed = tree.find("d4 e6 c4 Nf6").unwrap();
    let canonical = tree.find("d4 Nf6 c4 e6").unwrap();
    assert_eq!(
        engine.get(transposed).unwrap().status,
        Status::Transposition(canonical)
    );
    assert_eq!(engine.root().unwrap().gap_count, 0);
}

#[test]
fn below_target_lines_require_nothing() {
    let mut tree = RepertoireTree::default();
    tree.add("e4 c6");
    let mut stats = FixtureStats::default();
    stats.set("e4", &[("c5", 990), ("c6", 10)]);
    let mut engine = white(50, 10);
    engine.recompute_all(&tree, &stats.by_epd);
    assert_eq!(
        engine.get(tree.find("e4 c6").unwrap()).unwrap().status,
        Status::BelowTarget
    );
    assert_eq!(engine.root().unwrap().gap_count, 1); // c5 is missing
}

#[test]
fn opponent_to_move_leaf_counts_as_covered() {
    // Black repertoire: after 1. d4 d5 2. c4 c6 3. Nf3 Nf6 it is White's move.
    let tree = RepertoireTree::from_pgn(
        "1. d4 d5 2. c4 (2. Nf3 Nf6 3. c4 c6 4. Nc3 (4. e3 Bf5) e6) c6 3. Nf3 Nf6 4. Nc3 e6 *",
    );
    let other = tree.find("d4 d5 Nf3 Nf6 c4 c6").unwrap();
    let main = tree.find("d4 d5 c4 c6 Nf3 Nf6").unwrap();
    let mut stats = FixtureStats::default();
    stats.set("", &[("d4", 100)]);
    stats.set("d4 d5", &[("c4", 50), ("Nf3", 50)]);
    stats.set("d4 d5 Nf3 Nf6", &[("c4", 100)]);
    let mut engine = CoverageEngine::new(CoverageSettings::new(Side::Black, 10, 1));
    engine.recompute_all(&tree, &stats.by_epd);
    assert_eq!(
        engine.get(other).unwrap().status,
        Status::Transposition(main)
    );
    assert_eq!(engine.get(other).unwrap().pending_count, 0);
}

// CoveragePropertyTests: incremental results must equal a full recompute after any edits.

/// Synthetic stats with some positions not fetched yet.
struct Synthetic<'a> {
    cache: &'a HashMap<Epd, Option<ExplorerStats>>,
    missing: &'a BTreeSet<Epd>,
}

impl StatsSource for Synthetic<'_> {
    fn stats(&self, epd: &Epd) -> Option<std::borrow::Cow<'_, ExplorerStats>> {
        if self.missing.contains(epd) {
            return None;
        }
        self.cache
            .get(epd)
            .and_then(Option::as_ref)
            .map(std::borrow::Cow::Borrowed)
    }
}

fn warm(cache: &mut HashMap<Epd, Option<ExplorerStats>>, tree: &RepertoireTree) {
    for node in tree.nodes() {
        cache
            .entry(node.epd.clone())
            .or_insert_with(|| make_synthetic(&node.epd));
    }
}

fn incremental_equals_full(color: Side, seed: u64) {
    let mut rng = Rng(seed);
    let mut tree = RepertoireTree::default();
    let mut missing: BTreeSet<Epd> = BTreeSet::new();
    let mut cache: HashMap<Epd, Option<ExplorerStats>> = HashMap::new();
    let settings = CoverageSettings::new(color, 40, 50);
    let mut engine = CoverageEngine::new(settings.clone());
    warm(&mut cache, &tree);
    engine.recompute_all(
        &tree,
        &Synthetic {
            cache: &cache,
            missing: &missing,
        },
    );

    for step in 0..120 {
        let mut ids: Vec<u32> = tree.nodes().map(|n| n.id).collect();
        ids.sort();
        let target = ids[(rng.next_u64() % ids.len() as u64) as usize];
        let action = rng.next_u64() % 10;
        if action < 7 {
            // add a move: prefer explorer moves so lines stay in the required region
            let epd = tree[target].epd.clone();
            let options: Vec<String> = cache
                .entry(epd.clone())
                .or_insert_with(|| make_synthetic(&epd))
                .as_ref()
                .map(|s| s.moves.iter().map(|m| m.uci.clone()).collect())
                .unwrap_or_default();
            if options.is_empty() {
                continue;
            }
            let uci = &options[(rng.next_u64() % options.len() as u64) as usize];
            let Some(added) = tree.add_move(uci, target) else {
                continue;
            };
            let added_epd = tree[added].epd.clone();
            if rng.next_u64().is_multiple_of(4) {
                missing.insert(added_epd.clone());
            }
            warm(&mut cache, &tree);
            engine.update(
                target,
                &HashSet::from([added_epd]),
                &tree,
                &Synthetic {
                    cache: &cache,
                    missing: &missing,
                },
            );
        } else if action == 7 && tree[target].ply >= 3 {
            let parent = tree[target].parent.unwrap();
            let removed: HashSet<Epd> = tree
                .subtree(target)
                .iter()
                .map(|&n| tree[n].epd.clone())
                .collect();
            tree.delete(target);
            engine.update(
                parent,
                &removed,
                &tree,
                &Synthetic {
                    cache: &cache,
                    missing: &missing,
                },
            );
        } else if action == 8 && target != RepertoireTree::ROOT {
            let parent = tree[target].parent.unwrap();
            let affected: HashSet<Epd> = tree
                .subtree(parent)
                .iter()
                .map(|&n| tree[n].epd.clone())
                .collect();
            tree.promote(target);
            engine.update(
                parent,
                &affected,
                &tree,
                &Synthetic {
                    cache: &cache,
                    missing: &missing,
                },
            );
        } else if let Some(epd) = missing.pop_first() {
            engine.stats_arrived(
                &epd,
                &tree,
                &Synthetic {
                    cache: &cache,
                    missing: &missing,
                },
            );
        }

        let mut full = CoverageEngine::new(settings.clone());
        full.recompute_all(
            &tree,
            &Synthetic {
                cache: &cache,
                missing: &missing,
            },
        );
        for node in tree.nodes() {
            let id = node.id;
            let a = engine
                .get(id)
                .unwrap_or_else(|| panic!("step {step} node {id} missing"));
            let b = full.get(id).unwrap();
            assert_eq!(a.status, b.status, "step {step} node {id}");
            assert!(close(a.completion, b.completion), "step {step} node {id}");
            assert_eq!(a.gap_count, b.gap_count, "step {step} node {id}");
            assert_eq!(a.pending_count, b.pending_count, "step {step} node {id}");
        }
    }
    assert!(tree.count() > 10);
}

#[test]
fn incremental_equals_full_all_seeds() {
    for color in [Side::White, Side::Black] {
        for seed in 1..=3 {
            incremental_equals_full(color, seed);
        }
    }
}
