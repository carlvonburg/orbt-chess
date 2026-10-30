package org.orbtchess.orbt.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.adaptive.ExperimentalMaterial3AdaptiveApi
import androidx.compose.material3.adaptive.currentWindowAdaptiveInfoV2
import androidx.compose.material3.adaptive.layout.AnimatedPane
import androidx.compose.material3.adaptive.layout.ListDetailPaneScaffold
import androidx.compose.material3.adaptive.layout.ListDetailPaneScaffoldDefaults
import androidx.compose.material3.adaptive.layout.ListDetailPaneScaffoldRole
import androidx.compose.material3.adaptive.layout.PaneAdaptedValue
import androidx.compose.material3.adaptive.layout.ThreePaneScaffoldDestinationItem
import androidx.compose.material3.adaptive.layout.SupportingPaneScaffold
import androidx.compose.material3.adaptive.layout.SupportingPaneScaffoldDefaults
import androidx.compose.material3.adaptive.layout.SupportingPaneScaffoldRole
import androidx.compose.material3.adaptive.layout.calculatePaneScaffoldDirective
import androidx.compose.material3.adaptive.layout.calculateThreePaneScaffoldValue
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteScaffold
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteScaffoldDefaults
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteType
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.key
import androidx.compose.runtime.remember
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.backhandler.BackHandler
import androidx.lifecycle.viewmodel.compose.LocalViewModelStoreOwner
import androidx.lifecycle.viewmodel.compose.viewModel
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.ui.analysis.AnalysisScreen
import org.orbtchess.orbt.ui.builder.BuilderScreen
import org.orbtchess.orbt.ui.components.BoardPane
import org.orbtchess.orbt.ui.components.OpenDocument
import org.orbtchess.orbt.ui.components.Symbols
import org.orbtchess.orbt.ui.library.LibraryScreen
import org.orbtchess.orbt.ui.library.SetupScreen
import org.orbtchess.orbt.ui.library.TodayPane
import org.orbtchess.orbt.ui.overview.OverviewScreen
import org.orbtchess.orbt.ui.overview.RepertoireSettingsScreen
import org.orbtchess.orbt.ui.overview.StudyOptionsSheet
import org.orbtchess.orbt.ui.settings.AcknowledgementsScreen
import org.orbtchess.orbt.ui.settings.SettingsScreen
import org.orbtchess.orbt.ui.statistics.CardInfoSheet
import org.orbtchess.orbt.ui.statistics.StatisticsScreen
import org.orbtchess.orbt.ui.training.DrillScreen
import org.orbtchess.orbt.ui.training.StudyAllScreen
import org.orbtchess.orbt.ui.tour.LocalTourGuide
import org.orbtchess.orbt.ui.tour.TourGuide
import org.orbtchess.orbt.ui.tour.TourSpotlight

// The navigation shell (RootView.swift and LibraryView.swift's navigation): Material's
// navigation suite (the bottom bar on a phone: Repertoires, Statistics) around Material's
// list-detail scaffold. On a phone one pane at a time: the library, an overview, a screen pushed
// on it. On wide windows (tablets, the desktop) the library is the list pane, the overview the
// detail pane and, on large windows, the statistics the extra pane beside it; Build, Study and
// Analysis fill the window as Material's supporting-pane layout, the board the main pane and
// their panel beside it. Every screen's wiring is here; screens only call `navigate(destination)`.


@OptIn(ExperimentalMaterial3AdaptiveApi::class, ExperimentalComposeUiApi::class, ExperimentalMaterial3Api::class)
@Composable
fun AppShell(app: AppModel) {
    val owner = LocalViewModelStoreOwner.current
    val shell = if (owner != null) viewModel(owner) { ShellModel(app) } else remember { ShellModel(app) }

    val adaptiveInfo = currentWindowAdaptiveInfoV2()
    // Material's panes for the window: one up to medium width, two on expanded, three on large.
    val directive = calculatePaneScaffoldDirective(adaptiveInfo)
    val wide = directive.maxHorizontalPartitions > 1
    SideEffect { shell.wide = wide }
    // A window grown past a phone's has no Statistics tab: its statistics are beside the overview.
    LaunchedEffect(wide) { if (wide && shell.tab == Tab.Statistics) shell.tab = Tab.Repertoires }

    val top = shell.top
    // The bottom bar on a phone's top-level screens; a pushed board screen has its own actions.
    val showBar = !wide && (shell.tab == Tab.Statistics || top == null || top.role == ListDetailPaneScaffoldRole.Detail)

    BackHandler(enabled = shell.canGoBack && shell.sheet == null) { shell.back() }

    // The tour's turns that change screens: started (Settings › Show Tour), its card is in
    // Today's place, so show Today; its end, from Study's: back to the library, at New Repertoire.
    val tourStep = app.tour.step
    LaunchedEffect(tourStep) {
        when (tourStep) {
            TourGuide.Step.Ready -> if (wide) shell.navigate(Destination.Library)
            TourGuide.Step.Finish -> {
                shell.navigate(Destination.Library)
                app.tour.skip()
                shell.navigate(Destination.Setup(SetupMode.New()))
            }
            else -> Unit
        }
    }

    CompositionLocalProvider(LocalTourGuide provides app.tour) {
        Box(Modifier.fillMaxSize()) {
            NavigationSuiteScaffold(
                navigationSuiteItems = {
                    item(
                        selected = shell.tab == Tab.Repertoires,
                        onClick = { shell.tab = Tab.Repertoires },
                        icon = { Icon(Symbols.repertoires, contentDescription = null) },
                        label = { Text("Repertoires") },
                    )
                    item(
                        selected = shell.tab == Tab.Statistics,
                        onClick = { shell.tab = Tab.Statistics },
                        icon = { Icon(Symbols.statistics, contentDescription = null) },
                        label = { Text("Statistics") },
                    )
                },
                layoutType = if (showBar) NavigationSuiteScaffoldDefaults.calculateFromAdaptiveInfo(adaptiveInfo) else NavigationSuiteType.None,
            ) {
                if (shell.tab == Tab.Statistics && !wide) {
                    StatisticsScreen(
                        app,
                        shell.statisticsScope,
                        inline = false,
                        navigate = shell::navigate,
                        onScopeChange = { shell.statisticsScope = it },
                    )
                } else {
                    LibraryPanes(app, shell, directive)
                }
            }

            // Full-window screens over everything (Android's settings screens, the setup flow).
            shell.overlays.lastOrNull()?.let { overlay ->
                Surface(Modifier.fillMaxSize()) { Overlay(app, shell, overlay) }
            }

            // The tour's spotlight over the tour's screens, bars included; not over a screen or
            // sheet that covers them.
            if (shell.overlays.isEmpty() && shell.sheet == null) TourSpotlight(app.tour)
        }

        shell.sheet?.let { sheet ->
            ModalBottomSheet(onDismissRequest = { shell.sheet = null }) {
                when (sheet) {
                    is Destination.CardInfo -> OpenDocument(app, sheet.entryId) { CardInfoSheet(app, it, sheet.node) }
                    is Destination.StudyOptions -> OpenDocument(app, sheet.entryId) {
                        StudyOptionsSheet(app, it, onDone = { shell.sheet = null })
                    }
                    else -> Unit
                }
            }
        }

        shell.error?.let { message ->
            AlertDialog(
                onDismissRequest = { shell.error = null },
                confirmButton = { TextButton(onClick = { shell.error = null }) { Text("OK") } },
                title = { Text("Something went wrong") },
                text = { Text(message) },
            )
        }
    }
}

/**
 * The library's panes: list (the library), detail (Today or an overview), extra (the statistics).
 * A board screen (Build, Study, Analysis) is the one pane on a phone; on wide windows it leaves
 * the list and fills the window as its own supporting-pane layout ([BoardPanes]).
 */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
@Composable
private fun LibraryPanes(
    app: AppModel,
    shell: ShellModel,
    directive: androidx.compose.material3.adaptive.layout.PaneScaffoldDirective,
) {
    val top = shell.top
    val back: () -> Unit = shell::back
    val navigate: (Destination) -> Unit = shell::navigate
    if (top != null && top.role == ListDetailPaneScaffoldRole.Extra && directive.maxHorizontalPartitions > 1) {
        BoardPanes(app, top, directive, navigate, back)
        return
    }

    val history = listOf(ThreePaneScaffoldDestinationItem<Long>(ListDetailPaneScaffoldRole.List)) +
        shell.stack.map { ThreePaneScaffoldDestinationItem(it.role, it.id) }
    val value = calculateThreePaneScaffoldValue(
        maxHorizontalPartitions = directive.maxHorizontalPartitions,
        adaptStrategies = ListDetailPaneScaffoldDefaults.adaptStrategies(),
        destinationHistory = history,
    )
    val listShown = value[ListDetailPaneScaffoldRole.List] == PaneAdaptedValue.Expanded
    val detailShown = value[ListDetailPaneScaffoldRole.Detail] == PaneAdaptedValue.Expanded
    val extraShown = value[ListDetailPaneScaffoldRole.Extra] == PaneAdaptedValue.Expanded

    ListDetailPaneScaffold(
        directive = directive,
        value = value,
        listPane = {
            AnimatedPane {
                LibraryScreen(
                    app,
                    selectedEntryId = if (detailShown) shell.selectedEntryId else null,
                    showToday = directive.maxHorizontalPartitions == 1,
                    navigate = navigate,
                )
            }
        },
        detailPane = {
            AnimatedPane {
                when {
                    top == null -> TodayPane(app, statisticsInline = !extraShown, navigate = navigate)
                    else -> Screen(app, top, BoardPane.Whole, navigate, if (listShown) null else back, statisticsInline = shell.wide && !extraShown)
                }
            }
        },
        extraPane = {
            AnimatedPane {
                when {
                    top == null -> StatisticsScreen(app, StatisticsScope.All, inline = true, navigate = navigate, paneTitle = true)
                    top.role == ListDetailPaneScaffoldRole.Detail -> StatisticsScreen(
                        app,
                        top.screen.entryId?.let { StatisticsScope.Repertoire(it) } ?: StatisticsScope.All,
                        inline = true,
                        navigate = navigate,
                        paneTitle = true,
                    )
                    // A phone: the board screen alone.
                    else -> Screen(app, top, BoardPane.Whole, navigate, back)
                }
            }
        },
    )
}

/**
 * A board screen on a wide window: Material's supporting-pane layout, the board the main pane
 * (with the screen's bars and back) and its panel the supporting pane beside it.
 */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
@Composable
private fun BoardPanes(
    app: AppModel,
    entry: StackEntry,
    directive: androidx.compose.material3.adaptive.layout.PaneScaffoldDirective,
    navigate: (Destination) -> Unit,
    onBack: () -> Unit,
) {
    val value = calculateThreePaneScaffoldValue(
        maxHorizontalPartitions = directive.maxHorizontalPartitions,
        adaptStrategies = SupportingPaneScaffoldDefaults.adaptStrategies(),
        currentDestination = ThreePaneScaffoldDestinationItem(SupportingPaneScaffoldRole.Main, entry.id),
    )
    // A new layout for each screen, so a screen pushed on another starts from its own panes.
    key(entry.id) {
        SupportingPaneScaffold(
            directive = directive,
            value = value,
            mainPane = { AnimatedPane { Screen(app, entry, BoardPane.Board, navigate, onBack) } },
            supportingPane = { AnimatedPane { Screen(app, entry, BoardPane.Panel, navigate, onBack) } },
        )
    }
}

/** One back-stack entry's screen in a pane. */
@Composable
private fun Screen(
    app: AppModel,
    entry: StackEntry,
    pane: BoardPane,
    navigate: (Destination) -> Unit,
    onBack: (() -> Unit)?,
    statisticsInline: Boolean = false,
) {
    when (val screen = entry.screen) {
        is Screen.Overview -> OpenDocument(app, screen.entryId) { doc ->
            OverviewScreen(app, doc, statisticsInline, navigate, onBack)
        }
        is Screen.Builder -> BuilderScreen(app, screen.model, pane, navigate, onBack)
        is Screen.Drill -> DrillScreen(app, screen.model, pane, navigate, onBack)
        is Screen.StudyAll -> StudyAllScreen(app, screen.model, pane, navigate, onBack)
        is Screen.Analysis -> AnalysisScreen(app, screen.model, pane, navigate, onBack)
    }
}

/** A full-window screen. */
@Composable
private fun Overlay(app: AppModel, shell: ShellModel, destination: Destination) {
    val close: () -> Unit = shell::closeOverlay
    when (destination) {
        Destination.Settings -> SettingsScreen(app, shell::navigate, onBack = close)
        Destination.Acknowledgements -> AcknowledgementsScreen(onBack = close)
        is Destination.RepertoireSettings -> OpenDocument(app, destination.entryId) { doc ->
            RepertoireSettingsScreen(app, doc, onBack = close, onDeleted = shell::showLibrary)
        }
        is Destination.Setup -> SetupScreen(
            app,
            destination.mode,
            onDone = { entry ->
                close()
                shell.navigate(Destination.Overview(entry.id))
                // A new repertoire opens on Build, to enter its first moves.
                if (destination.mode is SetupMode.New) shell.navigate(Destination.Builder(entry.id))
            },
            onCancel = close,
        )
        else -> Unit
    }
}
