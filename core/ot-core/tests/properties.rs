//! Properties over generated repertoires: the writer is stable, and transpositions keep each
//! position's lines in one place.

use std::collections::{HashMap, HashSet};

use proptest::prelude::*;

use ot_core::chess::{ChessPosition, Epd};
use ot_core::pgn::{self, PgnGame, PgnMove, PgnTag};
use ot_core::repertoire::{NodeId, RepertoireTree};

// Generated PGN text (not necessarily legal chess)

fn comment() -> impl Strategy<Value = String> {
    // No braces (they end a comment), at least one non-space so it survives trimming.
    "[a-zA-Z0-9%\\[\\] ,.!?()-]{0,12}[a-z]".prop_map(|s| s.trim().to_owned())
}

fn san() -> impl Strategy<Value = String> {
    prop_oneof![
        "[a-h][1-8]",
        "[NBRQK][a-h]?x?[a-h][1-8][+#]?",
        "[a-h]x[a-h][1-8](=[NBRQ])?",
        Just("O-O".to_owned()),
        Just("O-O-O".to_owned()),
    ]
}

fn pgn_move() -> impl Strategy<Value = PgnMove> {
    let leaf = (
        san(),
        prop::collection::vec(prop_oneof![1..=6i32, 7..=200i32], 0..2),
        prop::collection::vec(comment(), 0..2),
        prop::collection::vec(comment(), 0..2),
    )
        .prop_map(|(san, nags, pre_comments, comments)| PgnMove {
            san,
            nags,
            pre_comments,
            comments,
            children: Vec::new(),
        });
    leaf.prop_recursive(6, 40, 3, |inner| {
        (inner.clone(), prop::collection::vec(inner, 0..3)).prop_map(|(mut m, children)| {
            m.children = children;
            m
        })
    })
}

fn game() -> impl Strategy<Value = PgnGame> {
    (
        prop::collection::vec(("[A-Z][a-zA-Z]{0,8}", "[a-zA-Z0-9 \"\\\\.?:-]{0,12}"), 0..3),
        prop::collection::vec(comment(), 0..2),
        prop::collection::vec(pgn_move(), 0..3),
        prop_oneof![Just("*"), Just("1-0"), Just("0-1"), Just("1/2-1/2")],
    )
        .prop_map(|(tags, comments, moves, result)| PgnGame {
            tags: tags.into_iter().map(|(n, v)| PgnTag::new(n, v)).collect(),
            comments,
            moves,
            result: result.to_owned(),
        })
}

// Generated legal repertoires, with few moves to choose from so that move orders transpose

/// Plays each line of choice indices from the start, picking among the first few legal
/// moves (sorted by UCI) of each position. Returns the lines as SAN.
fn legal_lines(choices: &[Vec<u8>]) -> Vec<Vec<String>> {
    choices
        .iter()
        .map(|line| {
            let mut position = ChessPosition::start();
            let mut sans = Vec::new();
            for &choice in line {
                let mut moves = position.legal_moves();
                if moves.is_empty() {
                    break;
                }
                moves.sort_by(|a, b| a.uci.cmp(&b.uci));
                // Mostly knight moves, so the lines meet again (and repeat positions); a
                // pawn move now and then.
                let pawn = choice >= 224;
                moves.retain(|m| m.san.starts_with('N') != pawn && !m.san.contains('x'));
                if moves.is_empty() {
                    break;
                }
                let m = &moves[usize::from(choice) % moves.len().min(3)];
                let (played, next) = position.play_uci(&m.uci).expect("legal");
                sans.push(played.san);
                position = next;
            }
            sans
        })
        .collect()
}

/// The lines as one game with variations (shared prefixes merged).
fn game_of(lines: &[Vec<String>]) -> PgnGame {
    fn insert(moves: &mut Vec<PgnMove>, line: &[String]) {
        let Some((first, rest)) = line.split_first() else {
            return;
        };
        let index = match moves.iter().position(|m| &m.san == first) {
            Some(i) => i,
            None => {
                moves.push(PgnMove::new(first.clone()));
                moves.len() - 1
            }
        };
        insert(&mut moves[index].children, rest);
    }
    let mut moves = Vec::new();
    for line in lines {
        insert(&mut moves, line);
    }
    PgnGame {
        tags: vec![PgnTag::new("Event", "Generated")],
        moves,
        ..PgnGame::default()
    }
}

/// One move choice: mostly among two knight moves, so move orders transpose.
fn choice() -> impl Strategy<Value = u8> {
    prop_oneof![8 => 0u8..2, 1 => 2u8..224, 1 => 224u8..=255]
}

fn line() -> impl Strategy<Value = Vec<u8>> {
    prop::collection::vec(choice(), 1..10)
}

/// Games of lines of choices.
fn repertoire(games: std::ops::Range<usize>) -> impl Strategy<Value = Vec<Vec<Vec<u8>>>> {
    prop::collection::vec(prop::collection::vec(line(), 1..8), games)
}

fn tree_of(games: &[Vec<Vec<u8>>]) -> RepertoireTree {
    let games: Vec<PgnGame> = games.iter().map(|c| game_of(&legal_lines(c))).collect();
    RepertoireTree::from_pgn(&pgn::write_games(&games))
}

/// Nodes with moves below them, by position.
fn holders(tree: &RepertoireTree) -> HashMap<Epd, Vec<NodeId>> {
    let mut result: HashMap<Epd, Vec<NodeId>> = HashMap::new();
    for node in tree.nodes() {
        if !node.children.is_empty() {
            result.entry(node.epd.clone()).or_default().push(node.id);
        }
    }
    result
}

fn move_count(games: &[PgnGame]) -> usize {
    let mut stack: Vec<&PgnMove> = games.iter().flat_map(|g| &g.moves).collect();
    let mut count = 0;
    while let Some(m) = stack.pop() {
        count += 1;
        stack.extend(&m.children);
    }
    count
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(512))]

    #[test]
    fn writing_what_was_read_is_stable(games in prop::collection::vec(game(), 1..3)) {
        // A game without moves, tags or comments is not read back, and a pre-comment that
        // does not start a variation becomes the comment before it; otherwise a written
        // file reads back as it was, and writing it again gives the same text.
        let written = pgn::write_games(&games);
        let read = pgn::parse(&written);
        prop_assert_eq!(move_count(&read), move_count(&games));
        let again = pgn::write_games(&read);
        prop_assert_eq!(pgn::write_games(&pgn::parse(&again)), again);
    }

    #[test]
    fn a_saved_tree_reads_back_the_same(games in repertoire(1..4)) {
        saved_tree_reads_back(&games)?;
    }

    #[test]
    fn transposition_targets_are_never_ancestors(games in repertoire(1..4)) {
        let tree = tree_of(&games);
        for node in tree.nodes() {
            let Some(target) = tree.transposition_target(node.id) else {
                continue;
            };
            prop_assert!(node.children.is_empty());
            prop_assert_ne!(target, node.id);
            prop_assert!(!tree.is_ancestor(target, node.id));
            let t = tree.get(target).expect("target exists");
            prop_assert_eq!(&t.epd, &node.epd);
            prop_assert!(!t.children.is_empty());
        }
        let epds: HashSet<&Epd> = tree.nodes().map(|n| &n.epd).collect();
        prop_assert_eq!(epds.len(), tree.epd_index().len());
    }

    #[test]
    fn is_ancestor_matches_walking_up(games in repertoire(1..4), deletes in prop::collection::vec(any::<u32>(), 0..3)) {
        let mut tree = tree_of(&games);
        for d in deletes {
            let ids: Vec<NodeId> = tree.nodes().map(|n| n.id).collect();
            tree.delete(ids[d as usize % ids.len()]);
        }
        let ids: Vec<NodeId> = tree.nodes().map(|n| n.id).collect();
        for &b in &ids {
            let above: HashSet<NodeId> = tree.path(b).into_iter().filter(|&n| n != b).collect();
            for &a in &ids {
                prop_assert_eq!(tree.is_ancestor(a, b), above.contains(&a), "{} {}", a, b);
            }
        }
    }

    #[test]
    fn each_positions_lines_are_stored_once(games in repertoire(1..4)) {
        let tree = tree_of(&games);
        for ids in holders(&tree).values() {
            // Two nodes may both hold lines only if one is reached through the other
            // (a repetition), never side by side.
            for (i, &a) in ids.iter().enumerate() {
                for &b in &ids[i + 1..] {
                    prop_assert!(
                        tree.is_ancestor(a, b) || tree.is_ancestor(b, a),
                        "{} and {} both hold lines of one position", a, b
                    );
                }
            }
        }
    }

    #[test]
    fn transposed_moves_are_kept(games in repertoire(1..4)) {
        transposed_moves_kept(&games)?;
    }
}

fn saved_tree_reads_back(games: &[Vec<Vec<u8>>]) -> Result<(), TestCaseError> {
    let tree = tree_of(games);
    let text = tree.pgn_text();
    let back = RepertoireTree::from_pgn(&text);
    prop_assert_eq!(back.pgn_text(), text);
    prop_assert_eq!(back.count(), tree.count());
    prop_assert!(back.load_warnings.is_empty());
    Ok(())
}

/// Every line of the input can still be followed, continuing at transposition targets.
fn transposed_moves_kept(games: &[Vec<Vec<u8>>]) -> Result<(), TestCaseError> {
    let tree = tree_of(games);
    for line in games.iter().flat_map(|c| legal_lines(c)) {
        let mut cursor = RepertoireTree::ROOT;
        for san in &line {
            let next = tree.child_by_san(cursor, san).or_else(|| {
                let target = tree.transposition_target(cursor)?;
                tree.child_by_san(target, san)
            });
            prop_assert!(
                next.is_some(),
                "{} missing after {:?}",
                san,
                tree.moves(cursor)
            );
            cursor = next.unwrap_or(cursor);
        }
    }
    Ok(())
}
