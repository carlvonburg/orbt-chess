package org.orbtchess.orbt.ui.training

import androidx.compose.runtime.setValue
import androidx.compose.runtime.getValue
import org.orbtchess.orbt.ui.components.ExpressiveMenu
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.LocalFireDepartment
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.CalendarToday
import androidx.compose.material.icons.outlined.Inbox
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.ui.tour.TourGuide
import org.orbtchess.orbt.core.SchedTiming
import org.orbtchess.orbt.core.Streak
import org.orbtchess.orbt.core.notStudied
import org.orbtchess.orbt.core.studied
import org.orbtchess.orbt.core.schedTiming
import org.orbtchess.orbt.ui.Destination
import org.orbtchess.orbt.ui.components.Format
import org.orbtchess.orbt.ui.library.TodaySummary
import org.orbtchess.orbt.ui.components.StudiedBar
import org.orbtchess.orbt.ui.components.SymbolLabel
import org.orbtchess.orbt.ui.components.tabularDigits
import org.orbtchess.orbt.ui.theme.ThemeColor
import org.orbtchess.orbt.ui.theme.color
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.time.temporal.ChronoUnit
import kotlin.math.roundToInt

/**
 * The end of a study session (`StudyFinishedView.swift`): this session's result, the streak,
 * the repertoire's progress and what comes next, with the actions at the bottom (the next
 * repertoire in Study All, Study More Today). Shown by [DrillScreen] in place of the board when
 * the session ends, not navigated to; closing is the top app bar's back arrow, so there is no
 * Done button.
 *
 * @param next the next repertoire when studying all of them.
 * @param navigate unused for now: Study More Today extends this session in place, as in Swift.
 * @param onDone back to where Study was opened from.
 * @param tourEnd the tour's Study step is done: its next step is the user's own repertoire.
 */
@Composable
fun StudyFinishedScreen(
    app: AppModel,
    model: DrillModel,
    next: NextRepertoire?,
    navigate: (Destination) -> Unit,
    onDone: () -> Unit,
    modifier: Modifier = Modifier,
    tourEnd: Boolean = false,
) {
    val document = model.document
    val studied = model.answeredCount > 0
    val timing = schedTiming()
    val laterToday = document.sidecar.laterLearningDues(timing).filter { isToday(it) }
    // The core's streak over every repertoire's review log, as the library's Today card shows it.
    val streak by produceState(TodaySummary.empty.streak, app) { value = TodaySummary.load(app).streak }

    Column(modifier.fillMaxSize()) {
        Column(
            Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Column(Modifier.widthIn(max = 560.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Header(model, studied, learningLater = laterToday.isNotEmpty(), streak)
                if (studied) SessionTiles(model)
                ProgressCard(model)
                NextCard(model, laterToday, timing)
            }
        }
        if (tourEnd) TourEndActions(app) else Actions(model, next)
    }
}

// MARK: Content

@Composable
private fun Header(model: DrillModel, studied: Boolean, learningLater: Boolean, streak: Streak) {
    Column(
        Modifier.fillMaxWidth().padding(top = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        val fill = if (studied) ThemeColor.learned.container.color else MaterialTheme.colorScheme.surfaceContainerHighest
        Box(Modifier.size(64.dp).background(fill, CircleShape), contentAlignment = Alignment.Center) {
            Icon(
                if (studied) Icons.Filled.Check else Icons.Outlined.Inbox,
                contentDescription = null,
                tint = if (studied) ThemeColor.learned.onContainer.color else MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(32.dp),
            )
        }
        Text(
            when {
                !studied -> "Nothing to Study"
                learningLater -> "Done for Now"
                else -> "Done for Today"
            },
            style = MaterialTheme.typography.headlineSmall,
            textAlign = TextAlign.Center,
        )
        if (!studied) {
            Text(
                if (model.isFiltered) "There are no moves in this branch yet." else "No moves are due right now.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
        }
        if (streak.current > 0) {
            // At risk until something is studied today.
            SymbolLabel("${streak.current}-day streak", Icons.Filled.LocalFireDepartment, meaning = ThemeColor.todo)
        }
    }
}

@Composable
private fun SessionTiles(model: DrillModel) {
    val answered = model.answeredCount
    val minutes = (model.studiedMillis / 60_000.0).roundToInt()
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Tile(answered.toString(), if (answered == 1) "move" else "moves")
        Tile(Format.percent(model.correctCount.toDouble() / answered), "correct", ThemeColor.correct.color)
        Tile(if (minutes < 1) "<1 min" else "$minutes min", "time")
    }
}

@Composable
private fun androidx.compose.foundation.layout.RowScope.Tile(value: String, label: String, tint: Color = Color.Unspecified) {
    Card(Modifier.weight(1f)) {
        Column(Modifier.fillMaxWidth().padding(vertical = 12.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Text(value, style = tabularDigits(MaterialTheme.typography.titleLarge), color = tint)
            Text(label, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ProgressCard(model: DrillModel) {
    val document = model.document
    val progress = document.learningProgress()
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    document.name,
                    style = MaterialTheme.typography.titleMedium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                Spacer(Modifier.size(8.dp))
                Text(
                    "${progress.studied} of ${progress.cards} moves",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            StudiedBar(progress, height = 8.dp)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Legend(progress.mature, "mature", ThemeColor.learned)
                Legend(progress.young, "young", ThemeColor.learned.lighter())
                Legend(progress.learning, "learning", ThemeColor.learning)
            }
        }
    }
}

@Composable
private fun Legend(value: Long, label: String, meaning: ThemeColor) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Box(Modifier.size(7.dp).background(meaning.color, CircleShape))
        Text("$value $label", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** When moves come back: learning steps later today (tap to look again), then reviews. */
@Composable
private fun NextCard(model: DrillModel, laterToday: List<Long>, timing: SchedTiming) {
    val sidecar = model.document.sidecar
    val tomorrow = sidecar.dueTomorrow(timing)
    val nextReview = sidecar.nextDue(timing)?.takeUnless { isToday(it) }
    if (laterToday.isEmpty() && tomorrow == 0 && nextReview == null) return
    Card(Modifier.fillMaxWidth()) {
        val rowColors = ListItemDefaults.colors(containerColor = Color.Transparent)
        laterToday.firstOrNull()?.let { first ->
            val count = laterToday.size
            ListItem(
                leadingContent = { Icon(Icons.Outlined.Schedule, contentDescription = null) },
                trailingContent = {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(timeText(first), style = tabularDigits())
                        Icon(Icons.Filled.Refresh, contentDescription = "Check again", modifier = Modifier.size(18.dp))
                    }
                },
                colors = rowColors,
                modifier = Modifier.clickable(onClickLabel = "Check again") { model.checkAgain() },
            ) { Text("$count learning ${if (count == 1) "move" else "moves"}") }
            if (tomorrow > 0 || nextReview != null) HorizontalDivider(Modifier.padding(start = 56.dp))
        }
        if (tomorrow > 0) {
            ListItem(
                leadingContent = { Icon(Icons.Outlined.CalendarToday, contentDescription = null) },
                trailingContent = { Text("$tomorrow tomorrow", style = tabularDigits()) },
                colors = rowColors,
            ) { Text("Reviews") }
        } else if (nextReview != null) {
            ListItem(
                leadingContent = { Icon(Icons.Outlined.CalendarToday, contentDescription = null) },
                trailingContent = { Text(nextStudyText(nextReview)) },
                colors = rowColors,
            ) { Text("Next review") }
        }
    }
}

// MARK: Actions

/** The tour's end: on to the user's own repertoire. */
@Composable
private fun TourEndActions(app: AppModel) {
    Column(
        Modifier.fillMaxWidth().padding(16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            "You've filled a gap and learned the move. Now make a repertoire for the opening you play.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
        Button(
            shapes = ButtonDefaults.shapes(),
            onClick = { app.tour.advance(from = TourGuide.Step.Studying, to = TourGuide.Step.Finish) },
            modifier = Modifier.widthIn(max = 560.dp).fillMaxWidth(),
        ) { Text("Create Your Own Repertoire") }
    }
}

/** Main button first: the next repertoire during Study All, else studying more today. */
@Composable
private fun Actions(model: DrillModel, next: NextRepertoire?) {
    val document = model.document
    val notStudied = document.learningProgress().notStudied
    val extraReviews = if (model.isFiltered) 0 else document.reviewsBeyondLimit()
    val canStudyMore = !model.isFiltered && (notStudied > 0 || extraReviews > 0)
    if (next == null && !canStudyMore) return
    Column(
        Modifier.fillMaxWidth().padding(16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        val width = Modifier.widthIn(max = 560.dp).fillMaxWidth()
        if (next != null) {
            Button(onClick = next.start, shapes = ButtonDefaults.shapes(), modifier = width) { Text("Continue with ${next.name}") }
        }
        if (canStudyMore) {
            var menu by remember { mutableStateOf(false) }
            Box(width) {
                if (next == null) {
                    Button(onClick = { menu = true }, shapes = ButtonDefaults.shapes(), modifier = Modifier.fillMaxWidth()) { Text("Study More Today") }
                } else {
                    OutlinedButton(onClick = { menu = true }, shapes = ButtonDefaults.shapes(), modifier = Modifier.fillMaxWidth()) { Text("Study More Today") }
                }
                ExpressiveMenu(menu, onDismissRequest = { menu = false }) {
                    if (notStudied > 0) {
                        group {
                            label("$notStudied new moves not studied yet")
                            for (n in listOf(5, 10, 20)) {
                                item("Learn $n More New Moves", Icons.Outlined.AutoAwesome) { model.increaseNewLimit(n) }
                            }
                        }
                    }
                    if (extraReviews > 0) {
                        group { item("Review $extraReviews More Moves", Icons.Filled.Refresh) { model.increaseReviewLimit(extraReviews) } }
                    }
                }
            }
        }
    }
}

// MARK: Helpers

private fun localDate(unixSeconds: Long): LocalDate = Instant.ofEpochSecond(unixSeconds).atZone(ZoneId.systemDefault()).toLocalDate()

/** Whether a time (unix seconds) is on today's calendar date, as `Calendar.isDateInToday`. */
private fun isToday(unixSeconds: Long): Boolean = localDate(unixSeconds) == LocalDate.now()

private fun timeText(unixSeconds: Long): String =
    DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).format(Instant.ofEpochSecond(unixSeconds).atZone(ZoneId.systemDefault()))

/** A time today, "Tomorrow" or "In N days" (`LibraryRow.nextStudyText`). */
private fun nextStudyText(unixSeconds: Long): String {
    if (isToday(unixSeconds)) return timeText(unixSeconds)
    val days = ChronoUnit.DAYS.between(LocalDate.now(), localDate(unixSeconds))
    return if (days <= 1) "Tomorrow" else "In $days days"
}
