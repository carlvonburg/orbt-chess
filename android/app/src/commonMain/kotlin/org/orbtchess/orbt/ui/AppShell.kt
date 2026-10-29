package org.orbtchess.orbt.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.adaptive.ExperimentalMaterial3AdaptiveApi
import androidx.compose.material3.adaptive.currentWindowAdaptiveInfo
import androidx.compose.material3.adaptive.layout.AnimatedPane
import androidx.compose.material3.adaptive.layout.ListDetailPaneScaffold
import androidx.compose.material3.adaptive.layout.ListDetailPaneScaffoldDefaults
import androidx.compose.material3.adaptive.layout.ListDetailPaneScaffoldRole
import androidx.compose.material3.adaptive.layout.PaneAdaptedValue
import androidx.compose.material3.adaptive.layout.ThreePaneScaffoldDestinationItem
import androidx.compose.material3.adaptive.layout.calculatePaneScaffoldDirectiveWithTwoPanesOnMediumWidth
import androidx.compose.material3.adaptive.layout.calculateThreePaneScaffoldValue
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteScaffold
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteScaffoldDefaults
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteType
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.backhandler.BackHandler
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
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
// detail pane, and the extra pane shows the board of Build, Study and Analysis (their panel in
// the detail pane) or, beside an overview or Today, the statistics, as the Swift app's split
// view does. Every screen's wiring is here; screens only call `navigate(destination)`.

/** Starting widths of the list and of a panel beside a board (the Swift split view's ideals: 260, 380). */
private val ListPaneWidth = 300.dp
private val PanelWidth = 400.dp

@OptIn(ExperimentalMaterial3AdaptiveApi::class, ExperimentalComposeUiApi::class, ExperimentalMaterial3Api::class)
@Composable
fun AppShell(app: AppModel) {
    val owner = LocalViewModelStoreOwner.current
    val shell = if (owner != null) viewModel(owner) { ShellModel(app) } else remember { ShellModel(app) }

    val adaptiveInfo = currentWindowAdaptiveInfo(supportLargeAndXLargeWidth = true)
    // Two panes from medium width on (a tablet in portrait, as iPad's split view), three on large.
    val directive = calculatePaneScaffoldDirectiveWithTwoPanesOnMediumWidth(adaptiveInfo)
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

/** The library's panes: list (the library), detail (Today, an overview or a panel), extra (a board or the statistics). */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
@Composable
private fun LibraryPanes(
    app: AppModel,
    shell: ShellModel,
    directive: androidx.compose.material3.adaptive.layout.PaneScaffoldDirective,
) {
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
    val top = shell.top
    val back: () -> Unit = shell::back
    val navigate: (Destination) -> Unit = shell::navigate

    BoxWithConstraints {
        // The extra pane (the board, or the statistics) takes what the others leave.
        val spacer = directive.horizontalPartitionSpacerSize
        val extraWidth: Dp = maxWidth -
            (if (listShown) ListPaneWidth + spacer else 0.dp) -
            (if (detailShown) PanelWidth + spacer else 0.dp)

        ListDetailPaneScaffold(
            directive = directive,
            value = value,
            listPane = {
                AnimatedPane(Modifier.preferredWidth(ListPaneWidth)) {
                    LibraryScreen(
                        app,
                        selectedEntryId = if (detailShown) shell.selectedEntryId else null,
                        showToday = directive.maxHorizontalPartitions == 1,
                        navigate = navigate,
                    )
                }
            },
            detailPane = {
                AnimatedPane(if (extraShown) Modifier.preferredWidth(PanelWidth) else Modifier) {
                    when {
                        top == null -> TodayPane(app, statisticsInline = !extraShown, navigate = navigate)
                        top.role == ListDetailPaneScaffoldRole.Detail ->
                            Screen(app, top, BoardPane.Whole, navigate, if (listShown) null else back, statisticsInline = shell.wide && !extraShown)
                        // A board screen's panel, its board beside it.
                        else -> Screen(app, top, if (extraShown) BoardPane.Panel else BoardPane.Whole, navigate, back)
                    }
                }
            },
            extraPane = {
                AnimatedPane(Modifier.preferredWidth(extraWidth.coerceAtLeast(ListPaneWidth))) {
                    when {
                        top == null -> StatisticsScreen(app, StatisticsScope.All, inline = true, navigate = navigate, paneTitle = true)
                        top.role == ListDetailPaneScaffoldRole.Detail -> StatisticsScreen(
                            app,
                            top.screen.entryId?.let { StatisticsScope.Repertoire(it) } ?: StatisticsScope.All,
                            inline = true,
                            navigate = navigate,
                            paneTitle = true,
                        )
                        detailShown -> Screen(app, top, BoardPane.Board, navigate, onBack = null)
                        else -> Screen(app, top, BoardPane.Whole, navigate, back)
                    }
                }
            },
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
