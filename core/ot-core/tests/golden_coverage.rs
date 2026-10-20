//! The Rust coverage engine against the Swift core's fixtures.

mod common;
mod golden;

use std::collections::{BTreeSet, HashMap, HashSet};

use ot_core::chess::{Epd, Side};
use ot_core::coverage::{
    CoverageEngine, CoverageGap, CoverageSettings, GapKind, NodeCoverage, ReplyInfo, StatsSource,
    Status,
};
use ot_core::explorer::ExplorerStats;
use ot_core::repertoire::RepertoireTree;
use serde_json::{Value, json};

/// Doubles come out of the same operations in the same order, so they should match exactly;
/// allow for the last bit only.
const TOL: f64 = 1e-12;

fn gap_json(g: &CoverageGap) -> Value {
    let kind = match &g.kind {
        GapKind::MissingMove => json!({"kind": "missingMove"}),
        GapKind::MissingReply { uci, san } => {
            json!({"kind": "missingReply", "uci": uci, "san": san})
        }
    };
    json!({"node": g.node, "kind": kind, "mass": g.mass, "seenEvery": g.seen_every()})
}

fn reply_json(r: &ReplyInfo) -> Value {
    json!({
        "uci": r.uci, "san": r.san, "share": r.share, "reach": r.reach, "required": r.required,
        "excluded": r.excluded, "child": r.child, "transposesTo": r.transposes_to,
        "completion": r.completion, "games": r.games,
    })
}

fn node_json(c: &NodeCoverage) -> Value {
    let status = match c.status {
        Status::Required => json!({"kind": "required"}),
        Status::BelowTarget => json!({"kind": "belowTarget"}),
        Status::Pending => json!({"kind": "pending"}),
        Status::Unknown => json!({"kind": "unknown"}),
        Status::Gap => json!({"kind": "gap"}),
        Status::Transposition(t) => json!({"kind": "transposition", "target": t}),
        Status::Alternative => json!({"kind": "alternative"}),
    };
    json!({
        "reach": c.reach, "status": status, "completion": c.completion, "gapCount": c.gap_count,
        "gapMass": c.gap_mass, "pendingCount": c.pending_count,
        "biggestGap": c.biggest_gap.as_ref().map(gap_json),
        "localGaps": c.local_gaps.iter().map(gap_json).collect::<Vec<_>>(),
        "replies": c.replies.iter().map(reply_json).collect::<Vec<_>>(),
        "counts": c.counts, "seenEvery": c.seen_every(),
    })
}

fn engine_json(engine: &CoverageEngine, tree: &RepertoireTree) -> Value {
    let nodes: serde_json::Map<String, Value> = engine
        .info()
        .iter()
        .map(|(id, c)| (id.to_string(), node_json(c)))
        .collect();
    json!({
        "nodes": nodes,
        "root": engine.root().map(node_json),
        "gaps": engine.gaps().iter().map(gap_json).collect::<Vec<_>>(),
        "pendingPositions": engine.pending_positions(tree).iter()
            .map(|(e, r)| json!({"epd": e.as_str(), "reach": r})).collect::<Vec<_>>(),
    })
}

fn settings(v: &Value) -> CoverageSettings {
    let color = if v["color"] == "white" {
        Side::White
    } else {
        Side::Black
    };
    let mut s = CoverageSettings::new(
        color,
        v["targetGames"].as_i64().unwrap(),
        v["minGames"].as_i64().unwrap(),
    );
    for (epd, moves) in v["excluded"].as_object().unwrap() {
        let set: BTreeSet<String> = moves
            .as_array()
            .unwrap()
            .iter()
            .map(|m| m.as_str().unwrap().to_owned())
            .collect();
        s.excluded.insert(Epd::new(epd.as_str()), set);
    }
    s
}

/// The lookups the Swift engine made, keyed by the Rust EPDs (a few Semi-Slav positions have
/// a different key in Swift; see legacy_epds).
fn stats_map(v: &Value, tree: &RepertoireTree) -> HashMap<Epd, ExplorerStats> {
    let mut map: HashMap<Epd, ExplorerStats> = v
        .as_object()
        .unwrap()
        .iter()
        .filter(|(_, s)| !s.is_null())
        .map(|(e, s)| {
            (
                Epd::new(e.as_str()),
                serde_json::from_value(s.clone()).unwrap(),
            )
        })
        .collect();
    for (id, legacy) in tree.legacy_epds() {
        if let Some(s) = map.get(&legacy).cloned() {
            map.insert(tree[id].epd.clone(), s);
        }
    }
    map
}

fn check_recompute(label: &str, tree: &RepertoireTree, fixture: &Value) {
    let mut engine = CoverageEngine::new(settings(&fixture["settings"]));
    engine.recompute_all(tree, &stats_map(&fixture["stats"], tree));
    let mut expected = json!({
        "nodes": fixture["nodes"], "root": fixture["root"],
        "gaps": fixture["gaps"], "pendingPositions": fixture["pendingPositions"],
    });
    let mut actual = engine_json(&engine, tree);
    // Pending positions are keyed by EPD; drop the few with Swift-only keys from both sides.
    let legacy: HashSet<String> = tree
        .legacy_epds()
        .values()
        .map(|e| e.as_str().to_owned())
        .collect();
    let renamed: HashSet<String> = tree
        .legacy_epds()
        .keys()
        .map(|&id| tree[id].epd.as_str().to_owned())
        .collect();
    for (v, skip) in [(&mut expected, &legacy), (&mut actual, &renamed)] {
        v["pendingPositions"]
            .as_array_mut()
            .unwrap()
            .retain(|p| !skip.contains(p["epd"].as_str().unwrap()));
    }
    golden::assert_same(label, &expected, &actual, TOL);
}

#[test]
fn recompute_matches_swift_for_every_input_and_scheme() {
    let mut checked = 0;
    for name in golden::inputs() {
        let tree = RepertoireTree::from_pgn(&golden::text(&format!("inputs/{name}.pgn")));
        for scheme in [
            "synthetic",
            "synthetic_missing",
            "treestats",
            "treestats_missing",
        ] {
            for color in ["white", "black"] {
                let label = format!("{name}.{scheme}.{color}");
                let fixture = golden::json(&format!("coverage/{label}.json"));
                check_recompute(&label, &tree, &fixture);
                checked += 1;
            }
        }
    }
    assert_eq!(checked, golden::inputs().len() * 8);
}

#[test]
fn hand_fixtures_match_swift() {
    let hand = golden::json("coverage/hand.json");
    for (name, case) in hand.as_object().unwrap() {
        if name == "replies_at_unsaved" {
            let engine = CoverageEngine::new(settings(&case["settings"]));
            let stats: ExplorerStats = serde_json::from_value(case["stats"].clone()).unwrap();
            let replies = engine.draft_replies(
                &Epd::new(case["epd"].as_str().unwrap()),
                &stats,
                case["reach"].as_f64(),
            );
            let actual = json!(replies.iter().map(reply_json).collect::<Vec<_>>());
            golden::assert_same(name, &case["replies"], &actual, TOL);
            continue;
        }
        let tree = tree_from_json(&case["tree"]);
        // Same moves; a tree built move by move gets default tags, so compare the movetext.
        assert!(
            tree.pgn_text().ends_with(case["pgnText"].as_str().unwrap()),
            "{name}"
        );
        check_recompute(name, &tree, &case["coverage"]);
    }
}

/// Rebuilds a fixture tree with the same node ids (adding nodes in id order assigns them).
fn tree_from_json(v: &Value) -> RepertoireTree {
    let mut tree = RepertoireTree::default();
    for node in v["nodes"].as_array().unwrap().iter().skip(1) {
        let parent = node["parent"].as_u64().unwrap() as u32;
        let added = tree.add_move(node["uci"].as_str().unwrap(), parent);
        assert_eq!(json!(added), node["id"], "fixture tree ids must be dense");
    }
    tree
}

struct Synthetic<'a> {
    cache: &'a HashMap<Epd, Option<ExplorerStats>>,
    missing: &'a HashSet<Epd>,
}

impl StatsSource for Synthetic<'_> {
    fn stats(&self, epd: &Epd) -> Option<&ExplorerStats> {
        if self.missing.contains(epd) {
            return None;
        }
        self.cache.get(epd).and_then(Option::as_ref)
    }
}

fn warm(cache: &mut HashMap<Epd, Option<ExplorerStats>>, tree: &RepertoireTree) {
    for node in tree.nodes() {
        cache
            .entry(node.epd.clone())
            .or_insert_with(|| common::make_synthetic(&node.epd));
    }
}

fn epds(v: &Value) -> HashSet<Epd> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|e| Epd::new(e.as_str().unwrap()))
        .collect()
}

#[test]
fn incremental_updates_replay_like_swift() {
    for color in ["white", "black"] {
        for seed in 1..=3 {
            let label = format!("incremental.{color}.{seed}");
            let fixture = golden::json(&format!("coverage/{label}.json"));
            let mut tree = RepertoireTree::default();
            let mut engine = CoverageEngine::new(settings(&fixture["settings"]));
            let mut cache = HashMap::new();
            let mut missing: HashSet<Epd> = HashSet::new();
            warm(&mut cache, &tree);
            engine.recompute_all(
                &tree,
                &Synthetic {
                    cache: &cache,
                    missing: &missing,
                },
            );
            for op in fixture["ops"].as_array().unwrap() {
                let step = &op["step"];
                let id = |k: &str| op[k].as_u64().unwrap() as u32;
                match op["op"].as_str().unwrap() {
                    "addMove" => {
                        let added = tree.add_move(op["uci"].as_str().unwrap(), id("after"));
                        assert_eq!(json!(added), op["added"], "{label} step {step}");
                        if op["missingInserted"] == true {
                            missing.insert(tree[added.unwrap()].epd.clone());
                        }
                        warm(&mut cache, &tree);
                        engine.update(
                            id("after"),
                            &epds(&op["updateEPDs"]),
                            &tree,
                            &Synthetic {
                                cache: &cache,
                                missing: &missing,
                            },
                        );
                    }
                    "delete" => {
                        tree.delete(id("id"));
                        engine.update(
                            id("changedAt"),
                            &epds(&op["updateEPDs"]),
                            &tree,
                            &Synthetic {
                                cache: &cache,
                                missing: &missing,
                            },
                        );
                    }
                    "promote" => {
                        tree.promote(id("id"));
                        engine.update(
                            id("changedAt"),
                            &epds(&op["updateEPDs"]),
                            &tree,
                            &Synthetic {
                                cache: &cache,
                                missing: &missing,
                            },
                        );
                    }
                    "statsArrived" => {
                        let epd = Epd::new(op["epd"].as_str().unwrap());
                        missing.remove(&epd);
                        let changed = engine.stats_arrived(
                            &epd,
                            &tree,
                            &Synthetic {
                                cache: &cache,
                                missing: &missing,
                            },
                        );
                        assert_eq!(json!(changed), op["changed"], "{label} step {step}");
                    }
                    other => panic!("unknown op {other}"),
                }
                assert_eq!(missing, epds(&op["missing"]), "{label} step {step} missing");
                golden::assert_same(
                    &format!("{label} step {step} root"),
                    &op["root"],
                    &json!(engine.root().map(node_json)),
                    TOL,
                );
            }
            let fin = &fixture["final"];
            let expected = json!({"nodes": fin["nodes"], "root": fin["root"], "gaps": fin["gaps"],
                "pendingPositions": fin["pendingPositions"]});
            golden::assert_same(
                &format!("{label} final"),
                &expected,
                &engine_json(&engine, &tree),
                TOL,
            );
        }
    }
}
