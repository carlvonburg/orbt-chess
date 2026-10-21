//! Snapshots of the coverage engine on the PGNs in tests/data/pgn (every node) and on the real
//! repertoires in testData/ (a summary). Stats come from `common::tree_stats` (the tree's own
//! moves, so replies are covered) or `common::synthetic_stats` (other moves, so replies are
//! gaps), with one position in five left without stats (pending). After an intended change,
//! review the new snapshots with `cargo insta review`.

mod common;

use std::collections::{BTreeMap, HashMap};
use std::fmt::Write;

use common::num;
use ot_core::chess::{Epd, Side};
use ot_core::coverage::{CoverageEngine, CoverageGap, CoverageSettings, GapKind, Status};
use ot_core::explorer::ExplorerStats;
use ot_core::repertoire::RepertoireTree;

fn status(s: &Status) -> String {
    match s {
        Status::Transposition(t) => format!("transposition({t})"),
        other => format!("{other:?}").to_lowercase(),
    }
}

fn gap(tree: &RepertoireTree, g: &CoverageGap) -> String {
    let what = match &g.kind {
        GapKind::MissingMove => "your move".to_owned(),
        GapKind::MissingReply { san, .. } => format!("reply {san}"),
    };
    let line = tree.path(g.node);
    format!(
        "{what} after [{}] mass {} seen every {}",
        common::line_san(tree, &line),
        num(g.mass),
        g.seen_every()
    )
}

/// Coverage target "seen once in `target` games", from positions with `min_games` games.
fn engine(
    tree: &RepertoireTree,
    color: Side,
    stats: &HashMap<Epd, ExplorerStats>,
    (target, min_games): (i64, i64),
) -> CoverageEngine {
    let mut engine = CoverageEngine::new(CoverageSettings::new(color, target, min_games));
    engine.recompute_all(tree, stats);
    engine
}

/// One block per node in id order: status and numbers, then its replies.
fn every_node(tree: &RepertoireTree, engine: &CoverageEngine) -> String {
    let mut out = String::new();
    for n in tree.nodes() {
        let Some(c) = engine.info().get(&n.id) else {
            continue;
        };
        let san = n.mv.as_ref().map_or("root", |m| m.san.as_str());
        writeln!(
            out,
            "{} {san}: {} reach {} completion {} gaps {} (mass {}) pending {} seen every {}{}",
            n.id,
            status(&c.status),
            c.reach.map_or("-".into(), num),
            num(c.completion),
            c.gap_count,
            num(c.gap_mass),
            c.pending_count,
            c.seen_every().map_or("-".into(), |n| n.to_string()),
            if c.counts { "" } else { " (not counted)" },
        )
        .unwrap();
        for r in &c.replies {
            let mut flags = Vec::new();
            if r.required {
                flags.push("required".to_owned());
            }
            if r.excluded {
                flags.push("excluded".to_owned());
            }
            if let Some(child) = r.child {
                flags.push(format!("child {child}"));
            }
            if let Some(t) = r.transposes_to {
                flags.push(format!("transposes to {t}"));
            }
            writeln!(
                out,
                "    {} share {} reach {} completion {} games {} {}",
                r.san,
                num(r.share),
                num(r.reach),
                num(r.completion),
                r.games,
                flags.join(", ")
            )
            .unwrap();
        }
    }
    out
}

/// The root, the counts by status, the biggest gaps and pending positions.
fn summary(tree: &RepertoireTree, engine: &CoverageEngine) -> String {
    let mut out = String::new();
    if let Some(root) = engine.root() {
        writeln!(
            out,
            "root: completion {} gaps {} (mass {}) pending {}",
            num(root.completion),
            root.gap_count,
            num(root.gap_mass),
            root.pending_count
        )
        .unwrap();
    }
    let mut by_status: BTreeMap<String, usize> = BTreeMap::new();
    for c in engine.info().values() {
        let s = match c.status {
            Status::Transposition(_) => "transposition".to_owned(),
            ref s => status(s),
        };
        *by_status.entry(s).or_default() += 1;
    }
    writeln!(out, "nodes by status: {by_status:?}").unwrap();
    let gaps = engine.gaps();
    writeln!(out, "{} gaps, the biggest:", gaps.len()).unwrap();
    for g in gaps.iter().take(25) {
        writeln!(out, "  {}", gap(tree, g)).unwrap();
    }
    let pending = engine.pending_positions(tree);
    writeln!(
        out,
        "{} pending positions, the most reached:",
        pending.len()
    )
    .unwrap();
    for (epd, reach) in pending.iter().take(10) {
        writeln!(out, "  {} {}", num(*reach), epd.as_str()).unwrap();
    }
    out
}

fn schemes(tree: &RepertoireTree) -> [(&'static str, HashMap<Epd, ExplorerStats>); 2] {
    [
        ("tree_stats", common::with_missing(common::tree_stats(tree))),
        (
            "synthetic",
            common::with_missing(common::synthetic_stats(tree)),
        ),
    ]
}

#[test]
fn small_pgns() {
    for (name, text) in common::small_pgns() {
        let tree = RepertoireTree::from_pgn(&text);
        for (scheme, stats) in schemes(&tree) {
            for color in [Side::White, Side::Black] {
                let e = engine(&tree, color, &stats, (40, 50));
                let text = format!("{}\n{}", summary(&tree, &e), every_node(&tree, &e));
                insta::assert_snapshot!(format!("{name}.{scheme}.{color:?}"), text);
            }
        }
    }
}

#[test]
fn real_repertoires() {
    for name in common::REPERTOIRES {
        let tree = RepertoireTree::from_pgn(&common::repertoire(name));
        for (scheme, stats) in schemes(&tree) {
            // The app's defaults for a new repertoire.
            let e = engine(&tree, Side::Black, &stats, (500, 25));
            insta::assert_snapshot!(format!("{name}.{scheme}"), summary(&tree, &e));
        }
    }
}
