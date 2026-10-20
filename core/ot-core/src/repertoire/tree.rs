use std::collections::{BTreeSet, HashMap};

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
    /// Indices of the chapters (PGN games) that contain this node.
    pub chapters: BTreeSet<usize>,
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

/// One PGN game of the file. Games that start from a non-standard position are kept
/// verbatim in `passthrough` and written back unchanged.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Chapter {
    pub tags: Vec<PgnTag>,
    pub comments: Vec<String>,
    pub result: String,
    pub passthrough: Option<PgnGame>,
}

impl Chapter {
    fn standard() -> Chapter {
        Chapter {
            tags: RepertoireTree::default_tags("Repertoire"),
            comments: Vec::new(),
            result: "*".to_owned(),
            passthrough: None,
        }
    }

    pub fn name(&self) -> &str {
        let tag = |name: &str| self.tags.iter().find(|t| t.name == name);
        tag("ChapterName")
            .or_else(|| tag("Event"))
            .map(|t| t.value.as_str())
            .unwrap_or("")
    }
}

#[derive(Clone, Debug)]
pub struct RepertoireTree {
    nodes: Vec<Option<RepertoireNode>>,
    count: usize,
    pub chapters: Vec<Chapter>,
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
            chapters: BTreeSet::new(),
        };
        RepertoireTree {
            nodes: vec![Some(root)],
            count: 1,
            chapters: Vec::new(),
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
        self.transposition_target_in(id, None)
    }

    fn transposition_target_in(&self, id: NodeId, chapter: Option<usize>) -> Option<NodeId> {
        let node = self.get(id)?;
        if !node.children.is_empty() {
            return None;
        }
        let candidates = self.epd_index.get(&node.epd)?;
        if candidates.len() < 2 {
            return None;
        }
        candidates
            .iter()
            .copied()
            .filter(|&candidate| {
                let Some(c) = self.get(candidate) else {
                    return false;
                };
                if candidate == id || c.children.is_empty() {
                    return false;
                }
                // Moves are written per chapter, so lines only move to a node of the same chapter.
                if let Some(chapter) = chapter
                    && !c.chapters.contains(&chapter)
                {
                    return false;
                }
                !self.is_ancestor(candidate, id)
            })
            .min()
    }

    pub fn is_ancestor(&self, a: NodeId, b: NodeId) -> bool {
        let mut cursor = self.get(b).and_then(|n| n.parent);
        while let Some(c) = cursor {
            if c == a {
                return true;
            }
            cursor = self.get(c).and_then(|n| n.parent);
        }
        false
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
        let chapter = self.default_chapter(parent);
        Some(self.insert(mv, next, parent, BTreeSet::from([chapter])))
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

    pub fn set_chapter_tag(&mut self, index: usize, name: &str, value: &str) {
        self.ensure_chapter();
        let Some(chapter) = self.chapters.get_mut(index) else {
            return;
        };
        match chapter.tags.iter_mut().find(|t| t.name == name) {
            Some(tag) => tag.value = value.to_owned(),
            None => chapter.tags.insert(0, PgnTag::new(name, value)),
        }
    }

    // PGN

    /// Builds a tree from PGN games. Games from the standard position are merged into one tree.
    pub fn from_games(games: Vec<PgnGame>) -> RepertoireTree {
        let mut tree = RepertoireTree::default();
        for game in games {
            tree.append_chapter(game);
        }
        if tree.chapters.is_empty() {
            tree.chapters = vec![Chapter::standard()];
        }
        tree.reset_root_chapters();
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

    fn reset_root_chapters(&mut self) {
        let standard: BTreeSet<usize> = (0..self.chapters.len())
            .filter(|&i| self.chapters[i].passthrough.is_none())
            .collect();
        self.get_mut(Self::ROOT).expect("root").chapters = standard;
    }

    fn append_chapter(&mut self, game: PgnGame) {
        let index = self.chapters.len();
        let root_epd = self.root().epd.clone();
        if let Some(fen) = game.start_fen()
            && let Some(position) = ChessPosition::from_fen(fen)
            && position.epd() != root_epd
        {
            self.chapters.push(Chapter {
                tags: game.tags.clone(),
                comments: game.comments.clone(),
                result: game.result.clone(),
                passthrough: Some(game),
            });
            return;
        }
        self.chapters.push(Chapter {
            tags: game.tags,
            comments: game.comments,
            result: game.result,
            passthrough: None,
        });
        self.get_mut(Self::ROOT)
            .expect("root")
            .chapters
            .insert(index);
        self.merge_moves(&game.moves, Self::ROOT, Some(index));
    }

    /// Merges PGN moves (with variations) below `id`. Returns the number of new nodes.
    pub fn merge_moves(&mut self, moves: &[PgnMove], id: NodeId, chapter: Option<usize>) -> usize {
        let before = self.count;
        let chapter = chapter.unwrap_or_else(|| {
            if self.get(id).is_some() {
                self.default_chapter(id)
            } else {
                0
            }
        });
        let mut stack: Vec<(&PgnMove, NodeId)> = moves.iter().rev().map(|m| (m, id)).collect();
        while let Some((pgn_move, parent)) = stack.pop() {
            let Some(parent_node) = self.get(parent) else {
                continue;
            };
            let target = if let Some(existing) = self.child_by_san(parent, &pgn_move.san) {
                existing
            } else if let Some((mv, next)) = parent_node.position.play_san(&pgn_move.san) {
                match self.child_by_uci(parent, &mv.uci) {
                    Some(existing) => existing,
                    None => self.insert(mv, next, parent, BTreeSet::new()),
                }
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
            node.chapters.insert(chapter);
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
                self.transposition_target_in(target, Some(chapter))
                    .unwrap_or(target)
            };
            if continuation != target {
                self.merged_transpositions += 1;
            }
            stack.extend(pgn_move.children.iter().rev().map(|m| (m, continuation)));
        }
        self.count - before
    }

    /// Union of both trees (used when the file changed elsewhere). Chapters are matched by index.
    pub fn merge_tree(&mut self, other: &RepertoireTree) -> usize {
        let mut added = 0;
        for (index, game) in other.pgn_games().into_iter().enumerate() {
            if index < self.chapters.len() {
                if self.chapters[index].passthrough.is_none()
                    && other.chapters[index].passthrough.is_none()
                {
                    added += self.merge_moves(&game.moves, Self::ROOT, Some(index));
                }
            } else {
                let before = self.count;
                self.append_chapter(game);
                self.reset_root_chapters();
                added += self.count - before;
            }
        }
        added
    }

    /// Writes all chapters back as PGN games.
    pub fn pgn_games(&self) -> Vec<PgnGame> {
        self.chapters
            .iter()
            .enumerate()
            .map(|(index, chapter)| match &chapter.passthrough {
                Some(passthrough) => passthrough.clone(),
                None => PgnGame {
                    tags: chapter.tags.clone(),
                    comments: chapter.comments.clone(),
                    moves: self.pgn_moves(Self::ROOT, Some(index)),
                    result: chapter.result.clone(),
                },
            })
            .collect()
    }

    pub fn pgn_text(&self) -> String {
        pgn::write_games(&self.pgn_games())
    }

    /// Moves below `id` as PGN, restricted to `chapter` if given.
    pub fn pgn_moves(&self, id: NodeId, chapter: Option<usize>) -> Vec<PgnMove> {
        let Some(node) = self.get(id) else {
            return Vec::new();
        };
        node.children
            .iter()
            .filter_map(|&child_id| {
                let child = self.get(child_id)?;
                let mv = child.mv.as_ref()?;
                if let Some(chapter) = chapter
                    && !child.chapters.contains(&chapter)
                {
                    return None;
                }
                Some(PgnMove {
                    san: mv.san.clone(),
                    nags: child.nags.clone(),
                    pre_comments: child.pre_comments.clone(),
                    comments: child.comments.clone(),
                    children: self.pgn_moves(child_id, chapter),
                })
            })
            .collect()
    }

    // Private

    fn default_chapter(&self, parent: NodeId) -> usize {
        self.get(parent)
            .and_then(|p| p.chapters.first().copied())
            .or_else(|| self.chapters.iter().position(|c| c.passthrough.is_none()))
            .unwrap_or(0)
    }

    fn ensure_chapter(&mut self) {
        if self.chapters.is_empty() {
            self.chapters = vec![Chapter::standard()];
            self.get_mut(Self::ROOT).expect("root").chapters = BTreeSet::from([0]);
        }
    }

    fn insert(
        &mut self,
        mv: PlayedMove,
        position: ChessPosition,
        parent: NodeId,
        chapters: BTreeSet<usize>,
    ) -> NodeId {
        self.ensure_chapter();
        let id = self.nodes.len() as NodeId;
        let parent_ply = self.get(parent).map_or(0, |p| p.ply);
        let epd = position.epd();
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
            chapters,
        }));
        self.count += 1;
        if let Some(p) = self.get_mut(parent) {
            p.children.push(id);
        }
        self.epd_index.entry(epd).or_default().push(id);
        id
    }
}

fn append_unique(target: &mut Vec<String>, items: &[String]) {
    for item in items {
        if !target.contains(item) {
            target.push(item.clone());
        }
    }
}
