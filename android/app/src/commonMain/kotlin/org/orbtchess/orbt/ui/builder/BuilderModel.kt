package org.orbtchess.orbt.ui.builder

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import org.orbtchess.orbt.core.BoardSquare
import org.orbtchess.orbt.core.BuilderSession
import org.orbtchess.orbt.core.Changes
import org.orbtchess.orbt.core.CoverageGap
import org.orbtchess.orbt.core.Node
import org.orbtchess.orbt.core.PieceKind
import org.orbtchess.orbt.core.PlayedMove
import org.orbtchess.orbt.core.Position
import org.orbtchess.orbt.core.ReplyInfo
import org.orbtchess.orbt.core.Side
import org.orbtchess.orbt.core.opposite
import org.orbtchess.orbt.storage.NodeId
import org.orbtchess.orbt.storage.ROOT_NODE
import org.orbtchess.orbt.storage.RepertoireDocument
import org.orbtchess.orbt.ui.board.BoardArrow
import org.orbtchess.orbt.ui.board.toBoardArrow

/**
 * Build's state (`BuilderModel.swift`): the current node plus a draft of moves played on the
 * board that are not saved yet. The Rust core (`BuilderSession`) holds the state and the rules;
 * this forwards to it and hands what each action changed to the document. Made by the shell
 * before Build is shown and shared by its panes ([org.orbtchess.orbt.ui.components.BoardPane]).
 *
 * Every getter reads the document's revision and [stamp], so Compose redraws a view when the
 * session or the document changes.
 *
 * @param start the position to start from (null: the start of the repertoire).
 * @param showGaps open the gap list over the builder at first.
 */
class BuilderModel(
    val document: RepertoireDocument,
    val start: NodeId? = null,
    val showGaps: Boolean = false,
) {
    private val session = BuilderSession(document.core, start)
    private var closed = false

    /** Bumped after every action, so views re-read the session. */
    private var stamp by mutableIntStateOf(0)

    /** The sheet shown over Build (`BuilderPresentation.sheet`): the panel (or the whole screen) presents it. */
    var sheet: BuilderSheet? by mutableStateOf(if (showGaps) BuilderSheet.Gaps else null)

    /** Called by the shell when Build leaves the back stack: free the core session. */
    fun close() {
        if (closed) return
        closed = true
        session.close()
    }

    /** Reading this registers a view for the session's and the document's changes. */
    private fun observe() {
        stamp
        document.revision
    }

    private fun act(changes: Changes) {
        document.apply(changes)
        stamp++
    }

    val tree: RepertoireDocument.Tree get() = document.tree

    val current: NodeId get() { observe(); return session.current() }
    val node: Node? get() = tree[current]

    var orientation: Side
        get() { observe(); return session.orientation() }
        set(value) { session.setOrientation(value); stamp++ }

    fun flip() { orientation = orientation.opposite }

    /** Moves played past [current] that are not in the repertoire yet. */
    val draft: List<PlayedMove> get() { observe(); return session.draft() }
    val hasDraft: Boolean get() { observe(); return session.hasDraft() }

    /** Position on the board (after the draft), read once per change: views ask for it often. */
    val position: Position
        get() {
            observe()
            val key = stamp to document.revision
            cachedPosition?.let { (cachedKey, position) -> if (cachedKey == key) return position }
            return session.position().also { cachedPosition = key to it }
        }
    private var cachedPosition: Pair<Pair<Int, ULong>, Position>? = null

    /** When the current position's lines are stored at another node (a transposition), that node. */
    val continuation: NodeId? get() { observe(); return session.continuation() }

    /**
     * While a draft is on the board: a saved node with the same position whose lines continue
     * from it, i.e. the draft transposes into your repertoire.
     */
    val draftTransposition: NodeId? get() { observe(); return session.draftTransposition() }

    /**
     * The saved node with lines that [uci], played on the board, leads into by another move
     * order. Null when the move is your saved line itself, or reaches nothing you have.
     */
    fun transposition(after: String): NodeId? { observe(); return session.transpositionAfter(after) }

    /** The node whose moves the panels show: the current one, or where its lines continue. */
    val shownNode: Node? get() { observe(); return tree[session.shownNode()] }

    /** Not at the start position with nothing played on the board. */
    val canBack: Boolean get() = current != ROOT_NODE || hasDraft
    val canForward: Boolean get() { observe(); return session.canForward() }

    /** The main line ahead, as forward plays it (the move strip shows it after the current move). */
    val lineAhead: List<NodeId> get() { observe(); return session.lineAhead(40u) }
    val lastMove: PlayedMove? get() { observe(); return session.lastMove() }
    val isUserTurnOnBoard: Boolean get() { observe(); return session.isUserTurnOnBoard() }

    /** Biggest Gap has somewhere to go: not when the board shows it already (a new repertoire's first move). */
    val canGoToBiggestGap: Boolean get() { observe(); return session.canGoToBiggestGap() }

    /** Probability of reaching the board position. Null while a needed statistic is missing. */
    val reachOnBoard: Double? get() { observe(); return session.reachOnBoard() }

    /** Opponent replies at the board position while a draft is on it. */
    val draftReplies: List<ReplyInfo>? get() { observe(); return session.draftReplies() }

    /**
     * The draft is deep enough to save: every reply at the board position is rarer than the
     * coverage target (the panel's "Coverage target reached").
     */
    val draftReachedTarget: Boolean
        get() {
            if (isUserTurnOnBoard || reachOnBoard == null) return false
            val replies = draftReplies
            if (replies.isNullOrEmpty()) return false
            return replies.none { it.required }
        }

    /** Moves from the start to the board position, including the draft. */
    val movesToBoard: List<PlayedMove> get() { observe(); return session.movesToBoard() }

    /**
     * Arrows for the current node: your saved moves, or the opponent's replies sized by
     * frequency with missing required replies as dashed arrows.
     */
    val arrows: List<BoardArrow> get() { observe(); return session.arrows().map { it.toBoardArrow() } }

    // MARK: Navigation

    fun go(id: NodeId) = act(session.go(id))
    fun back() = act(session.back())
    fun forward() = act(session.forward())

    /** Switches to the previous/next sibling line (↑/↓ keys). */
    fun sibling(offset: Int) = act(session.sibling(offset.toLong()))

    /** A move made on the board: follows the repertoire if the move exists there, otherwise extends the draft. */
    fun play(from: BoardSquare, to: BoardSquare, promotion: PieceKind?) = act(session.play(from, to, promotion))

    fun play(uci: String) = act(session.playUci(uci))

    /** Previews a reply or candidate from the panel as a draft move. */
    fun preview(uci: String) = act(session.preview(uci))

    // MARK: Editing

    fun saveDraft() = act(session.saveDraft())

    fun discardDraft() {
        session.discardDraft()
        stamp++
    }

    /**
     * A line from the analysis board (its "back to Build", `AnalysisModel.Origin.Build`): its
     * saved moves are followed, the rest is the draft (`Builder::set_line`).
     */
    fun setLine(moves: List<PlayedMove>) {
        if (closed) return
        act(session.setLine(moves.map { it.uci }))
    }

    fun delete(id: NodeId) = act(session.delete(id))

    /** Undoes the last edit; the board stays on a saved position. */
    fun undo() = act(session.undo())

    /** Goes to the biggest gap below the current node, or in the whole repertoire. */
    fun goToBiggestGap() = act(session.goToBiggestGap())

    fun go(gap: CoverageGap) = act(session.goToGap(gap))
}

/** The sheets Build shows (`BuilderView.Sheet`); Move Info is the shell's Card Info sheet. */
enum class BuilderSheet { Outline, Gaps, Note }
