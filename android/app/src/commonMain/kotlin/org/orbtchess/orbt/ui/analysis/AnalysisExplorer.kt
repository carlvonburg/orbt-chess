package org.orbtchess.orbt.ui.analysis

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.HourglassEmpty
import androidx.compose.material.icons.outlined.WifiOff
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.core.CloudEval
import org.orbtchess.orbt.core.ExplorerMove
import org.orbtchess.orbt.core.ExplorerStats
import org.orbtchess.orbt.core.QueueState
import org.orbtchess.orbt.core.cloudEvalText
import org.orbtchess.orbt.ui.Destination
import org.orbtchess.orbt.ui.components.Format
import org.orbtchess.orbt.ui.components.ScoreBar
import org.orbtchess.orbt.ui.components.SymbolLabel
import org.orbtchess.orbt.ui.components.tabularDigits

/**
 * The explorer's moves in the position, laid out as Build's candidates: the opening name, an
 * "Explorer" heading, then a row per move (tap one to play it). Items of a lazy list.
 *
 * @param showsHeader the opening name and heading; off under the phone's Explorer/Moves
 *   control, which already names it.
 * @param eval the Lichess cloud eval of the position, for each move's evaluation.
 */
internal fun LazyListScope.analysisExplorer(
    app: AppModel,
    model: AnalysisModel,
    stats: ExplorerStats?,
    eval: CloudEval?,
    showsHeader: Boolean,
    navigate: (Destination) -> Unit,
) {
    if (showsHeader) {
        stats?.opening?.name?.let { name ->
            item {
                Text(
                    name,
                    style = MaterialTheme.typography.titleSmall,
                    maxLines = 2,
                    modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 8.dp),
                )
            }
        }
        item { Heading("Explorer") }
    }
    when {
        stats != null -> {
            val total = stats.white + stats.draws + stats.black
            stats.moves.take(12).forEach { move ->
                item(key = move.uci) {
                    ExplorerRow(move, total, eval?.let { cloudEvalText(it, move.uci) }) { model.play(move.uci) }
                }
            }
            if (stats.moves.isEmpty()) {
                item {
                    Text(
                        "No games in this position.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                    )
                }
            }
        }
        app.isLoadingStats -> repeat(4) { item { PlaceholderRow() } }
        else -> item { StatsUnavailable(app, navigate) }
    }
}

/** A panel's heading (Explorer, Moves), as Build's. */
@Composable
internal fun Heading(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.titleMedium,
        modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 4.dp),
    )
}

/** One explorer move: the move, the cloud eval after it, the results bar, games and share. */
@Composable
private fun ExplorerRow(move: ExplorerMove, total: Long, eval: String?, select: () -> Unit) {
    val games = move.white + move.draws + move.black
    Row(
        Modifier.fillMaxWidth().clickable(onClick = select).padding(horizontal = 16.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(move.san, fontWeight = FontWeight.SemiBold, modifier = Modifier.widthIn(min = 48.dp))
        Text(
            eval ?: "",
            style = tabularDigits(MaterialTheme.typography.labelSmall),
            fontWeight = FontWeight.SemiBold,
            textAlign = TextAlign.Center,
            modifier = Modifier.width(40.dp),
        )
        ScoreBar(move.white, move.draws, move.black, Modifier.weight(1f))
        // Games and share of games side by side, as in the Lichess explorer.
        val share = Format.percent(if (total > 0) games.toDouble() / total else 0.0)
        Text(
            buildAnnotatedString {
                withStyle(SpanStyle(color = MaterialTheme.colorScheme.onSurface)) { append(Format.games(games)) }
                append(" · $share")
            },
            style = tabularDigits(MaterialTheme.typography.labelSmall),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            textAlign = TextAlign.End,
            modifier = Modifier.width(76.dp),
        )
    }
}

/** Stands in for an explorer move while the stats load. */
@Composable
private fun PlaceholderRow() {
    val fill = MaterialTheme.colorScheme.surfaceContainerHighest
    Row(
        Modifier.fillMaxWidth().clearAndSetSemantics {}.padding(horizontal = 16.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.width(36.dp).height(16.dp).clip(RoundedCornerShape(4.dp)).background(fill))
        Box(Modifier.width(52.dp))
        Box(Modifier.weight(1f).height(18.dp).clip(RoundedCornerShape(3.dp)).background(fill))
        Box(Modifier.width(76.dp).height(12.dp).clip(RoundedCornerShape(4.dp)).background(fill))
    }
}

/** Stats for the position on screen are on their way: signed in, and not paused by Lichess or offline. */
private val AppModel.isLoadingStats: Boolean
    get() = auth.isSignedIn && when (explorer.state) {
        QueueState.NeedsLogin, QueueState.Offline, is QueueState.RateLimited -> false
        else -> true
    }

/** Why there are no stats: offline, slowed down by Lichess, or not signed in (Settings signs in). */
@Composable
private fun StatsUnavailable(app: AppModel, navigate: (Destination) -> Unit) {
    val modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)
    val style = MaterialTheme.typography.bodySmall
    when {
        app.explorer.state == QueueState.Offline ->
            SymbolLabel("Offline. Statistics will load when you're back online.", Icons.Outlined.WifiOff, modifier, style = style)
        app.explorer.state is QueueState.RateLimited ->
            SymbolLabel("Lichess asked us to slow down. Resuming in a minute.", Icons.Outlined.HourglassEmpty, modifier, style = style)
        app.auth.isSignedIn && app.explorer.state != QueueState.NeedsLogin -> Row(
            modifier,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
            Text("Loading statistics…", style = style, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        else -> TextButton(onClick = { navigate(Destination.Settings) }, modifier = Modifier.padding(horizontal = 4.dp)) {
            Text("Sign in with Lichess")
        }
    }
}
