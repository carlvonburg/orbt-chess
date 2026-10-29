//! Snapshots of the PGN parser and writer and of the repertoire tree, for the PGNs in
//! tests/data/pgn and the large repertoires (`common::REPERTOIRES`). After an intended change, review the
//! new snapshots with `cargo insta review`.

mod common;

use std::collections::HashSet;
use std::fmt::Write;

use orbt_core::pgn::{self, PgnGame, PgnMove};
use orbt_core::repertoire::{NodeId, RepertoireTree};
use serde_json::{Value, json};

fn move_json(m: &PgnMove) -> Value {
    json!({
        "san": m.san, "nags": m.nags, "preComments": m.pre_comments, "comments": m.comments,
        "children": m.children.iter().map(move_json).collect::<Vec<_>>(),
    })
}

fn games_json(games: &[PgnGame]) -> String {
    let games: Vec<Value> = games
        .iter()
        .map(|g| {
            json!({
                "tags": g.tags.iter().map(|t| [&t.name, &t.value]).collect::<Vec<_>>(),
                "comments": g.comments,
                "moves": g.moves.iter().map(move_json).collect::<Vec<_>>(),
                "result": g.result,
            })
        })
        .collect();
    serde_json::to_string_pretty(&games).unwrap()
}

/// The tree's header and other games, then one line per node.
fn tree_text(tree: &RepertoireTree) -> String {
    let mut out = String::new();
    writeln!(
        out,
        "{} nodes, {} merged transpositions",
        tree.count(),
        tree.merged_transpositions
    )
    .unwrap();
    for warning in &tree.load_warnings {
        writeln!(out, "warning: {warning}").unwrap();
    }
    if let Some(h) = &tree.header {
        let tags: Vec<String> = h
            .tags
            .iter()
            .map(|t| format!("{}={}", t.name, t.value))
            .collect();
        writeln!(out, "header: {}", tags.join(" ")).unwrap();
    }
    for g in &tree.other_games {
        writeln!(out, "other game: {:?}", g.tag("Event").unwrap_or("")).unwrap();
    }
    for n in tree.nodes() {
        let san = n.mv.as_ref().map_or("root", |m| m.san.as_str());
        write!(out, "{} {san} ply {}", n.id, n.ply).unwrap();
        if let Some(p) = n.parent {
            write!(out, " <- {p}").unwrap();
        }
        if !n.children.is_empty() {
            write!(out, " -> {:?}", n.children).unwrap();
        }
        if let Some(t) = tree.transposition_target(n.id) {
            write!(out, " transposes to {t}").unwrap();
        }
        if !n.nags.is_empty() {
            write!(out, " nags {:?}", n.nags).unwrap();
        }
        if !n.pre_comments.is_empty() {
            write!(out, " pre {:?}", n.pre_comments).unwrap();
        }
        if !n.comments.is_empty() {
            write!(out, " comments {:?}", n.comments).unwrap();
        }
        writeln!(out, " | {}", n.epd.as_str()).unwrap();
    }
    out
}

/// Re-reading the saved PGN gives the same tree, and saving it again the same text.
fn rereads_the_same(name: &str, tree: &RepertoireTree) {
    let reread = RepertoireTree::from_pgn(&tree.pgn_text());
    assert_eq!(reread.count(), tree.count(), "{name}");
    assert!(
        reread.pgn_text() == tree.pgn_text(),
        "{name}: saved PGN changes on re-save"
    );
}

#[test]
fn small_pgns() {
    for (name, text) in common::small_pgns() {
        let games = pgn::parse(&text);
        insta::assert_snapshot!(format!("{name}.parse"), games_json(&games));
        insta::assert_snapshot!(format!("{name}.written"), pgn::write_games(&games));
        let tree = RepertoireTree::from_pgn(&text);
        insta::assert_snapshot!(format!("{name}.tree"), tree_text(&tree));
        insta::assert_snapshot!(format!("{name}.saved"), tree.pgn_text());
        rereads_the_same(&name, &tree);
    }
}

#[test]
fn real_repertoires() {
    for name in common::REPERTOIRES {
        let text = common::repertoire(name);
        // Writing what was parsed and parsing it again changes nothing.
        let written = pgn::write_games(&pgn::parse(&text));
        assert!(pgn::write_games(&pgn::parse(&written)) == written, "{name}");

        let tree = RepertoireTree::from_pgn(&text);
        rereads_the_same(name, &tree);
        let positions: HashSet<_> = tree.nodes().map(|n| n.epd.clone()).collect();
        let leaves = tree.leaves(RepertoireTree::ROOT).len();
        let summary = format!(
            "{} nodes, {} positions, {leaves} leaves, {} merged transpositions, {} games\n\
             warnings: {:?}\n",
            tree.count(),
            positions.len(),
            tree.merged_transpositions,
            tree.pgn_games().len(),
            tree.load_warnings,
        );
        insta::assert_snapshot!(format!("{name}.summary"), summary);
        if name == "openings_expanded" {
            // Compacted, it holds the positions of the tree it was expanded from.
            let source = RepertoireTree::from_pgn(&common::repertoire("openings"));
            let source_positions: HashSet<_> = source.nodes().map(|n| n.epd.clone()).collect();
            assert!(positions == source_positions, "{name}");
            assert_eq!(tree.count(), source.count(), "{name}");
        } else {
            insta::assert_snapshot!(format!("{name}.saved"), tree.pgn_text());
        }
    }
}

/// The tree after an edit: node ids and moves, then the saved movetext.
fn edit_text(tree: &RepertoireTree) -> String {
    let nodes: Vec<String> = tree
        .nodes()
        .skip(1)
        .map(|n| format!("{}:{}", n.id, n.mv.as_ref().map_or("", |m| m.san.as_str())))
        .collect();
    let text = tree.pgn_text();
    let movetext: Vec<&str> = text
        .lines()
        .filter(|l| !l.is_empty() && !l.starts_with('['))
        .collect();
    format!("  {}\n  {}", nodes.join(" "), movetext.join(" / "))
}

fn tree_from_moves(v: &Value) -> RepertoireTree {
    let mut tree = RepertoireTree::default();
    for pair in v.as_array().unwrap() {
        let parent = pair[0].as_u64().unwrap() as NodeId;
        tree.add_move(pair[1].as_str().unwrap(), parent);
    }
    tree
}

#[test]
fn tree_edits() {
    let script = common::data_json("tree_edits.json");
    for group in ["edits", "chapters", "notes"] {
        let mut tree = RepertoireTree::default();
        let mut out = String::new();
        for op in script[group].as_array().unwrap() {
            let id = |k: &str| op[k].as_u64().unwrap() as NodeId;
            let s = |k: &str| op[k].as_str().unwrap();
            let result: Value = match s("op") {
                "new" => {
                    tree = RepertoireTree::default();
                    Value::Null
                }
                "parse" => {
                    tree = RepertoireTree::from_pgn(&common::data_text(&format!(
                        "pgn/{}.pgn",
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
                "setTag" => {
                    tree.set_tag(s("name"), s("value"));
                    Value::Null
                }
                "mergeMoves" => {
                    let games = pgn::parse(s("pgn"));
                    json!(tree.merge_moves(&games[0].moves, id("at")))
                }
                other => panic!("unknown op {other}"),
            };
            writeln!(out, "{op} -> {result}\n{}", edit_text(&tree)).unwrap();
        }
        insta::assert_snapshot!(format!("edits.{group}"), out);
    }
    let m = &script["mergeTree"];
    let mut local = tree_from_moves(&m["local"]);
    let remote = tree_from_moves(&m["remote"]);
    let added = local.merge_tree(&remote);
    insta::assert_snapshot!(
        "edits.mergeTree",
        format!("added {added}\n{}", edit_text(&local))
    );
}
