package org.orbtchess.orbt.ui.analysis

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import org.orbtchess.orbt.core.AnalysisSession
import org.orbtchess.orbt.core.BoardSquare
import org.orbtchess.orbt.core.MoveListRow
import org.orbtchess.orbt.core.MoveToken
import org.orbtchess.orbt.core.NodeEval
import org.orbtchess.orbt.core.PieceKind
import org.orbtchess.orbt.core.PlayedMove
import org.orbtchess.orbt.core.Position
import org.orbtchess.orbt.core.Side
import org.orbtchess.orbt.engine.EngineService
import org.orbtchess.orbt.storage.ROOT_NODE
import org.orbtchess.orbt.storage.RepertoireDocument
import org.orbtchess.orbt.ui.builder.BuilderModel

/**
 * The analysis board (`AnalysisModel.swift`): the line from Build or Study, and the variations
 * played on it. The Rust core (`AnalysisSession`) holds the tree; nothing is saved. Made by the
 * shell from a [org.orbtchess.orbt.ui.Destination.Analysis]; going back to Build puts the line to
 * the selected move on the builder as an unsaved draft, going back to Study drops it.
 *
 * Views read [state], re-read from the session after every action, so a pane still animating
 * away after [close] never calls the freed session.
 *
 * @param startFen the position the moves are played from; null: the repertoire's start.
 */
class AnalysisModel(
    val document: RepertoireDocument,
    val startFen: String?,
    val moves: List<PlayedMove>,
    val orientation: Side,
    val origin: Origin,
) {
    /** Where the board was opened from. */
    sealed interface Origin {
        /** Build: [finish] hands the line to this builder as its draft (`Builder::set_line`). */
        class Build(val builder: BuilderModel) : Origin

        /** Study: [finish] drops the line. */
        data object Study : Origin
    }

    /** What the views show, read from the session after each action. */
    class State(
        val startFen: String,
        val current: UInt,
        val position: Position,
        val orientation: Side,
        val lastMove: PlayedMove?,
        val movesToBoard: List<PlayedMove>,
        /** The move list: the main line cut where variations branch off, variations indented. */
        val moveList: List<MoveListRow>,
        /** The moves ahead on the line forward follows (each move's first child). */
        val lineAhead: List<PlayedMove>,
    ) {
        val canBack: Boolean get() = current != 0u
        val canForward: Boolean get() = lineAhead.isNotEmpty()

        /** What the engine analyses: the position on the board. */
        val engineKey: EngineService.Key get() = EngineService.Key(startFen, movesToBoard.map { it.uci })

        /** The ply before the first move: the start position's (from its FEN's side and move number). */
        val startPly: Int
            get() {
                val fields = startFen.split(" ")
                val number = fields.getOrNull(5)?.toIntOrNull() ?: return 0
                return (number - 1) * 2 + if (fields[1] == "b") 1 else 0
            }

        /** The move list's row holding the move on the board, null at the start. */
        val currentRow: Int?
            get() = moveList.indexOfFirst { row ->
                when (row) {
                    is MoveListRow.Main -> row.v1.white?.isCurrent == true || row.v1.black?.isCurrent == true
                    is MoveListRow.Variation -> row.v1.tokens.any { it is MoveToken.Move && it.v1.isCurrent }
                }
            }.takeIf { it >= 0 }
    }

    private val session = AnalysisSession(
        startFen ?: document.tree.position(ROOT_NODE)?.fen(),
        moves.map { it.uci },
        orientation,
    )
    private var finished = false
    private var closed = false

    var state: State by mutableStateOf(read())
        private set

    /** The engine's lines and arrows (the cloud eval and Stockfish). */
    var engineOn by mutableStateOf(true)

    /** The engine's settings over the board. On wide windows the board pane's menu sets it and the panel presents it. */
    var showsSettings by mutableStateOf(false)

    private fun read(): State = State(
        startFen = session.startFen(),
        current = session.current(),
        position = session.position(),
        orientation = session.orientation(),
        lastMove = session.lastMove(),
        movesToBoard = session.movesToBoard(),
        moveList = session.moveList(),
        lineAhead = session.lineAhead(),
    )

    /** Runs an action on the session, re-reading it when it changed something. */
    private fun act(action: () -> Boolean) {
        if (closed) return
        if (action()) state = read()
    }

    fun isMainLine(id: UInt): Boolean = !closed && session.isMainLine(id)

    // MARK: Moves

    fun play(from: BoardSquare, to: BoardSquare, promotion: PieceKind?) = act { session.play(from, to, promotion) }
    fun play(uci: String) = act { session.playUci(uci) }
    fun go(id: UInt) = act { session.go(id) }
    fun back() = act { session.back() }
    fun forward() = act { session.forward() }

    /**
     * Goes to the move [plies] half-moves into the history strip's line: back along the moves
     * to the board, or forward along the line ahead (0: the start).
     */
    fun goToPly(plies: Int) = act {
        val here = session.movesToBoard().size
        var changed = false
        if (plies < here) {
            repeat(here - plies) { changed = session.back() || changed }
        } else {
            repeat(plies - here) { changed = session.forward() || changed }
        }
        changed
    }

    fun promote(id: UInt) = act { session.promote(id) }
    fun makeMainLine(id: UInt) = act { session.makeMainLine(id) }
    fun deleteFrom(id: UInt) = act { session.deleteFrom(id) }

    fun flip() = act {
        session.setOrientation(if (session.orientation() == Side.WHITE) Side.BLACK else Side.WHITE)
        true
    }

    /** Records the engine's evaluation of the position on the board for the move list. */
    fun setEval(eval: NodeEval) = act {
        session.setEval(eval)
        true
    }

    fun linePgn(id: UInt): String = if (closed) "" else session.linePgn(id)
    fun pgn(): String = if (closed) "" else session.pgn()

    /**
     * Called by the shell when the board is popped (not when something covers it): Build gets
     * the line to the selected move as its draft (saved moves are followed, nothing is
     * written); Study drops it.
     */
    fun finish() {
        if (finished || closed) return
        finished = true
        (origin as? Origin.Build)?.builder?.setLine(state.movesToBoard)
    }

    /** Called by the shell after [finish]: free the core session (the screen stops the engine). */
    fun close() {
        if (closed) return
        closed = true
        session.close()
    }
}
