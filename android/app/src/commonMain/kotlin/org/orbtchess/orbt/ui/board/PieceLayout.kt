package org.orbtchess.orbt.ui.board

import androidx.compose.runtime.Immutable
import org.jetbrains.compose.resources.DrawableResource
import org.orbtchess.orbt.core.BoardSquare
import org.orbtchess.orbt.core.PieceKind
import org.orbtchess.orbt.core.Position
import org.orbtchess.orbt.core.Side
import org.orbtchess.orbt.core.file
import org.orbtchess.orbt.core.rank
import orbt.app.generated.resources.Res
import orbt.app.generated.resources.piece_bb
import orbt.app.generated.resources.piece_bk
import orbt.app.generated.resources.piece_bn
import orbt.app.generated.resources.piece_bp
import orbt.app.generated.resources.piece_bq
import orbt.app.generated.resources.piece_br
import orbt.app.generated.resources.piece_wb
import orbt.app.generated.resources.piece_wk
import orbt.app.generated.resources.piece_wn
import orbt.app.generated.resources.piece_wp
import orbt.app.generated.resources.piece_wq
import orbt.app.generated.resources.piece_wr
import kotlin.math.abs

/**
 * The piece set: lichess's "cburnett" (Colin M.L. Burnett, GPLv2+), the Apple app's
 * `Assets.xcassets/Pieces` converted to vector drawables in `composeResources/drawable`.
 */
internal fun pieceDrawable(side: Side, kind: PieceKind): DrawableResource = when (side) {
    Side.WHITE -> when (kind) {
        PieceKind.PAWN -> Res.drawable.piece_wp
        PieceKind.KNIGHT -> Res.drawable.piece_wn
        PieceKind.BISHOP -> Res.drawable.piece_wb
        PieceKind.ROOK -> Res.drawable.piece_wr
        PieceKind.QUEEN -> Res.drawable.piece_wq
        PieceKind.KING -> Res.drawable.piece_wk
    }
    Side.BLACK -> when (kind) {
        PieceKind.PAWN -> Res.drawable.piece_bp
        PieceKind.KNIGHT -> Res.drawable.piece_bn
        PieceKind.BISHOP -> Res.drawable.piece_bb
        PieceKind.ROOK -> Res.drawable.piece_br
        PieceKind.QUEEN -> Res.drawable.piece_bq
        PieceKind.KING -> Res.drawable.piece_bk
    }
}

internal val PieceKind.title: String get() = name.lowercase().replaceFirstChar { it.uppercase() }

/**
 * Keeps a stable identity per piece across positions so moves slide instead of fading
 * (`PieceLayout` in BoardView.swift). Not observable state: the board updates it once per position.
 */
internal class PieceLayout {
    @Immutable
    data class Placed(val id: Int, val side: Side, val kind: PieceKind, val square: BoardSquare)

    /** One update: the pieces now, where those that moved came from, and those that left. */
    @Immutable
    class Update(
        val pieces: List<Placed>,
        val movedFrom: Map<Int, BoardSquare>,
        val added: Set<Int>,
        val removed: List<Placed>,
        /** Slide and fade (false for the first position, and for a move dropped by dragging). */
        val animated: Boolean,
    )

    private var pieces: List<Placed> = emptyList()
    private var nextId = 0

    fun update(position: Position, animated: Boolean): Update {
        val old = pieces.associateBy { it.id }
        val unmatchedOld = pieces.toMutableList()
        val result = mutableListOf<Placed>()
        val unmatchedNew = mutableListOf<org.orbtchess.orbt.core.BoardPiece>()
        for (piece in position.pieces()) {
            val i = unmatchedOld.indexOfFirst { it.square == piece.square && it.side == piece.side && it.kind == piece.kind }
            if (i >= 0) result += unmatchedOld.removeAt(i) else unmatchedNew += piece
        }
        val added = mutableSetOf<Int>()
        for (piece in unmatchedNew) {
            // The same piece, or a pawn that promoted, nearest first.
            val best = unmatchedOld
                .filter { it.side == piece.side && (it.kind == piece.kind || it.kind == PieceKind.PAWN) }
                .minByOrNull { distance(it.square, piece.square) }
            if (best != null) {
                unmatchedOld.remove(best)
                result += Placed(best.id, piece.side, piece.kind, piece.square)
            } else {
                result += Placed(nextId, piece.side, piece.kind, piece.square)
                added += nextId
                nextId += 1
            }
        }
        pieces = result
        val movedFrom = result.mapNotNull { p -> old[p.id]?.takeIf { it.square != p.square }?.let { p.id to it.square } }.toMap()
        return Update(result, movedFrom, added, unmatchedOld, animated)
    }

    private fun distance(a: BoardSquare, b: BoardSquare): Int = abs(a.file - b.file) + abs(a.rank - b.rank)
}
