package org.orbtchess.orbt.ui.library

import androidx.compose.runtime.setValue
import androidx.compose.runtime.getValue
import org.orbtchess.orbt.ui.components.groupedTopAppBarColors
import org.orbtchess.orbt.ui.components.ListSection
import org.orbtchess.orbt.ui.components.GroupedBackground
import org.orbtchess.orbt.ui.components.MenuBuilder
import org.orbtchess.orbt.ui.components.ExpressiveMenu
import org.orbtchess.orbt.ui.components.onSecondaryClick
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CalendarToday
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.LargeFlexibleTopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.pulltorefresh.PullToRefreshDefaults
import androidx.compose.material3.pulltorefresh.rememberPullToRefreshState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import orbt.app.generated.resources.Res
import orbt.app.generated.resources.piece_wn
import org.jetbrains.compose.resources.ExperimentalResourceApi
import org.jetbrains.compose.resources.vectorResource
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.core.Side
import org.orbtchess.orbt.core.studied
import org.orbtchess.orbt.core.total
import org.orbtchess.orbt.storage.RepertoireEntry
import org.orbtchess.orbt.ui.Destination
import org.orbtchess.orbt.ui.SetupMode
import org.orbtchess.orbt.ui.components.CoverageBar
import org.orbtchess.orbt.ui.components.DueCounts
import org.orbtchess.orbt.ui.components.EmptyState
import org.orbtchess.orbt.ui.components.StudiedBar
import org.orbtchess.orbt.ui.components.TooltipIconButton
import org.orbtchess.orbt.ui.components.Symbols
import org.orbtchess.orbt.ui.overview.DeleteRepertoireDialog
import org.orbtchess.orbt.ui.overview.SecondaryLabel
import org.orbtchess.orbt.ui.theme.LocalSelectedRow
import org.orbtchess.orbt.ui.theme.ThemeColor
import org.orbtchess.orbt.ui.theme.color

/**
 * The repertoires (`LibraryView.swift`, Anki's deck list): by side, each with its coverage and
 * study progress and today's due moves; Settings and Add (New Repertoire, Import PGN) in the top
 * app bar; a row's menu (long press) renames, sets options, exports or deletes; the empty
 * library's welcome (`EmptyLibraryView.swift`). The list pane on wide windows, where Today is its
 * first row; the Repertoires tab on a phone, where Today (Study All) is its first section.
 *
 * @param selectedEntryId the repertoire shown beside the list on wide windows (its row is selected), else null.
 * @param showToday true on a phone: Today is the list's first section (on wide windows it is [TodayPane]).
 * @param navigate shows a destination: [Destination.Overview] for a row, [Destination.Library]
 *   (Today on wide windows), [Destination.Settings], [Destination.Setup], [Destination.StudyAll],
 *   [Destination.RepertoireSettings], [Destination.StudyOptions].
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalResourceApi::class)
@Composable
fun LibraryScreen(
    app: AppModel,
    selectedEntryId: String?,
    showToday: Boolean,
    navigate: (Destination) -> Unit,
    modifier: Modifier = Modifier,
) {
    val library = app.library
    val scope = rememberCoroutineScope()
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var deleteEntry by remember { mutableStateOf<RepertoireEntry?>(null) }
    var addMenu by remember { mutableStateOf(false) }
    var refreshing by remember { mutableStateOf(false) }
    val importPgn = rememberPgnImport(
        onPicked = { navigate(Destination.Setup(SetupMode.Importing(it.data, it.name))) },
        onError = { errorMessage = it },
    )
    val export = rememberPgnExport(app) { errorMessage = it }
    RefreshOnReturn(app)

    /** Adds the sample and offers the tour on it. */
    fun takeTour() {
        scope.launch {
            try {
                startTour(app)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                errorMessage = e.message ?: e.toString()
            }
        }
    }

    // The first launch on this device starts with the sample and its tour; repertoires from
    // the start mean no sample later, even if they are all deleted.
    var sampleOffered by remember { mutableStateOf(app.tour.wasOffered) }
    LaunchedEffect(library.isLoaded, sampleOffered) {
        if (!library.isLoaded || sampleOffered) return@LaunchedEffect
        if (library.entries.isEmpty()) takeTour() else app.tour.markOffered()
        sampleOffered = true
    }
    val tourRunning = tourRunning(app)

    // iOS's large title: Material 3 Expressive's large flexible app bar, collapsing as the list scrolls.
    val scrollBehavior = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    Scaffold(
        modifier = modifier.nestedScroll(scrollBehavior.nestedScrollConnection),
        containerColor = GroupedBackground,
        topBar = {
            LargeFlexibleTopAppBar(
                title = { Text("Repertoires") },
                scrollBehavior = scrollBehavior,
                colors = groupedTopAppBarColors(),
                actions = {
                    // An empty library offers these in its middle.
                    if (library.entries.isNotEmpty()) {
                        Box {
                            TooltipIconButton("Add", Symbols.add, { addMenu = true })
                            ExpressiveMenu(addMenu, onDismissRequest = { addMenu = false }) {
                                group {
                                    item("New Repertoire", Symbols.add) { navigate(Destination.Setup(SetupMode.New())) }
                                    item("Import PGN…", Symbols.importFile) { importPgn() }
                                }
                            }
                        }
                    }
                    TooltipIconButton("Settings", Symbols.settings, { navigate(Destination.Settings) })
                },
            )
        },
    ) { padding ->
        val content = Modifier.fillMaxSize().padding(padding)
        val refreshState = rememberPullToRefreshState()
        when {
            // The first launch adds the sample: still loading, not an empty library.
            !library.isLoaded || (library.entries.isEmpty() && !sampleOffered) ->
                Box(content, contentAlignment = Alignment.Center) { LoadingIndicator() }
            library.entries.isEmpty() -> EmptyLibrary(
                newRepertoire = { navigate(Destination.Setup(SetupMode.New(it))) },
                importPgn = importPgn,
                takeTour = ::takeTour,
                modifier = content,
            )
            else -> PullToRefreshBox(
                isRefreshing = refreshing,
                state = refreshState,
                indicator = {
                    PullToRefreshDefaults.LoadingIndicator(refreshState, refreshing, Modifier.align(Alignment.TopCenter))
                },
                onRefresh = {
                    scope.launch {
                        refreshing = true
                        library.refresh()
                        refreshing = false
                    }
                },
                modifier = content,
            ) {
                LazyColumn(Modifier.fillMaxSize()) {
                    if (showToday && tourRunning) {
                        // Studying moves you haven't built yet isn't the next step.
                        item { ListSection("Tour") { TourSection(app, navigate) } }
                    } else if (showToday) {
                        item { ListSection("Today") { TodayCard(app, navigate) } }
                    } else {
                        // Today's card is in the pane beside when this row is selected.
                        item { ListSection(null) { TodayRow(app, selected = selectedEntryId == null) { navigate(Destination.Library) } } }
                    }
                    groups(
                        app, selectedEntryId, navigate,
                        menu = { entry ->
                            entryMenu(entry, navigate, export = { export(entry) }, delete = { deleteEntry = entry })
                        },
                    )
                }
            }
        }
    }

    deleteEntry?.let { entry ->
        DeleteRepertoireDialog(
            name = entry.name,
            syncedWith = app.sync.provider?.title,
            onDismiss = { deleteEntry = null },
            onDelete = {
                deleteEntry = null
                scope.launch {
                    try {
                        app.documents.delete(entry)
                        if (selectedEntryId == entry.id) navigate(Destination.Library)
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        errorMessage = e.message ?: e.toString()
                    }
                }
            },
        )
    }

    errorMessage?.let { message ->
        AlertDialog(
            onDismissRequest = { errorMessage = null },
            confirmButton = { TextButton(onClick = { errorMessage = null }, shapes = ButtonDefaults.shapes()) { Text("OK") } },
            title = { Text("Something went wrong") },
            text = { Text(message) },
        )
    }
}

/** Sections of the repertoire list: grouped by side, as Chessbook does; by name within each group. */
private enum class LibraryGroup(val title: String) {
    White("White"), Black("Black"), Setup("Not Set Up");

    fun contains(entry: RepertoireEntry): Boolean = when (this) {
        White -> entry.sidecar?.color() == Side.WHITE
        Black -> entry.sidecar?.color() == Side.BLACK
        Setup -> entry.sidecar == null
    }
}

private fun LazyListScope.groups(
    app: AppModel,
    selectedEntryId: String?,
    navigate: (Destination) -> Unit,
    menu: MenuBuilder.(RepertoireEntry) -> Unit,
) {
    for (group in LibraryGroup.entries) {
        val entries = app.library.entries.filter(group::contains)
        if (entries.isEmpty()) continue
        // A side's repertoires as one group of Material's segmented list.
        item(key = "group-${group.name}") {
            ListSection(group.title) {
                for (entry in entries) {
                    LibraryRow(
                        app, entry,
                        selected = selectedEntryId != null && app.documents.currentId(selectedEntryId) == entry.id,
                        onClick = {
                            navigate(if (entry.needsSetup) Destination.Setup(SetupMode.SetUp(entry.id)) else Destination.Overview(entry.id))
                        },
                        menu = { menu(entry) },
                    )
                }
            }
        }
    }
}

/** Today in the list pane on wide windows (the split view's sidebar row), with today's due count. */
@Composable
private fun TodayRow(app: AppModel, selected: Boolean, onClick: () -> Unit) {
    val due = app.library.entries.sumOf { EntryStats.of(it, app).counts.total }
    CompositionLocalProvider(LocalSelectedRow provides selected) {
        ListItem(
            selected = selected,
            onClick = onClick,
            leadingContent = { Icon(Icons.Outlined.CalendarToday, contentDescription = null) },
            trailingContent = { if (due > 0) Text("$due", style = MaterialTheme.typography.labelLarge) },
            colors = rowColors(selected),
        ) { Text("Today") }
    }
}

/**
 * The list pane's rows are Material 3 Expressive's selectable list items in segmented groups:
 * the selected one in the secondary container, as Material selects.
 */
@Composable
private fun rowColors(selected: Boolean) = if (selected) {
    val scheme = MaterialTheme.colorScheme
    ListItemDefaults.colors(
        containerColor = scheme.secondaryContainer,
        headlineColor = scheme.onSecondaryContainer,
        supportingColor = scheme.onSecondaryContainer,
        trailingIconColor = scheme.onSecondaryContainer,
        leadingIconColor = scheme.onSecondaryContainer,
    )
} else {
    ListItemDefaults.colors()
}

/** One repertoire (`LibraryRow`): its name and today's counts, then what is built and studied, and its gaps. */
@Composable
private fun LibraryRow(
    app: AppModel,
    entry: RepertoireEntry,
    selected: Boolean,
    onClick: () -> Unit,
    menu: MenuBuilder.() -> Unit,
) {
    var showMenu by remember { mutableStateOf(false) }
    var menuAt by remember { mutableStateOf<IntOffset?>(null) }
    val stats = EntryStats.of(entry, app)
    Box {
        CompositionLocalProvider(LocalSelectedRow provides selected) {
            ListItem(
                selected = selected,
                onClick = onClick,
                modifier = Modifier.onSecondaryClick { menuAt = it; showMenu = true },
                onLongClick = { menuAt = null; showMenu = true },
                onLongClickLabel = "Repertoire menu",
                supportingContent = {
                    when {
                        entry.needsSetup -> Text("New PGN. Tap to set it up.")
                        stats.progress.cards == 0L && stats.savedMoves == 0 -> Text("Empty · add moves to start")
                        else -> RowProgress(stats)
                    }
                },
                trailingContent = if (entry.needsSetup) null else ({ DueStatus(stats) }),
                colors = rowColors(selected),
            ) { Text(entry.name, maxLines = 1) }
        }
        ExpressiveMenu(showMenu, onDismissRequest = { showMenu = false }, at = menuAt, content = menu)
    }
}

/** Anki's deck gear menu: Rename (the repertoire's settings), Options, Export, Delete. */
private fun MenuBuilder.entryMenu(entry: RepertoireEntry, navigate: (Destination) -> Unit, export: () -> Unit, delete: () -> Unit) {
    if (!entry.needsSetup) {
        group {
            item("Rename", Icons.Outlined.Edit) { navigate(Destination.RepertoireSettings(entry.id)) }
            item("Options", Symbols.options) { navigate(Destination.StudyOptions(entry.id)) }
            item("Export", Symbols.share) { export() }
        }
    }
    group { item("Delete", Symbols.delete, destructive = true) { delete() } }
}

/**
 * Today's counts; with nothing due after studying, when this repertoire is studied next. Never
 * "done": building progress and gaps are shown below.
 */
@Composable
private fun DueStatus(stats: EntryStats) {
    if (stats.counts.total == 0L && stats.progress.studied > 0) {
        val next = stats.nextDue ?: return
        SecondaryLabel(nextStudyText(next), if (isToday(next)) Icons.Outlined.Schedule else Icons.Outlined.CalendarToday)
    } else {
        DueCounts(stats.counts, stats.progress)
    }
}

/** Built and studied as bars with their labels in a column, then "Not studied yet" and the gaps. */
@Composable
private fun RowProgress(stats: EntryStats) {
    val label = MaterialTheme.typography.labelSmall
    Column(Modifier.padding(top = 4.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Box(Modifier.height(14.dp), contentAlignment = Alignment.CenterStart) { Text("Built", style = label) }
                if (stats.progress.studied > 0) {
                    Box(Modifier.height(14.dp), contentAlignment = Alignment.CenterStart) { Text("Studied", style = label) }
                }
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Box(Modifier.height(14.dp), contentAlignment = Alignment.Center) { CoverageBar(stats.completion) }
                if (stats.progress.studied > 0) {
                    Box(Modifier.height(14.dp), contentAlignment = Alignment.Center) { StudiedBar(stats.progress) }
                }
            }
        }
        val notStudied = stats.progress.studied == 0L && stats.progress.cards > 0
        if (notStudied || stats.gaps > 0) {
            Row {
                if (notStudied) Text("Not studied yet", style = MaterialTheme.typography.bodySmall)
                if (notStudied && stats.gaps > 0) Text(" · ", style = MaterialTheme.typography.bodySmall)
                if (stats.gaps > 0) {
                    Text(
                        if (stats.gaps == 1) "1 gap" else "${stats.gaps} gaps",
                        style = MaterialTheme.typography.bodySmall,
                        color = ThemeColor.todo.color,
                    )
                }
            }
        }
    }
}

/**
 * The repertoire list with no repertoire (`EmptyLibraryView.swift`): start one by choosing a
 * side (the setup flow opens with it), import a PGN, or take the tour with the sample.
 */
@Composable
private fun EmptyLibrary(newRepertoire: (Side) -> Unit, importPgn: () -> Unit, takeTour: () -> Unit, modifier: Modifier) {
    EmptyState(
        "Start a Repertoire",
        vectorResource(Res.drawable.piece_wn),
        modifier,
        description = "Choose a side to see which replies opponents at your level play, and which ones you haven't answered yet.",
    ) {
        Row(Modifier.width(280.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            SideCard(Side.WHITE, "White", selected = false, Modifier.weight(1f)) { newRepertoire(Side.WHITE) }
            SideCard(Side.BLACK, "Black", selected = false, Modifier.weight(1f)) { newRepertoire(Side.BLACK) }
        }
        TextButton(onClick = importPgn, shapes = ButtonDefaults.shapes()) { Text("Import a PGN…") }
        TextButton(onClick = takeTour, shapes = ButtonDefaults.shapes(), modifier = Modifier.padding(top = 8.dp)) {
            Icon(Symbols.tour, contentDescription = null, modifier = Modifier.size(ButtonDefaults.IconSize))
            Spacer(Modifier.width(ButtonDefaults.IconSpacing))
            Text("Take the Tour with a Sample")
        }
    }
}
