//! Card ids, sidecars, review logs and tree edits against the fixtures.

mod golden;

use std::collections::HashSet;

use ot_core::chess::Epd;
use ot_core::formats::{Sidecar, revlog};
use ot_core::repertoire::RepertoireTree;
use ot_core::training::anki::{Card, DeckConfig, SchedTiming};
use serde_json::{Value, json};

#[test]
fn card_ids_match_swift() {
    let fixture = golden::json("misc/card_ids.json");
    let rows = fixture["cardIDs"].as_array().unwrap();
    assert!(rows.len() > 100);
    for row in rows {
        let epd = Epd::new(row["epd"].as_str().unwrap());
        assert_eq!(json!(Card::id_for(&epd)), row["id"], "{epd}");
    }
}

const SIDECARS: [&str; 6] = [
    "minimal",
    "full",
    "masters",
    "other",
    "full_merged_other",
    "full_synced",
];

fn sidecar(name: &str) -> (Value, Sidecar) {
    let bytes = golden::bytes(&format!("misc/sidecar_{name}.otrep.json"));
    let s = Sidecar::decode(&bytes).unwrap_or_else(|e| panic!("{name}: {e}"));
    let mut value: Value = serde_json::from_slice(&bytes).unwrap();
    // Dropped from the summary since the fixtures were recorded.
    if let Some(summary) = value.get_mut("summary").and_then(Value::as_object_mut) {
        summary.remove("computedAt");
    }
    (value, s)
}

/// The sidecar's JSON, compared as values: the fixtures use Foundation's formatting.
fn encoded(s: &Sidecar) -> Value {
    serde_json::from_slice(&s.encoded()).unwrap()
}

#[test]
fn sidecars_round_trip() {
    for name in SIDECARS {
        let (value, s) = sidecar(name);
        golden::assert_same(name, &value, &encoded(&s), 0.0);
        let again = Sidecar::decode(&s.encoded()).unwrap();
        assert!(
            again.encoded() == s.encoded(),
            "{name} re-encodes to the same bytes"
        );
    }
}

#[test]
fn sidecar_merge_sync_and_estimates_match_swift() {
    let (_, full) = sidecar("full");
    let (_, other) = sidecar("other");
    let (merged, _) = sidecar("full_merged_other");
    golden::assert_same("merged", &merged, &encoded(&full.merged(&other)), 0.0);

    let info = golden::json("misc/sidecar_info.json");
    let sync = &info["syncSuspension"];
    let active: HashSet<Epd> = sync["active"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| Epd::new(e.as_str().unwrap()))
        .collect();
    let mut synced = full.clone();
    assert_eq!(json!(synced.sync_suspension(&active)), sync["changed"]);
    let (synced_value, _) = sidecar("full_synced");
    golden::assert_same("synced", &synced_value, &encoded(&synced), 0.0);

    let t = &info["timing"];
    let timing = SchedTiming::new(
        t["daysElapsed"].as_i64().unwrap(),
        t["nextDayAt"].as_i64().unwrap(),
        t["now"].as_i64().unwrap(),
    );
    for name in ["full", "masters", "minimal"] {
        let (value, s) = sidecar(name);
        let e = &info[name];
        let p = s.estimated_progress();
        let c = s.estimated_study_counts(&DeckConfig::default(), &timing);
        let actual = json!({
            "configKey": s.config_key(),
            "databaseCacheKey": s.database.cache_key(),
            "databaseSummary": s.database.summary(),
            "dueTomorrow": s.due_tomorrow(&timing),
            "estimatedProgress": {"cards": p.cards, "learning": p.learning, "mature": p.mature,
                                  "suspended": p.suspended, "young": p.young},
            "estimatedStudyCounts": {"learning": c.learning, "new": c.new, "review": c.review},
            "laterLearningDues": s.later_learning_dues(&timing),
            "nextDue": s.next_due(&timing),
            "roundTripEqual": golden::diff(name, &value, &encoded(&s), 0.0).is_none(),
        });
        golden::assert_same(name, e, &actual, 0.0);
    }
}

#[test]
fn review_logs_round_trip_byte_for_byte() {
    // Each line re-encodes to the same bytes (decode sorts by id, so compare per line).
    for name in [
        "revlog",
        "scheduler",
        "revlog_merged",
        "revlog_unsorted_with_garbage.decoded",
    ] {
        let text = golden::text(&format!("misc/{name}.otlog.jsonl"));
        for line in text.lines() {
            let entry = revlog::decode(line.as_bytes());
            assert_eq!(entry.len(), 1, "{name}: {line}");
            let encoded = String::from_utf8(revlog::encode(&entry)).unwrap();
            assert_eq!(encoded, format!("{line}\n"), "{name}");
        }
    }
    let garbage = golden::bytes("misc/revlog_unsorted_with_garbage.otlog.jsonl");
    let decoded = golden::bytes("misc/revlog_unsorted_with_garbage.decoded.otlog.jsonl");
    assert!(
        revlog::encode(&revlog::decode(&garbage)) == decoded,
        "garbage skipped and sorted"
    );
}

// tree/edits.json: scripted edits, the tree after each.

fn check_tree(label: &str, tree: &RepertoireTree, expected: &Value) {
    assert_eq!(json!(tree.count()), expected["count"], "{label} count");
    let nodes = expected["nodes"].as_array().unwrap();
    for (n, e) in tree.nodes().zip(nodes) {
        let actual = json!({
            "id": n.id, "parent": n.parent, "uci": n.mv.as_ref().map(|m| &m.uci),
            "san": n.mv.as_ref().map(|m| &m.san), "epd": n.epd.as_str(), "ply": n.ply,
            "children": n.children, "chapters": n.chapters, "comments": n.comments,
            "preComments": n.pre_comments, "nags": n.nags, "note": n.note(),
        });
        let want: serde_json::Map<String, Value> = actual
            .as_object()
            .unwrap()
            .keys()
            .map(|k| (k.clone(), e[k].clone()))
            .collect();
        golden::assert_same(label, &Value::Object(want), &actual, 0.0);
    }
    assert_eq!(
        json!(tree.load_warnings),
        expected["loadWarnings"],
        "{label}"
    );
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

#[test]
fn tree_edits_match_swift() {
    let fixture = golden::json("tree/edits.json");
    for group in ["edits", "chapters", "notes"] {
        let mut tree = RepertoireTree::default();
        for (i, step) in fixture[group].as_array().unwrap().iter().enumerate() {
            let op = &step["op"];
            let id = |k: &str| op[k].as_u64().unwrap() as u32;
            let s = |k: &str| op[k].as_str().unwrap();
            let result: Value = match s("op") {
                "new" => {
                    tree = RepertoireTree::default();
                    Value::Null
                }
                "parse" => {
                    // `pgn` names an input file.
                    tree = RepertoireTree::from_pgn(&golden::text(&format!(
                        "inputs/{}.pgn",
                        s("pgn")
                    )));
                    Value::Null
                }
                "addMove" => json!(tree.add_move(s("uci"), id("after"))),
                "addMoveSAN" => json!(tree.add_move_san(s("san"), id("after"))),
                "addLine" => {
                    let ucis: Vec<&str> = op["ucis"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .map(|u| u.as_str().unwrap())
                        .collect();
                    json!(tree.add_line(&ucis, id("after")))
                }
                "promote" => {
                    tree.promote(id("id"));
                    Value::Null
                }
                "delete" => {
                    tree.delete(id("id"));
                    Value::Null
                }
                "setNote" => {
                    tree.set_note(s("text"), id("id"));
                    Value::Null
                }
                "setChapterTag" => {
                    tree.set_chapter_tag(
                        op["index"].as_u64().unwrap() as usize,
                        s("name"),
                        s("value"),
                    );
                    Value::Null
                }
                "mergeMoves" => {
                    let games = ot_core::pgn::parse(s("pgn"));
                    json!(tree.merge_moves(&games[0].moves, id("at"), None))
                }
                other => panic!("unknown op {other}"),
            };
            let label = format!("{group} step {i} {}", s("op"));
            assert_eq!(result, step["result"], "{label} result");
            check_tree(&label, &tree, &step["tree"]);
            assert_eq!(
                tree.pgn_text(),
                step["pgnText"].as_str().unwrap(),
                "{label} pgnText"
            );
        }
    }
    // mergeTree: local.merge(tree: remote), the trees given as fixture JSON.
    let m = &fixture["mergeTree"];
    let mut local = tree_from_json(&m["local"]);
    let remote = tree_from_json(&m["remote"]);
    assert_eq!(json!(local.merge_tree(&remote)), m["added"]);
    check_tree("mergeTree", &local, &m["result"]);
    // A tree rebuilt move by move gets default tags, so compare the movetext.
    assert!(local.pgn_text().ends_with(m["pgnText"].as_str().unwrap()));
}
