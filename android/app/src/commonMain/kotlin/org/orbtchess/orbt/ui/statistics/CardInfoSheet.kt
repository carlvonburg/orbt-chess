package org.orbtchess.orbt.ui.statistics

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.core.CardQueue
import org.orbtchess.orbt.core.CardType
import org.orbtchess.orbt.core.Graphs
import org.orbtchess.orbt.core.RevlogEntry
import org.orbtchess.orbt.core.RevlogReviewKind
import org.orbtchess.orbt.core.schedTiming
import org.orbtchess.orbt.storage.NodeId
import org.orbtchess.orbt.storage.RepertoireDocument
import org.orbtchess.orbt.ui.components.tabularDigits
import org.orbtchess.orbt.ui.theme.ThemeColor
import org.orbtchess.orbt.ui.theme.color
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/**
 * Anki's Card Info for the move at [node] (`CardInfoSheet.swift`): dates, interval, memory
 * state and history. The content of a Material bottom sheet the shell shows.
 */
@Composable
fun CardInfoSheet(
    app: AppModel,
    document: RepertoireDocument,
    node: NodeId,
    modifier: Modifier = Modifier,
) {
    // The review log, read when the sheet appears.
    var revlog by remember { mutableStateOf<List<RevlogEntry>>(emptyList()) }
    LaunchedEffect(document) { revlog = document.reviewLog() }
    val epd = document.tree[node]?.epd
    val card = epd?.let { document.sidecar.studyCards[it] }

    LazyColumn(modifier.fillMaxWidth()) {
        item {
            Text(
                "Move Info",
                style = MaterialTheme.typography.titleLarge,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp).semantics { heading() },
            )
        }
        if (epd == null || card == null) {
            item {
                Text(
                    "This move has not been studied yet.",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(24.dp),
                )
            }
            return@LazyColumn
        }
        val offset = ZoneId.systemDefault().rules.getOffset(Instant.now()).totalSeconds.toLong()
        val info = Graphs(listOf(card), 0, 0, revlog, schedTiming(), offset).cardInfo(card, epd)
        item {
            Text(
                document.tree.lineText(node).ifEmpty { "Starting position" },
                style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
            )
        }
        val rows = buildList {
            add("Added" to date(info.added * 1000))
            info.firstReview?.let { add("First review" to date(it)) }
            info.latestReview?.let { add("Latest review" to dateTime(it)) }
            info.due?.let { add("Due" to if (card.queue == CardQueue.LEARN) dateTime(it * 1000) else date(it * 1000)) }
            add("Interval" to if (card.ctype == CardType.REVIEW || card.ctype == CardType.RELEARN) "${info.interval} days" else "Learning")
            add("Reviews" to "${info.reps}")
            add("Lapses" to "${info.lapses}${if (card.leech == true) " (leech)" else ""}")
            add("Average time" to "%.1f s".format(info.averageMillis / 1000.0))
            add("Total time" to "%.0f s".format(info.totalMillis / 1000.0))
            info.memory?.let {
                add("Stability" to "%.1f days".format(it.stability))
                add("Difficulty" to "%.0f%%".format((it.difficulty - 1) / 9 * 100))
            }
            info.retrievability?.let { add("Retrievability" to percent(it)) }
        }
        items(rows) { (label, value) ->
            ListItem(
                headlineContent = { Text(label) },
                trailingContent = { Text(value, style = tabularDigits(MaterialTheme.typography.bodyMedium)) },
                colors = ListItemDefaults.colors(containerColor = Color.Transparent),
            )
        }
        item {
            HorizontalDivider(Modifier.padding(top = 8.dp))
            Text(
                "History",
                style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp).semantics { heading() },
            )
        }
        items(info.history.reversed(), key = { it.id }) { entry ->
            HistoryRow(entry)
        }
    }
}

@Composable
private fun HistoryRow(entry: RevlogEntry) {
    val style = tabularDigits(MaterialTheme.typography.bodySmall)
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp).semantics(mergeDescendants = true) {}) {
        Text(dateTime(entry.id), style = style)
        Spacer(Modifier.weight(1f))
        Text(kind(entry.kind), style = style, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(
            when (entry.ease) {
                1L -> "Again"
                0L -> "Manual"
                else -> "Good"
            },
            style = style,
            color = if (entry.ease == 1L) ThemeColor.wrong.color else MaterialTheme.colorScheme.onSurface,
            textAlign = TextAlign.End,
            modifier = Modifier.width(64.dp),
        )
    }
}

private fun date(millis: Long): String =
    Instant.ofEpochMilli(millis).atZone(ZoneId.systemDefault()).format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM))

private fun dateTime(millis: Long): String =
    Instant.ofEpochMilli(millis).atZone(ZoneId.systemDefault())
        .format(DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT))

private fun kind(type: RevlogReviewKind): String = when (type) {
    RevlogReviewKind.LEARNING -> "Learn"
    RevlogReviewKind.REVIEW -> "Review"
    RevlogReviewKind.RELEARNING -> "Relearn"
    RevlogReviewKind.FILTERED -> "Filtered"
    RevlogReviewKind.MANUAL -> "Manual"
    RevlogReviewKind.RESCHEDULED -> "Rescheduled"
}
