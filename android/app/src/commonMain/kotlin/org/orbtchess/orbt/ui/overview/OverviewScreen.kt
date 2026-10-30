package org.orbtchess.orbt.ui.overview

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.HourglassEmpty
import androidx.compose.material.icons.outlined.NoAccounts
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.WifiOff
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import org.orbtchess.orbt.ui.components.TooltipIconButton
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.ui.tour.TourGuide
import org.orbtchess.orbt.ui.tour.TourScreen
import org.orbtchess.orbt.ui.tour.tourTarget
import org.orbtchess.orbt.core.Counts
import org.orbtchess.orbt.core.QueueState
import org.orbtchess.orbt.core.notStudied
import org.orbtchess.orbt.core.schedTiming
import org.orbtchess.orbt.core.studied
import org.orbtchess.orbt.core.total
import org.orbtchess.orbt.storage.RepertoireDocument
import org.orbtchess.orbt.ui.Destination
import org.orbtchess.orbt.ui.DrillKind
import org.orbtchess.orbt.ui.StatisticsScope
import org.orbtchess.orbt.ui.components.CoverageBar
import org.orbtchess.orbt.ui.components.Format
import org.orbtchess.orbt.ui.components.StudiedBar
import org.orbtchess.orbt.ui.components.Symbols
import org.orbtchess.orbt.ui.components.SymbolLabel
import org.orbtchess.orbt.ui.components.tabularDigits
import org.orbtchess.orbt.ui.library.ActionButton
import org.orbtchess.orbt.ui.library.ActionMenuButton
import org.orbtchess.orbt.ui.library.EntryStats
import org.orbtchess.orbt.ui.library.isToday
import org.orbtchess.orbt.ui.library.relativeDay
import org.orbtchess.orbt.ui.library.shortTime
import org.orbtchess.orbt.ui.statistics.StatisticsScreen
import org.orbtchess.orbt.ui.theme.ThemeColor
import org.orbtchess.orbt.ui.theme.color
import java.text.NumberFormat

/**
 * A repertoire's overview (`RepertoireOverviewView.swift`, Anki's deck overview): coverage and
 * study progress and what is due today, each section ending with its action (Browse / Edit,
 * Study): the same buttons, the most likely one prominent, building while there are gaps, else
 * studying. Runs the background coverage check while shown. The detail pane on wide windows;
 * pushed on the library on a phone.
 *
 * @param statisticsInline true on a two-pane window, where no pane beside shows this
 *   repertoire's statistics: show them under the overview.
 * @param navigate [Destination.Builder], [Destination.Drill], [Destination.RepertoireSettings],
 *   [Destination.StudyOptions], [Destination.Statistics] (a phone's Statistics row).
 * @param onBack null where the overview is beside the library (nothing to go back to).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OverviewScreen(
    app: AppModel,
    document: RepertoireDocument,
    statisticsInline: Boolean,
    navigate: (Destination) -> Unit,
    onBack: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    val id = document.entryId
    // The background coverage check, while the overview is on screen (the core counts viewers).
    DisposableEffect(document) {
        document.startCoverageCheck()
        onDispose { document.stopCoverageCheck() }
    }
    val stats = EntryStats.of(document)
    var menu by remember { mutableStateOf(false) }
    // The tour on the sample begins here, at Browse / Edit.
    val isSample = TourGuide.isSample(document.pgnFile)
    TourScreen(running = isSample)
    LaunchedEffect(isSample) { if (isSample) app.tour.advance(from = TourGuide.Step.Ready, to = TourGuide.Step.Browse) }

    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                title = { Text(document.name, maxLines = 1) },
                navigationIcon = {
                    if (onBack != null) {
                        IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") }
                    }
                },
                actions = {
                    TooltipIconButton("Repertoire", Symbols.settings, { menu = true })
                    DropdownMenu(menu, onDismissRequest = { menu = false }) {
                        DropdownMenuItem(
                            text = { Text("Repertoire Settings…") },
                            leadingIcon = { Icon(Symbols.settings, contentDescription = null) },
                            onClick = {
                                menu = false
                                navigate(Destination.RepertoireSettings(id))
                            },
                        )
                        DropdownMenuItem(
                            text = { Text("Study Options…") },
                            leadingIcon = { Icon(Symbols.options, contentDescription = null) },
                            onClick = {
                                menu = false
                                navigate(Destination.StudyOptions(id))
                            },
                        )
                    }
                },
            )
        },
    ) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding)) {
            coverageSection(app, document, stats) { navigate(Destination.Builder(id)) }
            item { HorizontalDivider(Modifier.padding(vertical = 8.dp)) }
            studySection(document, stats, navigate, showStatisticsRow = onBack != null && !statisticsInline)
            if (statisticsInline) {
                item { HorizontalDivider(Modifier.padding(top = 8.dp)) }
                // A pane of its own height, scrolled within (the statistics are a screen).
                item { StatisticsScreen(app, StatisticsScope.Repertoire(id), inline = true, navigate = navigate, modifier = Modifier.fillParentMaxHeight()) }
            }
        }
    }
}

/** While there are gaps (or nothing of yours to study), building is the main action. */
private fun buildFirst(stats: EntryStats): Boolean = stats.gaps > 0 || stats.progress.cards == 0L

@Composable
private fun SectionHeader(title: String) {
    Text(
        title,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
    )
}

// MARK: Coverage

private fun LazyListScope.coverageSection(app: AppModel, document: RepertoireDocument, stats: EntryStats, browse: () -> Unit) {
    item { SectionHeader("Coverage") }
    item {
        Column(Modifier.padding(horizontal = 16.dp, vertical = 4.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "${Format.percent(stats.completion)} complete",
                    style = tabularDigits(MaterialTheme.typography.titleMedium),
                    modifier = Modifier.weight(1f),
                )
                if (stats.gaps > 0) {
                    Text(
                        if (stats.gaps == 1) "1 gap" else "${NumberFormat.getIntegerInstance().format(stats.gaps)} gaps",
                        style = tabularDigits(MaterialTheme.typography.titleSmall).copy(fontWeight = FontWeight.SemiBold),
                        color = ThemeColor.todo.color,
                    )
                }
            }
            CoverageBar(stats.completion)
            CoverageCheckStatus(app, document)
        }
    }
    item {
        ListItem(
            headlineContent = { Text("Saved moves") },
            trailingContent = { Text(NumberFormat.getIntegerInstance().format(stats.savedMoves), style = tabularDigits(MaterialTheme.typography.bodyLarge)) },
        )
    }
    item {
        ActionButton(
            "Browse / Edit", prominent = buildFirst(stats), onClick = browse,
            modifier = Modifier.padding(horizontal = 16.dp).tourTarget(TourGuide.Target.BrowseButton),
        )
    }
}

/** The background coverage check while it runs (`CoverageCheckStatus` in BuilderView.swift). */
@Composable
private fun CoverageCheckStatus(app: AppModel, document: RepertoireDocument) {
    val unchecked = document.uncheckedPositions
    if (unchecked <= 0) return
    val style = MaterialTheme.typography.bodySmall
    when (val state = app.explorer.state) {
        is QueueState.RateLimited -> {
            val minutes = ((state.until - System.currentTimeMillis()) / 60_000).coerceAtLeast(0)
            val resuming = if (minutes < 1) "in under a minute" else "in $minutes min"
            SecondaryLabel("Lichess asked to slow down · resuming $resuming", Icons.Outlined.HourglassEmpty, style = style)
        }
        QueueState.Offline -> SecondaryLabel("Offline · ${Format.positions(unchecked)} not checked yet", Icons.Outlined.WifiOff, style = style)
        QueueState.NeedsLogin -> SecondaryLabel("Sign in to Lichess to check ${Format.positions(unchecked)}", Icons.Outlined.NoAccounts, style = style)
        else -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
            Text("Checking coverage · $unchecked waiting", style = style, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

// MARK: Study

private fun LazyListScope.studySection(
    document: RepertoireDocument,
    stats: EntryStats,
    navigate: (Destination) -> Unit,
    showStatisticsRow: Boolean,
) {
    val id = document.entryId
    item { SectionHeader("Study") }
    if (stats.progress.cards == 0L) {
        // Nothing to count yet: only what to do.
        item {
            SecondaryLabel("Add moves of yours to study them.", Icons.Outlined.CheckCircle, Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
        }
        return
    }
    item { StudyProgress(stats) }
    item {
        Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
            if (stats.counts.total > 0) {
                DueToday(stats.counts)
            } else {
                val studied = stats.progress.studied > 0
                if (studied) {
                    SymbolLabel(doneText(document, stats), Icons.Filled.CheckCircle, meaning = ThemeColor.learned)
                } else {
                    SecondaryLabel(doneText(document, stats), Icons.Outlined.CheckCircle)
                }
            }
        }
    }
    item {
        val prominent = !buildFirst(stats)
        val modifier = Modifier.padding(horizontal = 16.dp)
        if (stats.counts.total > 0) {
            ActionButton("Study Now", prominent, { navigate(Destination.Drill(id, DrillKind.Study)) }, modifier)
        } else {
            StudyMoreMenu(document, stats, prominent, navigate, modifier)
        }
    }
    // Wide windows show the statistics beside the overview, or under it.
    if (showStatisticsRow) {
        item {
            ListItem(
                headlineContent = { Text("Statistics") },
                leadingContent = { Icon(Symbols.statistics, contentDescription = null) },
                trailingContent = { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null) },
                modifier = Modifier.padding(top = 8.dp).clickable {
                    navigate(Destination.Statistics(StatisticsScope.Repertoire(id)))
                },
            )
        }
    }
}

/** Like Coverage: how far along, then the numbers in Anki's groups. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun StudyProgress(stats: EntryStats) {
    val progress = stats.progress
    val number = NumberFormat.getIntegerInstance()
    Column(Modifier.padding(horizontal = 16.dp, vertical = 4.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            "${number.format(progress.studied)} of ${number.format(progress.cards)} moves studied",
            style = tabularDigits(MaterialTheme.typography.titleMedium),
        )
        StudiedBar(progress)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Legend(progress.mature, "mature", ThemeColor.learned)
            Legend(progress.young, "young", ThemeColor.learned.lighter())
            Legend(progress.learning, "learning", ThemeColor.learning)
            if (progress.suspended > 0) Legend(progress.suspended, "suspended", ThemeColor.inactive)
        }
    }
}

/** A dot in the bar part's color, then the count and its name. */
@Composable
private fun Legend(value: Long, label: String, meaning: ThemeColor) {
    val color = meaning.color
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Canvas(Modifier.size(7.dp)) { drawCircle(color) }
        Text(
            "${NumberFormat.getIntegerInstance().format(value)} $label",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/** "Due today" and the counts above zero, colored like the studied bar. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun DueToday(counts: Counts) {
    FlowRow(verticalArrangement = Arrangement.Center, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Text("Due today", style = MaterialTheme.typography.bodyLarge)
        Spacer(Modifier.weight(1f).width(12.dp))
        val style = tabularDigits(MaterialTheme.typography.bodyLarge).copy(fontWeight = FontWeight.SemiBold)
        val number = NumberFormat.getIntegerInstance()
        if (counts.new > 0) Text("${number.format(counts.new)} new", style = style, color = ThemeColor.new.color)
        if (counts.learning > 0) Text("${number.format(counts.learning)} learning", style = style, color = ThemeColor.learning.color)
        if (counts.review > 0) Text("${number.format(counts.review)} review", style = style, color = ThemeColor.learned.color)
    }
}

/**
 * Study More Today: Anki's custom study, raising today's limits or practicing every learned
 * move. Only today changes; the repertoire's limits stay as they are.
 */
@Composable
private fun StudyMoreMenu(
    document: RepertoireDocument,
    stats: EntryStats,
    prominent: Boolean,
    navigate: (Destination) -> Unit,
    modifier: Modifier,
) {
    val id = document.entryId
    val extraReviews = document.reviewsBeyondLimit()
    ActionMenuButton("Study More Today", prominent, modifier) { close ->
        val notStudied = stats.progress.notStudied
        if (notStudied > 0) {
            Text(
                "$notStudied new moves not studied yet",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
            )
            for (n in listOf(5, 10, 20)) {
                DropdownMenuItem(
                    text = { Text("Learn $n More New Moves") },
                    leadingIcon = { Icon(Icons.Outlined.AutoAwesome, contentDescription = null) },
                    onClick = {
                        close()
                        document.extendNewLimitToday(n)
                        navigate(Destination.Drill(id, DrillKind.Study))
                    },
                )
            }
        }
        if (extraReviews > 0) {
            DropdownMenuItem(
                text = { Text("Review $extraReviews More Moves") },
                leadingIcon = { Icon(Icons.Outlined.Refresh, contentDescription = null) },
                onClick = {
                    close()
                    document.extendReviewLimitToday(extraReviews)
                    navigate(Destination.Drill(id, DrillKind.Study))
                },
            )
        }
        if (stats.progress.studied > 0) {
            DropdownMenuItem(
                text = { Text("Practice the Whole Repertoire") },
                leadingIcon = { Icon(Symbols.practice, contentDescription = null) },
                onClick = {
                    close()
                    navigate(Destination.Drill(id, DrillKind.Practice))
                },
            )
        }
    }
}

private fun doneText(document: RepertoireDocument, stats: EntryStats): String {
    if (stats.progress.cards == 0L) return "Add moves of yours to study them."
    val next = document.sidecar.nextDue(schedTiming()) ?: return "Done for today."
    if (isToday(next)) return "Done for now. More moves are due at ${shortTime(next)}."
    return "Done for today. Next review ${relativeDay(next)}."
}
