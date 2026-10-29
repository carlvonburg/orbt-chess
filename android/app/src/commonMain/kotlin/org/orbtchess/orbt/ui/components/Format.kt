package org.orbtchess.orbt.ui.components

import org.orbtchess.orbt.core.PlayedMove
import java.text.NumberFormat
import kotlin.math.roundToInt

/** Numbers and moves as the screens show them (`Format` in Components.swift). */
object Format {
    /** "every game", "1 in 400", or a dash when the position is never reached. */
    fun seenEvery(reach: Double?): String {
        if (reach == null || reach <= 0) return "—"
        val n = 1 / reach
        if (n < 1.5) return "every game"
        return "1 in ${NumberFormat.getIntegerInstance().format(n.roundToInt())}"
    }

    fun percent(value: Double): String = NumberFormat.getPercentInstance().apply { maximumFractionDigits = 0 }.format(value)

    /** "1. d4 d5 2. c4 c6", numbered from [startPly] (0 = White's first move). */
    fun moveList(moves: List<PlayedMove>, startPly: Int = 0): String =
        org.orbtchess.orbt.core.moveList(moves, startPly.toUInt())

    /** Game counts: 950, 12k, 3.4M, 1.2B. */
    fun games(n: Long): String = when {
        n >= 1_000_000_000 -> "%.1fB".format(n / 1_000_000_000.0)
        n >= 100_000_000 -> "${n / 1_000_000}M"
        n >= 1_000_000 -> "%.1fM".format(n / 1_000_000.0)
        n >= 10_000 -> "${n / 1000}k"
        else -> NumberFormat.getIntegerInstance().format(n)
    }
}
