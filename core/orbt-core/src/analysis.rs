//! The analysis board's game: a line from the repertoire or a study, and the variations played
//! on it. Nothing here is saved; the builder takes the path to the selected move as its draft.
//!
//! Lichess's analysis board is the model: "promote variation" moves a variation up at its
//! nearest branch, "make main line" promotes it at every branch, "delete from here" removes a
//! move and what follows. The tree is an arena, and every walk uses a loop or a stack: a line
//! may be long, and the app calls the core on small stacks.

use crate::chess::{BoardSquare, ChessPosition, PieceKind, PlayedMove, Side};
use crate::pgn::{PgnGame, PgnMove, PgnTag, write_game};

pub type AnalysisNodeId = u32;

/// The root: the position the analysis starts from, before any move.
pub const ROOT: AnalysisNodeId = 0;

/// The best known evaluation of a node's position, from White's point of view.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NodeEval {
    /// "+0.3", "#-2".
    pub text: String,
    pub depth: u32,
}

struct Node {
    parent: Option<AnalysisNodeId>,
    mv: Option<PlayedMove>,
    position: ChessPosition,
    /// Ply index of the move (0 = White's first move); the root's is that of the first move.
    ply: usize,
    /// `children[0]` continues the line, the others are variations.
    children: Vec<AnalysisNodeId>,
    eval: Option<NodeEval>,
}

/// A move in the move list.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AnalysisMove {
    pub id: AnalysisNodeId,
    pub san: String,
    /// "3." before White's moves in a variation, "3…" before Black's where a variation or
    /// parenthesis starts; none in the main line's rows, which show the number once.
    pub number: Option<String>,
    pub eval: Option<String>,
    pub is_current: bool,
}

/// A row of the move list, laid out as lichess's mobile app does: the main line one full
/// move per row, and under a move with variations one row per variation.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MoveListRow {
    Main(MainRow),
    Variation(VariationRow),
}

/// One full move of the main line; a side is None where the line is cut ("…").
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MainRow {
    pub number: u32,
    pub white: Option<AnalysisMove>,
    pub black: Option<AnalysisMove>,
}

/// A variation: its moves, with a short one-line sub-variation inline in parentheses. Where
/// it branches otherwise, every continuation is a row of its own one level deeper.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VariationRow {
    /// One per level, outermost first: whether that level's guide goes on below this row
    /// (a later variation at that level follows). The last is this row's own: ├ or └.
    pub guides: Vec<bool>,
    pub tokens: Vec<MoveToken>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MoveToken {
    Move(AnalysisMove),
    Open,
    Close,
}

/// A sub-variation goes inline when it is the only one, has no branches of its own and is
/// this many plies or fewer (lichess mobile's rule).
const INLINE_PLIES: usize = 6;

pub struct AnalysisTree {
    nodes: Vec<Option<Node>>,
    start_fen: String,
    current: AnalysisNodeId,
    pub orientation: Side,
}

impl AnalysisTree {
    /// An analysis of `line` (UCI moves; it stops at an illegal one) from `start_fen`, with
    /// its last move selected. None if the FEN is invalid.
    pub fn new(start_fen: &str, line: &[String], orientation: Side) -> Option<AnalysisTree> {
        let position = ChessPosition::from_fen(start_fen)?;
        let ply = crate::pgn::start_ply(Some(start_fen));
        let mut tree = AnalysisTree {
            nodes: vec![Some(Node {
                parent: None,
                mv: None,
                position,
                ply,
                children: Vec::new(),
                eval: None,
            })],
            start_fen: start_fen.to_owned(),
            current: ROOT,
            orientation,
        };
        for uci in line {
            if tree.play_uci(uci).is_none() {
                break;
            }
        }
        Some(tree)
    }

    fn node(&self, id: AnalysisNodeId) -> Option<&Node> {
        self.nodes.get(id as usize)?.as_ref()
    }

    fn node_mut(&mut self, id: AnalysisNodeId) -> Option<&mut Node> {
        self.nodes.get_mut(id as usize)?.as_mut()
    }

    pub fn start_fen(&self) -> &str {
        &self.start_fen
    }

    pub fn current(&self) -> AnalysisNodeId {
        self.current
    }

    pub fn position(&self) -> ChessPosition {
        self.position_of(self.current)
    }

    pub fn position_of(&self, id: AnalysisNodeId) -> ChessPosition {
        self.node(id)
            .map(|node| node.position.clone())
            .unwrap_or_default()
    }

    /// The move that reached the selected position.
    pub fn last_move(&self) -> Option<PlayedMove> {
        self.node(self.current)?.mv.clone()
    }

    /// Selects `id`; false if it does not exist.
    pub fn go(&mut self, id: AnalysisNodeId) -> bool {
        if self.node(id).is_none() {
            return false;
        }
        self.current = id;
        true
    }

    pub fn back(&mut self) -> bool {
        match self.node(self.current).and_then(|node| node.parent) {
            Some(parent) => {
                self.current = parent;
                true
            }
            None => false,
        }
    }

    /// Follows the line on from the selected move.
    pub fn forward(&mut self) -> bool {
        match self
            .node(self.current)
            .and_then(|node| node.children.first())
        {
            Some(&child) => {
                self.current = child;
                true
            }
            None => false,
        }
    }

    /// Plays a move from the selected position: follows it if it was played before, otherwise
    /// adds it (as the line's continuation if there is none, else as a variation).
    pub fn play_uci(&mut self, uci: &str) -> Option<AnalysisNodeId> {
        let parent = self.current;
        let node = self.node(parent)?;
        let (played, position) = node.position.play_uci(uci)?;
        Some(self.add(parent, played, position))
    }

    pub fn play(
        &mut self,
        from: BoardSquare,
        to: BoardSquare,
        promotion: Option<PieceKind>,
    ) -> Option<AnalysisNodeId> {
        let parent = self.current;
        let node = self.node(parent)?;
        let (played, position) = node.position.play(from, to, promotion)?;
        Some(self.add(parent, played, position))
    }

    fn add(
        &mut self,
        parent: AnalysisNodeId,
        played: PlayedMove,
        position: ChessPosition,
    ) -> AnalysisNodeId {
        let existing = self.node(parent).and_then(|node| {
            node.children.iter().copied().find(|&child| {
                self.node(child)
                    .and_then(|c| c.mv.as_ref())
                    .is_some_and(|m| m.uci == played.uci)
            })
        });
        if let Some(child) = existing {
            self.current = child;
            return child;
        }
        let id = self.nodes.len() as AnalysisNodeId;
        let ply = self
            .node(parent)
            .map_or(0, |node| node.ply + usize::from(node.mv.is_some()));
        self.nodes.push(Some(Node {
            parent: Some(parent),
            mv: Some(played),
            position,
            ply,
            children: Vec::new(),
            eval: None,
        }));
        if let Some(node) = self.node_mut(parent) {
            node.children.push(id);
        }
        self.current = id;
        id
    }

    /// The nodes from the first move to `id`.
    pub fn path(&self, id: AnalysisNodeId) -> Vec<AnalysisNodeId> {
        let mut path = Vec::new();
        let mut cursor = Some(id);
        while let Some(node_id) = cursor {
            let Some(node) = self.node(node_id) else {
                break;
            };
            if node.mv.is_some() {
                path.push(node_id);
            }
            cursor = node.parent;
        }
        path.reverse();
        path
    }

    /// The moves from the start to `id`.
    pub fn moves(&self, id: AnalysisNodeId) -> Vec<PlayedMove> {
        self.path(id)
            .into_iter()
            .filter_map(|n| self.node(n)?.mv.clone())
            .collect()
    }

    /// The moves from the start to the selected position.
    pub fn moves_to_board(&self) -> Vec<PlayedMove> {
        self.moves(self.current)
    }

    /// The moves after the selected one along its line, for the move strip.
    pub fn line_ahead(&self) -> Vec<PlayedMove> {
        let mut moves = Vec::new();
        let mut cursor = self.current;
        while let Some(&next) = self.node(cursor).and_then(|n| n.children.first()) {
            if let Some(mv) = self.node(next).and_then(|n| n.mv.clone()) {
                moves.push(mv);
            }
            cursor = next;
        }
        moves
    }

    /// Whether `id` is on the main line (every move on its path is its parent's first).
    pub fn is_main_line(&self, id: AnalysisNodeId) -> bool {
        self.branch_point(id).is_none()
    }

    /// The deepest node on `id`'s path that is not its parent's first child.
    fn branch_point(&self, id: AnalysisNodeId) -> Option<AnalysisNodeId> {
        let mut cursor = id;
        loop {
            let parent = self.node(cursor)?.parent?;
            if self.node(parent)?.children.first() != Some(&cursor) {
                return Some(cursor);
            }
            cursor = parent;
        }
    }

    /// Lichess's "promote variation": the variation `id` is on replaces its line at the nearest
    /// branch. False if `id` is on the main line.
    pub fn promote(&mut self, id: AnalysisNodeId) -> bool {
        let Some(branch) = self.branch_point(id) else {
            return false;
        };
        let Some(parent) = self.node(branch).and_then(|n| n.parent) else {
            return false;
        };
        if let Some(node) = self.node_mut(parent) {
            node.children.retain(|&c| c != branch);
            node.children.insert(0, branch);
        }
        true
    }

    /// Promotes `id`'s variation at every branch, so it becomes the main line.
    pub fn make_main_line(&mut self, id: AnalysisNodeId) -> bool {
        let mut changed = false;
        while self.promote(id) {
            changed = true;
        }
        changed
    }

    /// Removes `id` and everything after it; the selection moves to its parent if it was in
    /// there. The root cannot be deleted.
    pub fn delete_from(&mut self, id: AnalysisNodeId) -> bool {
        let Some(parent) = self.node(id).and_then(|n| n.parent) else {
            return false;
        };
        if self.path_contains(self.current, id) {
            self.current = parent;
        }
        if let Some(node) = self.node_mut(parent) {
            node.children.retain(|&c| c != id);
        }
        let mut stack = vec![id];
        while let Some(next) = stack.pop() {
            if let Some(node) = self.nodes.get_mut(next as usize).and_then(Option::take) {
                stack.extend(node.children);
            }
        }
        true
    }

    fn path_contains(&self, id: AnalysisNodeId, ancestor: AnalysisNodeId) -> bool {
        let mut cursor = Some(id);
        while let Some(node_id) = cursor {
            if node_id == ancestor {
                return true;
            }
            cursor = self.node(node_id).and_then(|n| n.parent);
        }
        false
    }

    /// Keeps the deeper of the known and the new evaluation of `id`'s position.
    pub fn set_eval(&mut self, id: AnalysisNodeId, eval: NodeEval) {
        if let Some(node) = self.node_mut(id)
            && node
                .eval
                .as_ref()
                .is_none_or(|known| eval.depth >= known.depth)
        {
            node.eval = Some(eval);
        }
    }

    pub fn eval(&self, id: AnalysisNodeId) -> Option<&NodeEval> {
        self.node(id)?.eval.as_ref()
    }

    /// The move list (see `MoveListRow`), in PGN order.
    pub fn move_list(&self) -> Vec<MoveListRow> {
        let mut rows = Vec::new();
        let mut row: Option<MainRow> = None;
        let mut parent = ROOT;
        while let Some(&id) = self.node(parent).and_then(|n| n.children.first()) {
            let Some(node) = self.node(id) else { break };
            let number = full_move(node.ply);
            let mv = AnalysisMove {
                number: None,
                ..self.list_move(id, false)
            };
            match &mut row {
                Some(r)
                    if !node.ply.is_multiple_of(2) && r.number == number && r.black.is_none() =>
                {
                    r.black = Some(mv);
                }
                _ => {
                    rows.extend(row.take().map(MoveListRow::Main));
                    let white = node.ply.is_multiple_of(2);
                    row = Some(MainRow {
                        number,
                        black: (!white).then(|| mv.clone()),
                        white: white.then_some(mv),
                    });
                }
            }
            let siblings = self.node(parent).map_or(&[][..], |p| &p.children[1..]);
            if !siblings.is_empty() {
                rows.extend(row.take().map(MoveListRow::Main));
                self.variation_rows(siblings, &[], &mut rows);
            }
            parent = id;
        }
        rows.extend(row.map(MoveListRow::Main));
        rows
    }

    /// The rows of the variations starting at `starts`, one level below `guides`.
    fn variation_rows(
        &self,
        starts: &[AnalysisNodeId],
        guides: &[bool],
        rows: &mut Vec<MoveListRow>,
    ) {
        fn push(
            stack: &mut Vec<(AnalysisNodeId, Vec<bool>)>,
            ids: &[AnalysisNodeId],
            guides: &[bool],
        ) {
            for (i, &id) in ids.iter().enumerate().rev() {
                let mut level = guides.to_vec();
                level.push(i + 1 < ids.len());
                stack.push((id, level));
            }
        }
        let mut stack = Vec::new();
        push(&mut stack, starts, guides);
        while let Some((start, guides)) = stack.pop() {
            let mut tokens = vec![MoveToken::Move(self.list_move(start, true))];
            let mut cur = start;
            loop {
                let children = self.node(cur).map_or(&[][..], |n| &n.children[..]);
                match children {
                    [] => break,
                    [next] => {
                        cur = *next;
                        tokens.push(MoveToken::Move(self.list_move(cur, false)));
                    }
                    [next, side] if self.is_inline(*side) => {
                        tokens.push(MoveToken::Move(self.list_move(*next, false)));
                        tokens.push(MoveToken::Open);
                        let mut id = *side;
                        tokens.push(MoveToken::Move(self.list_move(id, true)));
                        while let Some(&child) = self.node(id).and_then(|n| n.children.first()) {
                            id = child;
                            tokens.push(MoveToken::Move(self.list_move(id, false)));
                        }
                        tokens.push(MoveToken::Close);
                        cur = *next;
                    }
                    _ => {
                        push(&mut stack, children, &guides);
                        break;
                    }
                }
            }
            rows.push(MoveListRow::Variation(VariationRow { guides, tokens }));
        }
    }

    fn is_inline(&self, mut id: AnalysisNodeId) -> bool {
        for _ in 0..INLINE_PLIES {
            match self.node(id).map_or(&[][..], |n| &n.children[..]) {
                [] => return true,
                [next] => id = *next,
                _ => return false,
            }
        }
        false
    }

    /// A move as the list shows it; `numbered` where a variation or parenthesis starts.
    fn list_move(&self, id: AnalysisNodeId, numbered: bool) -> AnalysisMove {
        let node = self.node(id);
        let ply = node.map_or(0, |n| n.ply);
        let number = if numbered || ply.is_multiple_of(2) {
            let dots = if ply.is_multiple_of(2) { "." } else { "…" };
            Some(format!("{}{dots}", full_move(ply)))
        } else {
            None
        };
        AnalysisMove {
            id,
            san: node
                .and_then(|n| n.mv.as_ref())
                .map(|m| m.san.clone())
                .unwrap_or_default(),
            number,
            eval: node.and_then(|n| n.eval.as_ref()).map(|e| e.text.clone()),
            is_current: id == self.current,
        }
    }

    /// The PGN of `id`'s line: the moves to it and the line on after it, without variations
    /// ("Copy variation PGN").
    pub fn line_pgn(&self, id: AnalysisNodeId) -> String {
        let mut ids = self.path(id);
        let mut cursor = id;
        while let Some(&next) = self.node(cursor).and_then(|n| n.children.first()) {
            ids.push(next);
            cursor = next;
        }
        let mut moves: Option<PgnMove> = None;
        for &node_id in ids.iter().rev() {
            let Some(mv) = self.node(node_id).and_then(|n| n.mv.as_ref()) else {
                continue;
            };
            let mut pgn_move = PgnMove::new(mv.san.clone());
            pgn_move.children.extend(moves.take());
            moves = Some(pgn_move);
        }
        self.pgn_with(moves.into_iter().collect())
    }

    /// The PGN of the whole analysis, variations included.
    pub fn pgn(&self) -> String {
        // Children are added after their parents, so building from the last id up finds every
        // child's PGN ready.
        let mut built: Vec<Option<PgnMove>> = (0..self.nodes.len()).map(|_| None).collect();
        for index in (0..self.nodes.len()).rev() {
            let Some(node) = &self.nodes[index] else {
                continue;
            };
            let children: Vec<PgnMove> = node
                .children
                .iter()
                .filter_map(|&c| built.get_mut(c as usize).and_then(Option::take))
                .collect();
            match &node.mv {
                Some(mv) => {
                    let mut pgn_move = PgnMove::new(mv.san.clone());
                    pgn_move.children = children;
                    built[index] = Some(pgn_move);
                }
                None => return self.pgn_with(children),
            }
        }
        self.pgn_with(Vec::new())
    }

    fn pgn_with(&self, moves: Vec<PgnMove>) -> String {
        let mut game = PgnGame {
            moves,
            result: "*".into(),
            ..PgnGame::default()
        };
        if self.start_fen != ChessPosition::START_FEN {
            game.tags = vec![
                PgnTag::new("SetUp", "1"),
                PgnTag::new("FEN", self.start_fen.clone()),
            ];
        }
        write_game(&game)
    }
}

fn full_move(ply: usize) -> u32 {
    u32::try_from(ply / 2 + 1).unwrap_or(u32::MAX)
}
