//! The Rust PGN parser, writer and repertoire tree against the Swift core's fixtures.

mod golden;

use ot_core::pgn::{self, PgnGame, PgnMove};
use ot_core::repertoire::RepertoireTree;
use serde_json::{Value, json};

fn move_json(m: &PgnMove) -> Value {
    json!({
        "san": m.san, "nags": m.nags, "preComments": m.pre_comments, "comments": m.comments,
        "children": m.children.iter().map(move_json).collect::<Vec<_>>(),
    })
}

pub fn game_json(g: &PgnGame) -> Value {
    json!({
        "tags": g.tags.iter().map(|t| json!({"name": t.name, "value": t.value})).collect::<Vec<_>>(),
        "comments": g.comments,
        "moves": g.moves.iter().map(move_json).collect::<Vec<_>>(),
        "result": g.result,
    })
}

pub fn tree_json(tree: &RepertoireTree) -> Value {
    let nodes: Vec<Value> = tree
        .nodes()
        .map(|n| {
            json!({
                "id": n.id, "parent": n.parent,
                "san": n.mv.as_ref().map(|m| &m.san), "uci": n.mv.as_ref().map(|m| &m.uci),
                "fen": n.fen(), "epd": n.epd.as_str(), "ply": n.ply, "children": n.children,
                "chapters": n.chapters, "comments": n.comments, "preComments": n.pre_comments,
                "nags": n.nags, "note": n.note(),
                "sideToMove": match n.side_to_move() { ot_core::chess::Side::White => "white", _ => "black" },
                "transpositionTarget": tree.transposition_target(n.id),
            })
        })
        .collect();
    let chapters: Vec<Value> = tree
        .chapters
        .iter()
        .map(|c| {
            json!({
                "tags": c.tags.iter().map(|t| json!({"name": t.name, "value": t.value})).collect::<Vec<_>>(),
                "comments": c.comments, "result": c.result, "name": c.name(),
                "passthrough": c.passthrough.as_ref().map(game_json),
            })
        })
        .collect();
    let epd_index: serde_json::Map<String, Value> = tree
        .epd_index()
        .iter()
        .map(|(e, ids)| (e.as_str().to_owned(), json!(ids)))
        .collect();
    json!({
        "count": tree.count(), "nodes": nodes, "chapters": chapters, "epdIndex": epd_index,
        "loadWarnings": tree.load_warnings, "mergedTranspositions": tree.merged_transpositions,
    })
}

fn input(name: &str) -> String {
    golden::text(&format!("inputs/{name}.pgn"))
}

#[test]
fn parser_matches_swift() {
    for name in golden::inputs() {
        let games = pgn::parse(&input(&name));
        let actual = json!({ "games": games.iter().map(game_json).collect::<Vec<_>>() });
        let expected = golden::json(&format!("pgn/{name}.parse.json"));
        golden::assert_same(&format!("{name}.parse"), &expected, &actual, 0.0);
    }
}

#[test]
fn writer_is_byte_exact() {
    for name in golden::inputs() {
        let written = pgn::write_games(&pgn::parse(&input(&name)));
        let expected = golden::text(&format!("pgn/{name}.written.pgn"));
        assert!(written == expected, "{name}.written.pgn differs");
    }
}

#[test]
fn tree_matches_swift() {
    for name in golden::inputs() {
        let tree = RepertoireTree::from_pgn(&input(&name));
        let mut expected = golden::json(&format!("tree/{name}.tree.json"));
        let reread = RepertoireTree::from_pgn(&tree.pgn_text());
        assert_eq!(
            expected["rereadCount"],
            json!(reread.count()),
            "{name} reread"
        );
        assert_eq!(
            expected["rereadPGNTextEqual"],
            json!(reread.pgn_text() == tree.pgn_text())
        );
        let obj = expected.as_object_mut().unwrap();
        obj.remove("rereadCount");
        obj.remove("rereadPGNTextEqual");
        let mut actual = tree_json(&tree);
        // chesskit-swift kept castling rights after a rook was captured on its home square,
        // so a few EPDs differ; legacy_epds_reproduce_the_swift_keys checks them instead.
        let legacy = tree.legacy_epds();
        if !legacy.is_empty() {
            let obj = expected.as_object_mut().unwrap();
            obj.remove("epdIndex");
            actual.as_object_mut().unwrap().remove("epdIndex");
            for (e, a) in expected["nodes"]
                .as_array_mut()
                .unwrap()
                .iter_mut()
                .zip(actual["nodes"].as_array_mut().unwrap())
            {
                if let Some(old) = legacy.get(&(a["id"].as_u64().unwrap() as u32)) {
                    a["epd"] = json!(old.as_str());
                    for v in [&mut *e, &mut *a] {
                        v.as_object_mut().unwrap().remove("fen");
                    }
                }
            }
        }
        // chesskit-swift keeps the ep square and counts the halfmove clock up after an en
        // passant capture; shakmaty clears and resets them. The EPD is the same (DEVIATIONS.md).
        for (e, a) in expected["nodes"]
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .zip(actual["nodes"].as_array_mut().unwrap())
        {
            let fields = |v: &Value| -> Vec<String> {
                let f: Vec<String> = v.as_str().unwrap().split(' ').map(str::to_owned).collect();
                vec![f[0].clone(), f[1].clone(), f[2].clone(), f[5].clone()]
            };
            if e["fen"] != a["fen"] && fields(&e["fen"]) == fields(&a["fen"]) {
                a["fen"] = e["fen"].clone();
            }
        }
        golden::assert_same(&format!("{name}.tree"), &expected, &actual, 0.0);
        let pgn_text = golden::text(&format!("tree/{name}.pgn"));
        assert!(tree.pgn_text() == pgn_text, "{name}: pgnText differs");
    }
}

#[test]
fn legacy_epds_reproduce_the_swift_keys() {
    for name in golden::inputs() {
        let tree = RepertoireTree::from_pgn(&input(&name));
        let expected = golden::json(&format!("tree/{name}.tree.json"));
        let legacy = tree.legacy_epds();
        for (node, e) in tree.nodes().zip(expected["nodes"].as_array().unwrap()) {
            let swift = e["epd"].as_str().unwrap();
            let key = legacy.get(&node.id).unwrap_or(&node.epd);
            assert_eq!(key.as_str(), swift, "{name} node {}", node.id);
        }
    }
}
