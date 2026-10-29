package org.orbtchess.orbt.ui.board

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.ImageComposeScene
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.unit.Density
import androidx.compose.ui.use
import org.jetbrains.skia.EncodedImageFormat
import org.orbtchess.orbt.core.BoardSquare
import org.orbtchess.orbt.core.PieceKind
import org.orbtchess.orbt.core.PlayedMove
import org.orbtchess.orbt.core.Position
import org.orbtchess.orbt.core.Side
import org.orbtchess.orbt.core.boardSquare
import org.orbtchess.orbt.core.notation
import org.orbtchess.orbt.core.positionFromFen
import org.orbtchess.orbt.ui.theme.AppColor
import org.orbtchess.orbt.ui.theme.OrbtTheme
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals

/**
 * The board in an offscreen scene: tap-tap, drag and promotion reach `onMove`, the position
 * follows, and with `ORBT_BOARD_SNAPSHOTS=<dir>` the frames are written as PNGs to look at.
 */
class BoardTest {
    private val size = 640
    private val sq = size / 8f

    private fun center(square: String, orientation: Side = Side.WHITE): Offset {
        val file = square[0] - 'a'
        val rank = square[1] - '1'
        val col = if (orientation == Side.WHITE) file else 7 - file
        val row = if (orientation == Side.WHITE) 7 - rank else rank
        return Offset(col * sq + sq / 2, row * sq + sq / 2)
    }

    private class Harness(start: Position) {
        var position by mutableStateOf(start)
        var lastMove by mutableStateOf<PlayedMove?>(null)
        val moves = mutableListOf<String>()
        fun play(from: BoardSquare, to: BoardSquare, promotion: PieceKind?) {
            val result = position.play(from, to, promotion) ?: return
            moves += result.mv.uci
            lastMove = result.mv
            position = result.position
        }
    }

    private var time = 0L
    private fun ImageComposeScene.frame(name: String? = null) {
        time += 16_000_000L
        val image = render(time)
        val dir = System.getenv("ORBT_BOARD_SNAPSHOTS") ?: return
        if (name == null) return
        File(dir, "$name.png").writeBytes(image.encodeToData(EncodedImageFormat.PNG)!!.bytes)
    }

    private fun ImageComposeScene.settle(name: String? = null) {
        repeat(30) { frame() }
        frame(name)
    }

    private fun ImageComposeScene.tap(at: Offset) {
        sendPointerEvent(PointerEventType.Press, at)
        frame()
        sendPointerEvent(PointerEventType.Release, at)
        frame()
    }

    private fun ImageComposeScene.drag(from: Offset, to: Offset) {
        sendPointerEvent(PointerEventType.Press, from)
        frame()
        for (i in 1..10) {
            sendPointerEvent(PointerEventType.Move, from + (to - from) * (i / 10f))
            frame()
        }
        sendPointerEvent(PointerEventType.Release, to)
        frame()
    }

    private fun scene(h: Harness, orientation: Side = Side.WHITE, arrows: List<BoardArrow> = emptyList(), badge: BoardBadge? = null, dark: Boolean = false) =
        ImageComposeScene(size, size, Density(2f)) {
            OrbtTheme(AppColor.Default, darkTheme = dark) {
                Board(
                    position = h.position,
                    orientation = orientation,
                    lastMove = h.lastMove,
                    arrows = arrows,
                    badge = badge,
                    movableSide = h.position.sideToMove(),
                    onMove = h::play,
                )
            }
        }

    @Test
    fun tapTapAndDragPlayMoves() {
        val h = Harness(Position.start())
        scene(h).use { scene ->
            scene.settle("start")
            scene.tap(center("e2"))
            scene.settle("selected")
            scene.tap(center("e4"))
            scene.frame("sliding")
            scene.settle("e4")
            assertEquals(listOf("e2e4"), h.moves)
            scene.drag(center("g8"), center("f6"))
            scene.settle("nf6")
            assertEquals(listOf("e2e4", "g8f6"), h.moves)
            // A tap on an opponent's piece selects nothing; an illegal target clears the selection.
            scene.tap(center("f6"))
            scene.tap(center("d1"))
            scene.tap(center("d5"))
            scene.settle()
            assertEquals(2, h.moves.size)
        }
    }

    @Test
    fun promotionAsksForThePiece() {
        val h = Harness(positionFromFen("8/4P3/8/8/8/8/k7/4K3 w - - 0 1")!!)
        scene(h).use { scene ->
            scene.settle()
            scene.tap(center("e7"))
            scene.tap(center("e8"))
            scene.settle("promotion")
            assertEquals(emptyList(), h.moves)
            // Queen, knight, rook, bishop from the promotion square down.
            scene.tap(center("e6"))
            scene.settle("promoted")
            assertEquals(listOf("e7e8r"), h.moves)
        }
    }

    @Test
    fun blackOrientationArrowsAndBadge() {
        val h = Harness(Position.start())
        h.play(boardSquare(4, 1), boardSquare(4, 3), null)
        val arrows = listOf(
            BoardArrow(sq("e7"), sq("e5"), BoardArrow.Style.Opponent, width = 0.18, opacity = 0.85),
            BoardArrow(sq("c7"), sq("c5"), BoardArrow.Style.Gap, width = 0.12, opacity = 0.6, dashed = true),
            BoardArrow(sq("g8"), sq("f6"), BoardArrow.Style.Mine, width = 0.1, opacity = 0.38),
            BoardArrow(sq("d7"), sq("d5"), BoardArrow.Style.Engine, width = 0.14, opacity = 0.7),
        )
        for (dark in listOf(false, true)) {
            scene(h, Side.BLACK, arrows, BoardBadge(sq("e4"), BoardBadge.Kind.Correct), dark).use { scene ->
                scene.settle(if (dark) "black-dark" else "black")
                scene.tap(center("e7", Side.BLACK))
                scene.settle(if (dark) "black-dark-selected" else "black-selected")
            }
        }
        scene(h, Side.WHITE, badge = BoardBadge(sq("e4"), BoardBadge.Kind.Wrong)).use { it.settle("wrong") }
        assertNotEquals(null, h.lastMove)
    }

    private fun sq(name: String) = boardSquare(name[0] - 'a', name[1] - '1').also { assertEquals(name, it.notation) }
}
