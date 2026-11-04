package org.orbtchess.orbt.ui.overview

import androidx.compose.runtime.setValue
import androidx.compose.runtime.getValue
import org.orbtchess.orbt.ui.components.groupedTopAppBarColors
import org.orbtchess.orbt.ui.components.ListSection
import org.orbtchess.orbt.ui.components.GroupedBackground
import androidx.compose.foundation.layout.Box
import org.orbtchess.orbt.ui.components.ExpressiveMenu
import androidx.compose.foundation.Canvas
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
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.TopAppBarScrollBehavior
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.nestedscroll.nestedScroll
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
import org.orbtchess.orbt.ui.theme.ThemeColor
import org.orbtchess.orbt.ui.theme.color
import java.text.NumberFormat

/**
 * A repertoire's overview (`RepertoireOverviewView.swift`, Anki's deck overview): coverage and
 * study progress and what is due today, each section ending with its action (Browse / Edit,
 * Study): the same buttons, the most likely one prominent, building while there are gaps, else
 * studying. Runs the background coverage check while shown. Pushed on the library on one pane
 * (a phone, a tablet in portrait); wide windows show [OverviewDashboard] instead.
 *
 * @param navigate [Destination.Builder], [Destination.Drill], [Destination.RepertoireSettings],
 *   [Destination.StudyOptions], [Destination.Statistics] (the Statistics row).
 * @param onBack null where the overview is beside the library (nothing to go back to).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OverviewScreen(
    app: AppModel,
    document: RepertoireDocument,
    navigate: (Destination) -> Unit,
    onBack: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    val id = document.entryId
    OverviewEffects(app, document)
    val stats = EntryStats.of(document)
    val scrollBehavior = TopAppBarDefaults.pinnedScrollBehavior()
    Scaffold(
        modifier = modifier.nestedScroll(scrollBehavior.nestedScrollConnection),
        containerColor = GroupedBackground,
        topBar = { OverviewTopBar(document, scrollBehavior, navigate, onBack) },
    ) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding)) {
            item("coverage") { CoverageSection(app, document, stats) { navigate(Destination.Builder(id)) } }
            item("study") { StudySection(document, stats, navigate) }
            // The repertoire's statistics: the Statistics tab, filtered to it.
            item("statistics") {
                ListSection(null) {
                    ListItem(
                        onClick = { navigate(Destination.Statistics(StatisticsScope.Repertoire(id))) },
                        leadingContent = { Icon(Symbols.statistics, contentDescription = null) },
                        trailingContent = { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null) },
                    ) { Text("Statistics") }
                }
            }
        }
    }
}

/**
 * What an overview does while on screen, as a list or a dashboard: the background coverage
 * check (the core counts viewers) and, on the sample, the tour, which begins at Browse / Edit.
 */
@Composable
internal fun OverviewEffects(app: AppModel, document: RepertoireDocument) {
    DisposableEffect(document) {
        document.startCoverageCheck()
        onDispose { document.stopCoverageCheck() }
    }
    val isSample = TourGuide.isSample(document.pgnFile)
    TourScreen(running = isSample)
    LaunchedEffect(isSample) { if (isSample) app.tour.advance(from = TourGuide.Step.Ready, to = TourGuide.Step.Browse) }
}

/** The overview's top app bar: the repertoire's name, back where there is one, and ⋮. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun OverviewTopBar(
    document: RepertoireDocument,
    scrollBehavior: TopAppBarScrollBehavior,
    navigate: (Destination) -> Unit,
    onBack: (() -> Unit)?,
) {
    val id = document.entryId
    var menu by remember { mutableStateOf(false) }
    TopAppBar(
        title = { Text(document.name, maxLines = 1) },
        scrollBehavior = scrollBehavior,
        colors = groupedTopAppBarColors(),
        navigationIcon = {
            if (onBack != null) {
                IconButton(onClick = onBack, shapes = IconButtonDefaults.shapes()) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") }
            }
        },
        actions = {
            Box {
                TooltipIconButton("More options", Symbols.more, { menu = true })
                ExpressiveMenu(menu, onDismissRequest = { menu = false }) {
                    group {
                        item("Repertoire Settings…", Symbols.settings) { navigate(Destination.RepertoireSettings(id)) }
                        item("Study Options…", Symbols.options) { navigate(Destination.StudyOptions(id)) }
                    }
                }
            }
        },
    )
}

/** While there are gaps (or nothing of yours to study), building is the main action. */
internal fun buildFirst(stats: EntryStats): Boolean = stats.gaps > 0 || stats.progress.cards == 0L

// MARK: Coverage

/**
 * Coverage, as one group of Material's segmented list: how complete and the gaps, the saved
 * moves, then Browse / Edit.
 */
@Composable
private fun CoverageSection(app: AppModel, document: RepertoireDocument, stats: EntryStats, browse: () -> Unit) {
    ListSection("Coverage") {
        CoverageSummary(app, document, stats, Modifier.fillMaxWidth().padding(16.dp))
        ListItem(trailingContent = { SavedMovesCount(stats) }) { Text("Saved moves") }
        BrowseButton(stats, browse, Modifier.padding(16.dp))
    }
}

/**
 * How complete (the percentage in the emphasized type Material 3 Expressive gives a key number)
 * and the gaps, the coverage bar and the background check.
 */
@Composable
internal fun CoverageSummary(app: AppModel, document: RepertoireDocument, stats: EntryStats, modifier: Modifier = Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.Bottom) {
            Text(
                Format.percent(stats.completion),
                style = tabularDigits(MaterialTheme.typography.headlineMediumEmphasized),
            )
            Text(
                " complete",
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.weight(1f).padding(bottom = 3.dp),
            )
            if (stats.gaps > 0) {
                Text(
                    if (stats.gaps == 1) "1 gap" else "${NumberFormat.getIntegerInstance().format(stats.gaps)} gaps",
                    style = tabularDigits(MaterialTheme.typography.titleSmallEmphasized),
                    color = ThemeColor.todo.color,
                    modifier = Modifier.padding(bottom = 3.dp),
                )
            }
        }
        CoverageBar(stats.completion)
        CoverageCheckStatus(app, document)
    }
}

/** The number of saved moves, for the "Saved moves" row. */
@Composable
internal fun SavedMovesCount(stats: EntryStats) {
    Text(NumberFormat.getIntegerInstance().format(stats.savedMoves), style = tabularDigits(MaterialTheme.typography.bodyLarge))
}

/** Browse / Edit, prominent while building comes first; where the tour begins. */
@Composable
internal fun BrowseButton(stats: EntryStats, browse: () -> Unit, modifier: Modifier = Modifier) {
    ActionButton(
        "Browse / Edit", prominent = buildFirst(stats), onClick = browse,
        modifier = modifier.tourTarget(TourGuide.Target.BrowseButton),
    )
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

/** Study, as one group: how far along, what is due today, then Study Now (or Study More Today). */
@Composable
private fun StudySection(
    document: RepertoireDocument,
    stats: EntryStats,
    navigate: (Destination) -> Unit,
) {
    ListSection("Study") {
        if (stats.progress.cards == 0L) {
            // Nothing to count yet: only what to do.
            NothingToStudy(Modifier.fillMaxWidth().padding(16.dp))
            return@ListSection
        }
        StudyProgress(stats, Modifier.fillMaxWidth().padding(16.dp))
        StudyToday(document, stats, Modifier.fillMaxWidth().padding(16.dp))
        StudyAction(document, stats, navigate, Modifier.padding(16.dp))
    }
}

/** A repertoire with no moves of yours yet: what to do. */
@Composable
internal fun NothingToStudy(modifier: Modifier = Modifier) {
    SecondaryLabel("Add moves of yours to study them.", Icons.Outlined.CheckCircle, modifier)
}

/** What is due today, or when the next move is. */
@Composable
internal fun StudyToday(document: RepertoireDocument, stats: EntryStats, modifier: Modifier = Modifier) {
    Column(modifier) {
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

/** Study Now while moves are due, else Study More Today; prominent unless building comes first. */
@Composable
internal fun StudyAction(document: RepertoireDocument, stats: EntryStats, navigate: (Destination) -> Unit, modifier: Modifier = Modifier) {
    val prominent = !buildFirst(stats)
    if (stats.counts.total > 0) {
        ActionButton("Study Now", prominent, { navigate(Destination.Drill(document.entryId, DrillKind.Study)) }, modifier)
    } else {
        StudyMoreMenu(document, stats, prominent, navigate, modifier)
    }
}

/** Like Coverage: how far along, then the numbers in Anki's groups. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun StudyProgress(stats: EntryStats, modifier: Modifier = Modifier) {
    val progress = stats.progress
    val number = NumberFormat.getIntegerInstance()
    Column(modifier, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.Bottom) {
            Text(number.format(progress.studied), style = tabularDigits(MaterialTheme.typography.headlineMediumEmphasized))
            Text(
                " of ${number.format(progress.cards)} moves studied",
                style = tabularDigits(MaterialTheme.typography.titleMedium),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(bottom = 3.dp),
            )
        }
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
    ActionMenuButton("Study More Today", prominent, modifier) {
        val notStudied = stats.progress.notStudied
        if (notStudied > 0) {
            group {
                label("$notStudied new moves not studied yet")
                for (n in listOf(5, 10, 20)) {
                    item("Learn $n More New Moves", Icons.Outlined.AutoAwesome) {
                        document.extendNewLimitToday(n)
                        navigate(Destination.Drill(id, DrillKind.Study))
                    }
                }
            }
        }
        if (extraReviews > 0) {
            group {
                item("Review $extraReviews More Moves", Icons.Outlined.Refresh) {
                    document.extendReviewLimitToday(extraReviews)
                    navigate(Destination.Drill(id, DrillKind.Study))
                }
            }
        }
        if (stats.progress.studied > 0) {
            group { item("Practice the Whole Repertoire", Symbols.practice) { navigate(Destination.Drill(id, DrillKind.Practice())) } }
        }
    }
}

private fun doneText(document: RepertoireDocument, stats: EntryStats): String {
    if (stats.progress.cards == 0L) return "Add moves of yours to study them."
    val next = document.sidecar.nextDue(schedTiming()) ?: return "Done for today."
    if (isToday(next)) return "Done for now. More moves are due at ${shortTime(next)}."
    return "Done for today. Next review ${relativeDay(next)}."
}
