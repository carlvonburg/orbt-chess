use std::collections::HashMap;

use super::comment;
use crate::chess::{ChessPosition, Epd, PlayedMove, Side, san};
use crate::pgn::{self, PgnGame, PgnMove, PgnTag};

/// Node ids are sequential and never reused; a deleted node leaves a hole. They are not
/// persisted (the sidecar stores lines as UCI).
pub type NodeId = u32;

#[derive(Clone, Debug)]
pub struct RepertoireNode {
    pub id: NodeId,
    pub parent: Option<NodeId>,
    /// The move that leads to this node; None for the root.
    pub mv: Option<PlayedMove>,
    /// Kept per node so playing from it never re-parses a FEN.
    pub position: ChessPosition,
    pub epd: Epd,
    pub ply: u32,
    /// `children[0]` is the main continuation.
    pub children: Vec<NodeId>,
    pub comments: Vec<String>,
    pub pre_comments: Vec<String>,
    pub nags: Vec<i32>,
}

impl RepertoireNode {
    pub fn side_to_move(&self) -> Side {
        self.epd.side_to_move()
    }

    pub fn fen(&self) -> String {
        self.position.fen()
    }

    /// The user's note without embedded commands like `[%cal Ge2e4]`.
    pub fn note(&self) -> String {
        self.comments
            .iter()
            .map(|c| comment::text(c))
            .filter(|t| !t.is_empty())
            .collect::<Vec<_>>()
            .join("\n")
    }
}

/// The tags, game comments and result of the repertoire's game.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GameHeader {
    pub tags: Vec<PgnTag>,
    pub comments: Vec<String>,
    pub result: String,
}

impl Default for GameHeader {
    fn default() -> GameHeader {
        GameHeader {
            tags: RepertoireTree::default_tags("Repertoire"),
            comments: Vec::new(),
            result: "*".to_owned(),
        }
    }
}

#[derive(Clone, Debug)]
pub struct RepertoireTree {
    nodes: Vec<Option<RepertoireNode>>,
    /// By node id: an ancestor to jump to (skew-binary jump pointers), so `is_ancestor` takes
    /// O(log depth) steps rather than one per ply.
    jumps: Vec<NodeId>,
    /// By node id: how many ancestors have the same position. When every other node with a
    /// position is an ancestor (a line repeating it), no transposition needs a search.
    repeats: Vec<u32>,
    count: usize,
    /// The game's header: the first game's that starts from the standard position (the
    /// others are merged into the tree and their headers dropped). None until there is one.
    pub header: Option<GameHeader>,
    /// Games from another start position (SetUp/FEN): not part of the tree, written back
    /// unchanged. The tree's game is written after the first `games_before` of them.
    pub other_games: Vec<PgnGame>,
    games_before: usize,
    epd_index: HashMap<Epd, Vec<NodeId>>,
    /// Moves that could not be played when loading (illegal or unreadable SAN).
    pub load_warnings: Vec<String>,
    /// Positions whose PGN lines were merged into another node with the same position.
    pub merged_transpositions: usize,
}

impl Default for RepertoireTree {
    fn default() -> RepertoireTree {
        RepertoireTree::new(ChessPosition::START_FEN)
    }
}

impl std::ops::Index<NodeId> for RepertoireTree {
    type Output = RepertoireNode;

    fn index(&self, id: NodeId) -> &RepertoireNode {
        self.get(id).expect("node exists")
    }
}

impl RepertoireTree {
    pub const ROOT: NodeId = 0;

    pub fn new(start_fen: &str) -> RepertoireTree {
        let position = ChessPosition::from_fen(start_fen).unwrap_or_default();
        let ply = pgn::start_ply((start_fen != ChessPosition::START_FEN).then_some(start_fen));
        let epd = position.epd();
        let root = RepertoireNode {
            id: Self::ROOT,
            parent: None,
            mv: None,
            position,
            epd: epd.clone(),
            ply: ply as u32,
            children: Vec::new(),
            comments: Vec::new(),
            pre_comments: Vec::new(),
            nags: Vec::new(),
        };
        RepertoireTree {
            nodes: vec![Some(root)],
            jumps: vec![Self::ROOT],
            repeats: vec![0],
            count: 1,
            header: None,
            other_games: Vec::new(),
            games_before: 0,
            epd_index: HashMap::from([(epd, vec![Self::ROOT])]),
            load_warnings: Vec::new(),
            merged_transpositions: 0,
        }
    }

    pub fn root(&self) -> &RepertoireNode {
        &self[Self::ROOT]
    }

    pub fn get(&self, id: NodeId) -> Option<&RepertoireNode> {
        self.nodes.get(id as usize).and_then(Option::as_ref)
    }

    fn get_mut(&mut self, id: NodeId) -> Option<&mut RepertoireNode> {
        self.nodes.get_mut(id as usize).and_then(Option::as_mut)
    }

    /// Number of nodes, including the root.
    pub fn count(&self) -> usize {
        self.count
    }

    /// All nodes in id order.
    pub fn nodes(&self) -> impl Iterator<Item = &RepertoireNode> {
        self.nodes.iter().flatten()
    }

    pub fn epd_index(&self) -> &HashMap<Epd, Vec<NodeId>> {
        &self.epd_index
    }

    pub fn nodes_at(&self, epd: &Epd) -> &[NodeId] {
        self.epd_index.get(epd).map(Vec::as_slice).unwrap_or(&[])
    }

    // Queries

    /// Node ids from the root to `id`, inclusive.
    pub fn path(&self, id: NodeId) -> Vec<NodeId> {
        let mut result = Vec::new();
        let mut cursor = Some(id);
        while let Some(c) = cursor {
            let Some(node) = self.get(c) else { break };
            result.push(c);
            cursor = node.parent;
        }
        result.reverse();
        result
    }

    pub fn moves(&self, id: NodeId) -> Vec<PlayedMove> {
        self.path(id)
            .into_iter()
            .filter_map(|n| self.get(n).and_then(|n| n.mv.clone()))
            .collect()
    }

    pub fn child_by_uci(&self, id: NodeId, uci: &str) -> Option<NodeId> {
        self.get(id)?.children.iter().copied().find(|&c| {
            self.get(c)
                .and_then(|n| n.mv.as_ref())
                .is_some_and(|m| m.uci == uci)
        })
    }

    pub fn child_by_san(&self, id: NodeId, wanted: &str) -> Option<NodeId> {
        let children = &self.get(id)?.children;
        let san_of = |c: NodeId| {
            self.get(c)
                .and_then(|n| n.mv.as_ref())
                .map(|m| m.san.as_str())
                .unwrap_or("")
        };
        if let Some(&exact) = children.iter().find(|&&c| san_of(c) == wanted) {
            return Some(exact);
        }
        let loose = san::loose(wanted);
        children
            .iter()
            .copied()
            .find(|&c| san::loose(san_of(c)) == loose)
    }

    /// Follows a line of SAN moves ("e4 c5 Nf3") from the root; None if any is missing.
    pub fn find_san(&self, line: &str) -> Option<NodeId> {
        let mut cursor = Self::ROOT;
        for san in line.split_whitespace() {
            cursor = self.child_by_san(cursor, san)?;
        }
        Some(cursor)
    }

    /// Follows a list of UCI moves from the root; returns None if any is missing.
    pub fn node_following_uci<S: AsRef<str>>(&self, moves: &[S]) -> Option<NodeId> {
        let mut cursor = Self::ROOT;
        for uci in moves {
            cursor = self.child_by_uci(cursor, uci.as_ref())?;
        }
        Some(cursor)
    }

    /// Depth-first order, parents before children.
    pub fn subtree(&self, id: NodeId) -> Vec<NodeId> {
        let mut result = Vec::new();
        let mut stack = vec![id];
        while let Some(n) = stack.pop() {
            result.push(n);
            if let Some(node) = self.get(n) {
                stack.extend(node.children.iter().rev());
            }
        }
        result
    }

    /// For a node without moves: the node with the same position that holds its lines
    /// (the first one that has moves). Never an ancestor, so following it cannot loop.
    pub fn transposition_target(&self, id: NodeId) -> Option<NodeId> {
        let node = self.get(id)?;
        if !node.children.is_empty() {
            return None;
        }
        let candidates = self.epd_index.get(&node.epd)?;
        if candidates.len() <= self.repeats.get(id as usize).map_or(0, |&r| r as usize + 1) {
            return None; // the others are all above it
        }
        // Ids only grow, so the first match is the lowest.
        candidates.iter().copied().find(|&candidate| {
            candidate != id
                && self.get(candidate).is_some_and(|c| !c.children.is_empty())
                && !self.is_ancestor(candidate, id)
        })
    }

    /// Whether `a` is above `b` (not `b` itself).
    pub fn is_ancestor(&self, a: NodeId, b: NodeId) -> bool {
        let (Some(above), Some(mut cursor)) = (self.get(a), self.get(b)) else {
            return false;
        };
        // Plies grow by one per move, so `a` is the ancestor of `b` at its ply, if any.
        while cursor.ply > above.ply {
            let jump = self
                .jumps
                .get(cursor.id as usize)
                .and_then(|&j| self.get(j))
                .filter(|j| j.ply >= above.ply);
            let next = jump.or_else(|| cursor.parent.and_then(|p| self.get(p)));
            match next {
                Some(next) if next.ply < cursor.ply => cursor = next,
                _ => return false,
            }
        }
        cursor.id == a && a != b
    }

    /// Leaves under `id` (lines ending there).
    pub fn leaves(&self, id: NodeId) -> Vec<NodeId> {
        self.subtree(id)
            .into_iter()
            .filter(|&n| self.get(n).is_some_and(|n| n.children.is_empty()))
            .collect()
    }

    // Edits

    /// Adds a move after `parent`, reusing an existing child with the same move.
    pub fn add_move(&mut self, uci: &str, parent: NodeId) -> Option<NodeId> {
        if let Some(existing) = self.child_by_uci(parent, uci) {
            return Some(existing);
        }
        let parent_node = self.get(parent)?;
        let (mv, next) = parent_node.position.play_uci(uci)?;
        self.add_played(mv, next, parent)
    }

    pub fn add_move_san(&mut self, san: &str, parent: NodeId) -> Option<NodeId> {
        if let Some(existing) = self.child_by_san(parent, san) {
            return Some(existing);
        }
        let parent_node = self.get(parent)?;
        let (mv, next) = parent_node.position.play_san(san)?;
        self.add_played(mv, next, parent)
    }

    fn add_played(
        &mut self,
        mv: PlayedMove,
        next: ChessPosition,
        parent: NodeId,
    ) -> Option<NodeId> {
        if let Some(existing) = self.child_by_uci(parent, &mv.uci) {
            return Some(existing);
        }
        Some(self.insert(mv, next, parent))
    }

    /// Adds a sequence of moves; returns the last node.
    pub fn add_line<S: AsRef<str>>(&mut self, ucis: &[S], start: NodeId) -> Option<NodeId> {
        let mut cursor = start;
        for uci in ucis {
            cursor = self.add_move(uci.as_ref(), cursor)?;
        }
        Some(cursor)
    }

    /// Removes the node and everything below it. The root cannot be deleted.
    pub fn delete(&mut self, id: NodeId) {
        if id == Self::ROOT {
            return;
        }
        let Some(parent) = self.get(id).and_then(|n| n.parent) else {
            return;
        };
        for n in self.subtree(id) {
            if let Some(removed) = self.nodes.get_mut(n as usize).and_then(Option::take) {
                self.count -= 1;
                if let Some(ids) = self.epd_index.get_mut(&removed.epd) {
                    ids.retain(|&x| x != n);
                    if ids.is_empty() {
                        self.epd_index.remove(&removed.epd);
                    }
                }
            }
        }
        if let Some(p) = self.get_mut(parent) {
            p.children.retain(|&c| c != id);
        }
    }

    /// Makes `id` the main continuation of its parent.
    pub fn promote(&mut self, id: NodeId) {
        let Some(parent) = self.get(id).and_then(|n| n.parent) else {
            return;
        };
        let Some(p) = self.get_mut(parent) else {
            return;
        };
        if let Some(index) = p.children.iter().position(|&c| c == id)
            && index > 0
        {
            p.children.remove(index);
            p.children.insert(0, id);
        }
    }

    /// Replaces the user's note and keeps embedded commands such as arrows.
    pub fn set_note(&mut self, text: &str, id: NodeId) {
        let Some(node) = self.get_mut(id) else {
            return;
        };
        let mut parts: Vec<String> = node
            .comments
            .iter()
            .flat_map(|c| comment::commands(c))
            .collect();
        let trimmed = text.trim();
        if !trimmed.is_empty() {
            parts.push(trimmed.to_owned());
        }
        let combined = parts.join(" ");
        node.comments = if combined.is_empty() {
            Vec::new()
        } else {
            vec![combined]
        };
    }

    pub fn set_tag(&mut self, name: &str, value: &str) {
        let header = self.header.get_or_insert_with(GameHeader::default);
        match header.tags.iter_mut().find(|t| t.name == name) {
            Some(tag) => tag.value = value.to_owned(),
            None => header.tags.insert(0, PgnTag::new(name, value)),
        }
    }

    // PGN

    /// Builds a tree from PGN games. Games from the standard position are merged into one
    /// tree (one game, with the first one's header); the others are kept as they are.
    pub fn from_games(games: Vec<PgnGame>) -> RepertoireTree {
        let mut tree = RepertoireTree::default();
        if games.is_empty() {
            tree.header = Some(GameHeader::default());
        }
        for game in games {
            tree.append_game(game);
        }
        tree
    }

    pub fn from_pgn(text: &str) -> RepertoireTree {
        RepertoireTree::from_games(pgn::parse(text))
    }

    pub fn default_tags(event: &str) -> Vec<PgnTag> {
        vec![
            PgnTag::new("Event", event),
            PgnTag::new("Site", "?"),
            PgnTag::new("Result", "*"),
        ]
    }

    fn append_game(&mut self, game: PgnGame) {
        let root_epd = self.root().epd.clone();
        if let Some(fen) = game.start_fen()
            && let Some(position) = ChessPosition::from_fen(fen)
            && position.epd() != root_epd
        {
            self.other_games.push(game);
            return;
        }
        if self.header.is_none() {
            self.games_before = self.other_games.len();
            self.header = Some(GameHeader {
                tags: game.tags,
                comments: game.comments,
                result: game.result,
            });
        }
        self.merge_moves(&game.moves, Self::ROOT);
    }

    /// Merges PGN moves (with variations) below `id`. Returns the number of new nodes.
    pub fn merge_moves(&mut self, moves: &[PgnMove], id: NodeId) -> usize {
        let before = self.count;
        let mut stack: Vec<(&PgnMove, NodeId)> = moves.iter().rev().map(|m| (m, id)).collect();
        while let Some((pgn_move, parent)) = stack.pop() {
            let Some(parent_node) = self.get(parent) else {
                continue;
            };
            let target = if let Some(existing) = self.existing_child(parent, &pgn_move.san) {
                existing
            } else if let Some((mv, next)) = parent_node.position.play_san(&pgn_move.san) {
                self.insert(mv, next, parent)
            } else {
                let line: Vec<String> = self.moves(parent).into_iter().map(|m| m.san).collect();
                let after = if line.is_empty() {
                    "start".to_owned()
                } else {
                    line.join(" ")
                };
                self.load_warnings
                    .push(format!("Illegal move {} after {after}", pgn_move.san));
                continue;
            };
            let node = self.get_mut(target).expect("target exists");
            append_unique(&mut node.comments, &pgn_move.comments);
            append_unique(&mut node.pre_comments, &pgn_move.pre_comments);
            for &nag in &pgn_move.nags {
                if !node.nags.contains(&nag) {
                    node.nags.push(nag);
                }
            }
            // A position whose lines are already stored elsewhere stays a leaf here: its moves
            // are merged into that node, so each position's continuation is stored once.
            // (Exports like Chessbook's repeat the whole subtree under every move order.)
            let continuation = if pgn_move.children.is_empty() {
                target
            } else {
                self.transposition_target(target).unwrap_or(target)
            };
            if continuation != target {
                self.merged_transpositions += 1;
            }
            stack.extend(pgn_move.children.iter().rev().map(|m| (m, continuation)));
        }
        self.count - before
    }

    /// The child reached by `san`, also when written differently ("Ngf3" for "Nf3").
    fn existing_child(&self, parent: NodeId, san: &str) -> Option<NodeId> {
        self.child_by_san(parent, san).or_else(|| {
            let (mv, _) = self.get(parent)?.position.play_san(san)?;
            self.child_by_uci(parent, &mv.uci)
        })
    }

    /// Union of both trees (used when the file changed elsewhere).
    pub fn merge_tree(&mut self, other: &RepertoireTree) -> usize {
        if self.header.is_none() {
            self.header.clone_from(&other.header);
        }
        for game in &other.other_games {
            if !self.other_games.contains(game) {
                self.other_games.push(game.clone());
            }
        }
        self.merge_moves(&other.pgn_moves(Self::ROOT), Self::ROOT)
    }

    /// Writes the repertoire back as PGN games: its game, and those from other positions.
    pub fn pgn_games(&self) -> Vec<PgnGame> {
        let header = match &self.header {
            Some(header) => header.clone(),
            None if !self.root().children.is_empty() => GameHeader::default(),
            None => return self.other_games.clone(),
        };
        let mut games = self.other_games.clone();
        let game = PgnGame {
            tags: header.tags,
            comments: header.comments,
            moves: self.pgn_moves(Self::ROOT),
            result: header.result,
        };
        games.insert(self.games_before.min(games.len()), game);
        games
    }

    pub fn pgn_text(&self) -> String {
        pgn::write_games(&self.pgn_games())
    }

    /// Moves below `id` as PGN.
    pub fn pgn_moves(&self, id: NodeId) -> Vec<PgnMove> {
        // Each frame: the move being built and its children still to visit. A work stack
        // rather than recursion, because a line nests one level per ply.
        let mut stack = vec![(PgnMove::default(), self.written_children(id))];
        loop {
            let (_, rest) = stack.last_mut().expect("non-empty until `id` is done");
            if let Some((child_id, pgn_move)) = rest.next() {
                stack.push((pgn_move, self.written_children(child_id)));
                continue;
            }
            let (mut done, _) = stack.pop().expect("non-empty");
            match stack.last_mut() {
                Some((parent, _)) => parent.children.push(done),
                None => return std::mem::take(&mut done.children),
            }
        }
    }

    /// The children of `id` as PGN moves without their children.
    fn written_children(&self, id: NodeId) -> std::vec::IntoIter<(NodeId, PgnMove)> {
        let Some(node) = self.get(id) else {
            return Vec::new().into_iter();
        };
        node.children
            .iter()
            .filter_map(|&child_id| {
                let child = self.get(child_id)?;
                let pgn_move = PgnMove {
                    san: child.mv.as_ref()?.san.clone(),
                    nags: child.nags.clone(),
                    pre_comments: child.pre_comments.clone(),
                    comments: child.comments.clone(),
                    children: Vec::new(),
                };
                Some((child_id, pgn_move))
            })
            .collect::<Vec<_>>()
            .into_iter()
    }

    // Private

    fn insert(&mut self, mv: PlayedMove, position: ChessPosition, parent: NodeId) -> NodeId {
        let id = self.nodes.len() as NodeId;
        let parent_ply = self.get(parent).map_or(0, |p| p.ply);
        let epd = position.epd();
        self.jumps.push(self.jump_for_child_of(parent));
        // The nearest ancestor with this position is the one with the highest id.
        let repeats = self
            .epd_index
            .get(&epd)
            .and_then(|ids| {
                ids.iter()
                    .rev()
                    .find(|&&c| c == parent || self.is_ancestor(c, parent))
            })
            .map_or(0, |&c| self.repeats.get(c as usize).map_or(0, |r| r + 1));
        self.repeats.push(repeats);
        self.nodes.push(Some(RepertoireNode {
            id,
            parent: Some(parent),
            mv: Some(mv),
            position,
            epd: epd.clone(),
            ply: parent_ply + 1,
            children: Vec::new(),
            comments: Vec::new(),
            pre_comments: Vec::new(),
            nags: Vec::new(),
        }));
        self.count += 1;
        if let Some(p) = self.get_mut(parent) {
            p.children.push(id);
        }
        self.epd_index.entry(epd).or_default().push(id);
        id
    }
}

impl RepertoireTree {
    /// Myers' skew-binary jump: the parent's jump's jump when the two jumps span the same
    /// number of plies, else the parent.
    fn jump_for_child_of(&self, parent: NodeId) -> NodeId {
        let ply = |id: NodeId| self.get(id).map_or(0, |n| n.ply);
        let jump = |id: NodeId| self.jumps.get(id as usize).copied().unwrap_or(Self::ROOT);
        let (p_jump, p_jump_jump) = (jump(parent), jump(jump(parent)));
        if ply(parent) - ply(p_jump) == ply(p_jump) - ply(p_jump_jump) {
            p_jump_jump
        } else {
            parent
        }
    }
}

fn append_unique(target: &mut Vec<String>, items: &[String]) {
    for item in items {
        if !target.contains(item) {
            target.push(item.clone());
        }
    }
}
