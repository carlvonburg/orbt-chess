package org.orbtchess.orbt.ui.training

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.orbtchess.orbt.core.BoardSquare
import org.orbtchess.orbt.core.Counts
import org.orbtchess.orbt.core.DrillMode
import org.orbtchess.orbt.core.DrillSession
import org.orbtchess.orbt.core.Feedback
import org.orbtchess.orbt.core.Phase
import org.orbtchess.orbt.core.PieceKind
import org.orbtchess.orbt.core.PlayResult
import org.orbtchess.orbt.core.PlayedMove
import org.orbtchess.orbt.core.Position
import org.orbtchess.orbt.core.QueueKind
import org.orbtchess.orbt.core.Side
import org.orbtchess.orbt.core.schedTiming
import org.orbtchess.orbt.storage.NodeId
import org.orbtchess.orbt.storage.RepertoireDocument
import org.orbtchess.orbt.ui.board.BoardArrow
import org.orbtchess.orbt.ui.board.BoardBadge
import org.orbtchess.orbt.ui.board.toBoardArrow

/** The screen's title for a drill mode (`DrillMode.title`). */
val DrillMode.title: String
    get() = when (this) {
        DrillMode.Study -> "Study"
        is DrillMode.Branch -> "Study Branch"
    }

/**
 * Plays study lines one after another (`DrillModel` in DrillView.swift). The Rust core
 * (`DrillSession`) answers the cards and decides what happens next; this runs its timers: the
 * rewind and the opponent's moves step on a clock, the next line follows a finished one after a
 * countdown (or when Next is tapped), and a wrong move's feedback turns into a hint after a
 * moment. Made by the shell before Study is shown and shared by its panes.
 *
 * @param learnMore today's new limit raised by this many moves (Anki's custom study), or 0.
 */
class DrillModel(
    val document: RepertoireDocument,
    val mode: DrillMode,
    val learnMore: Int = 0,
) {
    private val session = DrillSession(document.core, mode)
    private val scope: CoroutineScope = MainScope()
    private var started = false
    private var closed = false
    private var timer: Job? = null
    private var wrongTimer: Job? = null
    private var badgeTimer: Job? = null

    /** When the next line starts on its own (unix ms); null while it waits for Next. */
    var nextLineAt: Long? by mutableStateOf(null)
        private set

    /** The line's end waits for Next: the user left the board to look at it, or the countdown is off. */
    private var waitsForNext = false

    /** Off with a screen reader, which gets no time limit (`autoAdvance` in Swift). */
    var autoAdvance = true

    /** Bumped after every change, so views re-read the session. */
    private var stamp by mutableIntStateOf(0)

    /** A tick or cross on the square the last answer moved to, shown for a moment. */
    var badge: BoardBadge? by mutableStateOf(null)
        private set

    /** A wrong move, left on the board for a moment before it is taken back. */
    private var wrongMove: PlayResult? by mutableStateOf(null)

    // The session's position, read once per change: the board gets the same object until it moves.
    private var cachedPosition: Pair<Int, Position>? = null

    private fun observe() {
        stamp
        document.revision
    }

    val color: Side get() = document.color
    val isFiltered: Boolean get() = session.isFiltered()
    val phase: Phase get() { observe(); return session.phase() }
    val finished: Boolean get() = phase == Phase.FINISHED
    val feedback: Feedback get() { observe(); return session.feedback() }
    val showHint: Boolean get() { observe(); return session.showHint() }
    /** Cards answered in this session. */
    val answeredCount: Int get() { observe(); return session.answeredCount().toInt() }
    /** Of those, answered Good. */
    val correctCount: Int get() { observe(); return session.correctCount().toInt() }
    /** Time spent answering: the sum of each answer's time, as in the review log. */
    val studiedMillis: Long get() { observe(); return session.studiedMillis() }
    val counts: Counts get() { observe(); return session.counts() }
    /** Unix seconds. */
    val nextLearningDue: Long? get() { observe(); return session.nextLearningDue() }

    val position: Position
        get() {
            observe()
            wrongMove?.let { return it.position }
            cachedPosition?.let { (at, position) -> if (at == stamp) return position }
            return session.position().also { cachedPosition = stamp to it }
        }
    val lastMove: PlayedMove? get() { observe(); return wrongMove?.mv ?: session.lastMove() }
    /** The moves on the board, from the start of the line. */
    val playedNodes: List<NodeId> get() { observe(); return session.playedNodes() }
    val openingName: String? get() { observe(); return session.currentNode()?.let { document.openingName(it) } }
    val isUserTurn: Boolean get() { observe(); return session.isUserTurn() }
    /** Whether the board takes a move: your turn, and no wrong move still on it. */
    val canMove: Boolean get() = isUserTurn && wrongMove == null

    /** The kind of card being asked, for highlighting its count. */
    val askedKind: QueueKind? get() { observe(); return session.askedKind() }

    val arrows: List<BoardArrow>
        get() { observe(); return if (wrongMove == null) session.arrows().map { it.toBoardArrow() } else emptyList() }

    fun start() {
        if (closed) return
        // Runs again when the board reappears (after browsing, or in another pane): resume the
        // opponent's moves if they were stopped, keep the session.
        if (!started) {
            started = true
            document.apply(session.start(learnMore.toLong(), schedTiming()))
        }
        changed()
    }

    fun stop() {
        timer?.cancel()
        timer = null
        nextLineAt = null
    }

    /** Leaving the board to look at it (analysis, browsing): the opponent's moves stop, and a
     *  finished line waits for Next when the user comes back ([start]). */
    private fun hold() {
        if (session.phase() == Phase.LINE_DONE) waitsForNext = true
        stop()
    }

    /** Stops the countdown at a line's end: it waits for Next. */
    fun pause() {
        if (session.phase() != Phase.LINE_DONE) return
        waitsForNext = true
        changed()
    }

    fun nextLine() {
        if (session.phase() != Phase.LINE_DONE) return
        timer?.cancel()
        timer = null
        badge = null
        session.nextLine(schedTiming())
        changed()
    }

    fun userMoved(from: BoardSquare, to: BoardSquare, promotion: PieceKind?) {
        val position = session.position()
        document.apply(session.userMoved(from, to, promotion, schedTiming(), nowMs()))
        when (session.feedback()) {
            is Feedback.Correct -> showBadge(BoardBadge.Kind.Correct, to)
            is Feedback.Wrong -> {
                showBadge(BoardBadge.Kind.Wrong, to)
                wrongMove = position.play(from, to, promotion)
                wrongTimer?.cancel()
                wrongTimer = scope.launch {
                    delay(1_200)
                    // Anki shows the answer: keep the arrow until the move is played.
                    session.wrongTimeout()
                    stamp++
                }
            }
            else -> Unit
        }
        changed(afterMove = true)
    }

    /** Shows the badge, and takes back a wrong move with it. */
    private fun showBadge(kind: BoardBadge.Kind, square: BoardSquare) {
        badge = BoardBadge(square, kind)
        badgeTimer?.cancel()
        badgeTimer = scope.launch {
            delay(700)
            badge = null
            wrongMove = null
        }
    }

    /** The node to open when the user browses the repertoire mid-line. Browsing on your own
     *  turn reveals the answer, so it counts as Again. */
    fun browseNode(): NodeId? {
        hold()
        val result = session.browseNode(schedTiming(), nowMs())
        document.apply(result.changes)
        changed()
        return result.node
    }

    fun hint() {
        document.apply(session.hint(schedTiming(), nowMs()))
        changed()
    }

    /** The moves to the board, for the analysis board. Looking counts as Again, like browsing. */
    fun analysisMoves(): List<PlayedMove> {
        hold()
        val result = session.analysisMoves(schedTiming(), nowMs())
        document.apply(result.changes)
        changed()
        return result.moves
    }

    /** Anki's custom study "Increase today's new card limit". */
    fun increaseNewLimit(count: Int) {
        document.apply(session.extendLimits(count.toLong(), 0, schedTiming()))
        changed()
    }

    /** Anki's custom study "Increase today's review card limit". */
    fun increaseReviewLimit(count: Int) {
        document.apply(session.extendLimits(0, count.toLong(), schedTiming()))
        changed()
    }

    /** Looks for cards again (learning cards that became due). */
    fun checkAgain() {
        session.checkAgain(schedTiming())
        changed()
    }

    /** Called by the shell when Study leaves the back stack: stops the clock, frees the core session. */
    fun close() {
        if (closed) return
        closed = true
        scope.cancel()
        session.close()
    }

    // MARK: Timing

    /**
     * Refreshes the views and runs the timer the new phase needs. [afterMove]: the user just
     * played, so the reply waits a little longer than the moves played on the way to their turn.
     */
    private fun changed(afterMove: Boolean = false) {
        if (closed) return
        stamp++
        timer?.cancel()
        timer = null
        nextLineAt = null
        val phase = session.phase()
        if (phase != Phase.LINE_DONE) waitsForNext = false
        val delayMs: Long = when (phase) {
            Phase.REWINDING -> 250
            Phase.AUTOPLAY -> if (afterMove) 600 else 450
            Phase.LINE_DONE -> {
                if (!autoAdvance || waitsForNext) return
                nextLineAt = nowMs() + LINE_DONE_MS
                LINE_DONE_MS
            }
            Phase.IDLE, Phase.USER_TURN, Phase.FINISHED -> return
        }
        timer = scope.launch {
            delay(delayMs)
            timer = null
            // The badge outlasts the opponent's reply, not the line.
            if (session.phase() != Phase.AUTOPLAY) badge = null
            if (session.phase() == Phase.LINE_DONE) session.nextLine(schedTiming()) else session.step(nowMs())
            changed()
        }
    }

    companion object {
        /** The pause at the end of a line, to look at it before the next one starts. */
        const val LINE_DONE_MS = 2_000L

        private fun nowMs() = System.currentTimeMillis()
    }
}
