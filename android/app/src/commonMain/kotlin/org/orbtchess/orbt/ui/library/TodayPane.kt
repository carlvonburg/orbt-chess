package org.orbtchess.orbt.ui.library

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.LocalFireDepartment
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material.icons.outlined.CalendarToday
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.core.Counts
import org.orbtchess.orbt.core.notStudied
import org.orbtchess.orbt.core.studied
import org.orbtchess.orbt.core.total
import org.orbtchess.orbt.storage.RepertoireEntry
import org.orbtchess.orbt.storage.TrainingDefaults
import org.orbtchess.orbt.ui.Destination
import org.orbtchess.orbt.ui.DrillKind
import org.orbtchess.orbt.ui.StatisticsScope
import org.orbtchess.orbt.ui.components.Format
import org.orbtchess.orbt.ui.components.SymbolLabel
import org.orbtchess.orbt.ui.components.countColor
import org.orbtchess.orbt.ui.components.tabularDigits
import org.orbtchess.orbt.ui.overview.SecondaryLabel
import org.orbtchess.orbt.ui.statistics.StatisticsScreen
import org.orbtchess.orbt.ui.theme.ThemeColor
import org.orbtchess.orbt.ui.theme.color
import java.text.NumberFormat
import kotlin.math.roundToLong

/**
 * Today across every repertoire (the Today column in LibraryView.swift): what is left to do
 * today and Study All. The detail pane on wide windows while no repertoire is selected (on a
 * phone Today is the library's first section).
 *
 * @param statisticsInline true when no pane beside shows the statistics (a two-pane window):
 *   show every repertoire's statistics under Today.
 * @param navigate [Destination.StudyAll], [Destination.Drill], [Destination.Builder].
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TodayPane(
    app: AppModel,
    statisticsInline: Boolean,
    navigate: (Destination) -> Unit,
    modifier: Modifier = Modifier,
) {
    Scaffold(modifier = modifier, topBar = { TopAppBar(title = { Text("Today") }) }) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding)) {
            // While the tour runs, its card instead.
            item { if (tourRunning(app)) TourSection(app, navigate) else TodayCard(app, navigate) }
            if (statisticsInline) {
                item { HorizontalDivider(Modifier.padding(top = 8.dp)) }
                // A pane of its own height, scrolled within (the statistics are a screen).
                item {
                    StatisticsScreen(app, StatisticsScope.All, inline = true, navigate = navigate, modifier = Modifier.fillParentMaxHeight())
                }
            }
        }
    }
}

/** A repertoire and its progress, for Today. */
private class TodayItem(val entry: RepertoireEntry, val stats: EntryStats)

/** What today looks like (`TodayCard.Phase`). */
private sealed interface Phase {
    data object Due : Phase
    /** No moves saved yet in any repertoire. */
    data object Empty : Phase
    /** Learning moves come back later today (unix seconds). */
    data class DoneForNow(val count: Int, val at: Long) : Phase
    /** Nothing due and nothing studied today. */
    data object NothingDue : Phase
    data object CaughtUp : Phase
}

/**
 * Today across all repertoires (`TodayCard` in LibraryView.swift): Anki's due totals and
 * "Studied N moves in M minutes today". With nothing due it says why (done for now, caught up,
 * nothing studied yet) and offers what can still be done: Anki's custom study (more new moves,
 * practice) or filling gaps. Its actions are the same buttons, the most likely one prominent; a
 * menu when several repertoires could take one.
 */
@Composable
fun TodayCard(app: AppModel, navigate: (Destination) -> Unit, modifier: Modifier = Modifier) {
    val items = app.library.entries.filter { !it.needsSetup }.map { TodayItem(it, EntryStats.of(it, app)) }
    val counts = Counts(items.sumOf { it.stats.counts.new }, items.sumOf { it.stats.counts.learning }, items.sumOf { it.stats.counts.review })

    // Today's answers and the streak, read again when the library or what is due changes.
    var summary by remember { mutableStateOf(TodaySummary.empty) }
    LaunchedEffect(app.library.entries.size, counts.total) { summary = TodaySummary.load(app) }
    val today = summary.today
    val streak = summary.streak
    val studiedToday = (today?.answerCount ?: 0L) > 0

    val withMoves = items.filter { it.stats.progress.cards > 0 }
    val unlearned = items.filter { it.stats.progress.notStudied > 0 }.sortedByDescending { it.stats.progress.notStudied }
    val withGaps = items.filter { it.stats.gaps > 0 }.sortedByDescending { it.stats.gaps }
    val gapCount = items.sumOf { it.stats.gaps }
    val phase: Phase = run {
        if (counts.total > 0) return@run Phase.Due
        if (withMoves.isEmpty()) return@run Phase.Empty
        val learning = items.flatMap { it.stats.laterLearning }.filter(::isToday)
        learning.minOrNull()?.let { return@run Phase.DoneForNow(learning.size, it) }
        if (!studiedToday && unlearned.isNotEmpty()) Phase.NothingDue else Phase.CaughtUp
    }

    val number = NumberFormat.getIntegerInstance()
    val secondary = MaterialTheme.typography.bodySmall

    @Composable
    fun streakBadge() {
        if (streak.current <= 0) return
        // At risk until something is studied today.
        val days = "${streak.current}-day streak"
        val longest = if (streak.longest > streak.current) " · longest ${streak.longest}" else ""
        SymbolLabel(
            "${streak.current} ${if (streak.current == 1L) "day" else "days"}",
            Icons.Filled.LocalFireDepartment,
            Modifier.semantics { contentDescription = if (streak.studiedToday) days + longest else "Study today to keep your $days" },
            meaning = ThemeColor.todo,
            style = tabularDigits(MaterialTheme.typography.bodyMedium),
        )
    }

    @Composable
    fun header(title: @Composable () -> Unit) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) { title() }
            streakBadge()
        }
    }

    @Composable
    fun doneHeader(title: String, icon: androidx.compose.ui.graphics.vector.ImageVector) = header {
        SymbolLabel(title, icon, meaning = ThemeColor.learned, style = MaterialTheme.typography.titleMedium)
    }

    /** Anki's "Studied N cards in M minutes today", when something was. */
    @Composable
    fun studiedLine() {
        if (today == null || today.answerCount <= 0) return
        val moves = if (today.cardCount == 1L) "1 move" else "${number.format(today.cardCount)} moves"
        val minutes = (today.answerMillis / 60_000.0).roundToLong()
        Text(
            "Studied $moves in ${if (minutes < 1) "under a minute" else "$minutes min"} today",
            style = secondary,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }

    /** Tomorrow's reviews, or when the next one is due. */
    @Composable
    fun nextLine() {
        val tomorrow = items.sumOf { it.stats.dueTomorrow }
        val next = items.mapNotNull { it.stats.nextDue }.minOrNull()
        when {
            tomorrow > 0 -> SecondaryLabel("$tomorrow ${if (tomorrow == 1) "review" else "reviews"} tomorrow", Icons.Outlined.CalendarToday, style = secondary)
            next != null -> SecondaryLabel("Next review ${relativeDay(next)}", Icons.Outlined.CalendarToday, style = secondary)
        }
    }

    /** A button for one repertoire, or a menu to pick one of several. */
    @Composable
    fun action(title: String, of: List<TodayItem>, main: Boolean, detail: (EntryStats) -> String?, destination: (String) -> Destination) {
        val single = of.singleOrNull()
        if (single != null) {
            ActionButton(title, main, { navigate(destination(single.entry.id)) })
        } else {
            ActionMenuButton(title, main) { close ->
                for (item in of) {
                    DropdownMenuItem(
                        text = {
                            Column {
                                Text(item.entry.name)
                                detail(item.stats)?.let { Text(it, style = secondary, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                            }
                        },
                        onClick = {
                            close()
                            navigate(destination(item.entry.id))
                        },
                    )
                }
            }
        }
    }

    @Composable
    fun learnAction(main: Boolean) = action(
        "Learn ${TrainingDefaults.LEARN_MORE_COUNT} New Moves", unlearned, main,
        detail = { "${it.progress.notStudied} not studied" },
    ) { Destination.Drill(it, DrillKind.LearnMore) }

    @Composable
    fun gapsAction() = action(
        if (gapCount == 1) "Fill 1 Gap" else "Fill $gapCount Gaps", withGaps, main = false,
        detail = { if (it.gaps == 1) "1 gap" else "${it.gaps} gaps" },
    ) { Destination.Builder(it, showGaps = true) }

    Column(modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        when (phase) {
            Phase.Due -> {
                // What is left first, then what was studied (Anki's line under its deck list).
                header {
                    Text(
                        buildAnnotatedString {
                            withStyle(SpanStyle(fontWeight = FontWeight.Bold, fontSize = MaterialTheme.typography.headlineMedium.fontSize, fontFeatureSettings = "tnum")) {
                                append(number.format(counts.total))
                            }
                            append(if (counts.total == 1L) " move to study" else " moves to study")
                        },
                        style = MaterialTheme.typography.titleMedium,
                    )
                }
                Row(
                    Modifier.semantics { contentDescription = "${counts.new} new, ${counts.learning} learning, ${counts.review} to review" },
                    horizontalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    DueCount(counts.new, "new", ThemeColor.new)
                    DueCount(counts.learning, "learning", ThemeColor.learning)
                    DueCount(counts.review, "review", ThemeColor.learned)
                }
                studiedLine()
            }
            Phase.Empty -> {
                Text("Nothing to study yet", style = MaterialTheme.typography.titleMedium)
                Text(
                    "Answer the replies your opponents play, then study your moves here.",
                    style = secondary,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            is Phase.DoneForNow -> {
                doneHeader("Done for Now", Icons.Filled.CheckCircle)
                studiedLine()
                SecondaryLabel(
                    "${phase.count} learning ${if (phase.count == 1) "move" else "moves"} due at ${shortTime(phase.at)}",
                    Icons.Outlined.Schedule,
                    style = secondary,
                )
            }
            Phase.NothingDue -> {
                header { Text("Nothing Due Today", style = MaterialTheme.typography.titleMedium) }
                if (streak.current > 0) {
                    Text("Learn a few new moves to keep your ${streak.current}-day streak.", style = secondary, color = ThemeColor.todo.color)
                }
                nextLine()
            }
            Phase.CaughtUp -> {
                doneHeader("All Caught Up", Icons.Filled.Verified)
                studiedLine()
                if (unlearned.isEmpty() && withGaps.isEmpty()) {
                    Text("Every move you've saved is learned.", style = secondary, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                nextLine()
            }
        }

        when (phase) {
            Phase.Due -> ActionButton("Study All", prominent = true, onClick = { navigate(Destination.StudyAll(studyAllEntries(app))) })
            Phase.Empty -> action("Add Moves", items, main = true, detail = { null }) { Destination.Builder(it) }
            Phase.NothingDue -> {
                learnAction(main = true)
                if (withGaps.isNotEmpty()) gapsAction()
            }
            is Phase.DoneForNow, Phase.CaughtUp -> {
                // What can still be done today: new moves and gaps, or else practice and adding lines.
                if (unlearned.isEmpty() && withGaps.isEmpty()) {
                    action("Practice", withMoves.filter { it.stats.progress.studied > 0 }, main = false, detail = { "${it.progress.studied} moves" }) {
                        Destination.Drill(it, DrillKind.Practice)
                    }
                    action("Add Lines", withMoves.sortedBy { it.stats.completion }, main = false, detail = { "${Format.percent(it.completion)} built" }) {
                        Destination.Builder(it)
                    }
                } else {
                    if (unlearned.isNotEmpty()) learnAction(main = false)
                    if (withGaps.isNotEmpty()) gapsAction()
                }
            }
        }
    }
}

/** A due count with its name, colored like the studied bar; faint at zero. */
@Composable
private fun DueCount(value: Long, name: String, meaning: ThemeColor) {
    Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(
            NumberFormat.getIntegerInstance().format(value),
            style = tabularDigits(MaterialTheme.typography.bodyMedium).copy(fontWeight = FontWeight.SemiBold),
            color = countColor(value, meaning),
        )
        Text(name, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
