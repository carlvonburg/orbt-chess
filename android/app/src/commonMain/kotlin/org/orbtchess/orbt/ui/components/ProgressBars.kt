package org.orbtchess.orbt.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import org.orbtchess.orbt.core.Progress
import org.orbtchess.orbt.core.notStudied
import org.orbtchess.orbt.ui.theme.OrbtTheme
import org.orbtchess.orbt.ui.theme.ThemeColor
import org.orbtchess.orbt.ui.theme.color

/**
 * Coverage as a bar: the covered part in [ThemeColor.built] on the neutral track, so the track
 * is what is left (a gap, or lines not checked yet, is an empty bar). Material's own linear
 * progress indicator, without its stop indicator and gap (a single value, not a task's progress).
 */
@Composable
fun CoverageBar(value: Double, modifier: Modifier = Modifier, height: Dp = 6.dp) {
    val filled = value.coerceIn(0.0, 1.0).toFloat()
    LinearProgressIndicator(
        progress = { filled },
        modifier = modifier.fillMaxWidth().height(height)
            .semantics { contentDescription = "Coverage"; stateDescription = Format.percent(value) },
        color = ThemeColor.built.color,
        trackColor = MaterialTheme.colorScheme.surfaceContainerHighest,
        strokeCap = StrokeCap.Round,
        gapSize = 0.dp,
        drawStopIndicator = {},
    )
}

/**
 * Studied moves by Anki's groups over all your moves (`StudiedBar` in Swift): mature
 * ([ThemeColor.learned]), young (its lighter shade), learning ([ThemeColor.learning]); moves not
 * studied yet are the empty track. Material has no segmented progress bar, so it is drawn.
 */
@Composable
fun StudiedBar(progress: Progress, modifier: Modifier = Modifier, height: Dp = 6.dp) {
    SegmentedBar(
        segments = listOf(
            progress.mature to ThemeColor.learned,
            progress.young to ThemeColor.learned.lighter(),
            progress.learning to ThemeColor.learning,
        ),
        total = progress.cards,
        modifier = modifier.semantics {
            contentDescription = "Studied"
            stateDescription = "${progress.mature} mature, ${progress.young} young, " +
                "${progress.learning} learning, ${progress.notStudied} not studied"
        },
        height = height,
    )
}

/**
 * Counts as one bar of colored parts in order, over [total], on the neutral track: Anki's card
 * groups (`StudiedBar`, Statistics' moves bar). Each part is a meaning, never a hue.
 */
@Composable
fun SegmentedBar(
    segments: List<Pair<Long, ThemeColor>>,
    total: Long,
    modifier: Modifier = Modifier,
    height: Dp = 6.dp,
) {
    val colors = segments.map { it.second.color }
    val track = MaterialTheme.colorScheme.surfaceContainerHighest
    Canvas(modifier.fillMaxWidth().height(height).clip(RoundedCornerShape(50))) {
        drawRoundRect(track, cornerRadius = CornerRadius(size.height / 2))
        val sum = maxOf(total, 1L).toFloat()
        var x = 0f
        segments.forEachIndexed { i, (count, _) ->
            val width = size.width * count / sum
            if (width > 0f) drawRect(colors[i], topLeft = Offset(x, 0f), size = Size(width, size.height))
            x += width
        }
    }
}

/**
 * White / draw / black results, as in the Lichess explorer: each part shows its share when the
 * number fits in it. The parts are the pieces' colors (content, not meanings), the same in light
 * and dark appearance ([org.orbtchess.orbt.ui.theme.BoardTheme]).
 */
@Composable
fun ScoreBar(white: Long, draws: Long, black: Long, modifier: Modifier = Modifier) {
    val total = maxOf(white + draws + black, 1L)
    val board = OrbtTheme.board
    Row(
        modifier.fillMaxWidth().height(18.dp).clip(RoundedCornerShape(3.dp))
            .semantics {
                contentDescription =
                    "White ${white * 100 / total}%, draws ${draws * 100 / total}%, black ${black * 100 / total}%"
            },
    ) {
        ScorePart(white, total, board.whiteResult, board.resultText(board.whiteResult))
        ScorePart(draws, total, board.drawResult, board.resultText(board.drawResult))
        ScorePart(black, total, board.blackResult, board.resultText(board.blackResult))
    }
}

@Composable
private fun RowScope.ScorePart(games: Long, total: Long, fill: Color, text: Color) {
    if (games <= 0) return
    Box(
        Modifier.weight(games.toFloat() / total).fillMaxHeight().background(fill),
        contentAlignment = Alignment.Center,
    ) {
        val share = games.toDouble() / total
        // Only where the number fits (about 12% of a phone-wide bar).
        if (share >= 0.12) {
            Text(
                Format.percent(share),
                color = text,
                style = MaterialTheme.typography.labelSmall,
                maxLines = 1,
                modifier = Modifier.padding(horizontal = 2.dp),
            )
        }
    }
}
