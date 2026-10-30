package org.orbtchess.orbt.ui

import androidx.navigationevent.NavigationEventTransitionState
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.material3.adaptive.layout.MutableThreePaneScaffoldState
import androidx.compose.material3.MaterialTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.animation.togetherWith
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.fadeOut
import androidx.compose.animation.fadeIn
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.AnimatedContent
import org.orbtchess.orbt.ui.components.GroupedBackground
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.ButtonDefaults
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
import androidx.compose.material3.adaptive.layout.calculatePaneScaffoldDirective
import androidx.compose.material3.adaptive.layout.calculateThreePaneScaffoldValue
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteItem
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
import androidx.lifecycle.viewmodel.compose.LocalViewModelStoreOwner
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigationevent.NavigationEventInfo
import androidx.navigationevent.compose.NavigationBackHandler
import androidx.navigationevent.compose.rememberNavigationEventState
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.ui.analysis.AnalysisScreen
import org.orbtchess.orbt.ui.builder.BuilderScreen
import org.orbtchess.orbt.ui.components.BoardPane
import org.orbtchess.orbt.ui.components.OpenDocument
import org.orbtchess.orbt.ui.components.Symbols
import org.orbtchess.orbt.ui.library.LibraryScreen
import org.orbtchess.orbt.ui.library.SetupScreen
import org.orbtchess.orbt.ui.library.TodayDashboard
import org.orbtchess.orbt.ui.overview.OverviewDashboard
import org.orbtchess.orbt.ui.overview.OverviewScreen
import org.orbtchess.orbt.ui.overview.RepertoireSettingsScreen
import org.orbtchess.orbt.ui.overview.StudyOptionsSheet
import org.orbtchess.orbt.ui.settings.AcknowledgementsScreen
import org.orbtchess.orbt.ui.settings.SettingsScreen
import org.orbtchess.orbt.ui.statistics.CardInfoSheet
import org.orbtchess.orbt.ui.statistics.StatisticsScreen
import org.orbtchess.orbt.ui.tour.LocalTourGuide
import org.orbtchess.orbt.ui.tour.TourGuide
import org.orbtchess.orbt.ui.tour.TourSpotlight
import org.orbtchess.orbt.ui.training.DrillScreen
import org.orbtchess.orbt.ui.training.StudyAllScreen

// The navigation shell (RootView.swift and LibraryView.swift's navigation): Material's
// navigation suite (the bottom bar on a phone: Repertoires, Statistics) around Material's
// list-detail scaffold. On a phone one pane at a time: the library, an overview, a screen pushed
// on it. On wide windows (tablets, the desktop) the library is the list pane and the detail pane
// a dashboard: Today or the selected repertoire's overview, then its statistics; Build, Study and
// Analysis fill the window as their own list-detail layout, their panel the list pane and the
// board the detail pane. Every screen's wiring is here; screens only call `navigate(destination)`.


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

    val backState = rememberNavigationEventState(NavigationEventInfo.None)
    NavigationBackHandler(
        backState,
        isBackEnabled = shell.canGoBack && shell.sheet == null,
        onBackCompleted = { shell.back() },
    )
    // Predictive back: how far the back gesture has gone (0 to 1) while it is in progress.
    val backProgress = (backState.transitionState as? NavigationEventTransitionState.InProgress)?.latestEvent?.progress

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

    val suiteType = if (showBar) NavigationSuiteScaffoldDefaults.navigationSuiteType(adaptiveInfo) else NavigationSuiteType.None
    CompositionLocalProvider(LocalTourGuide provides app.tour) {
        Box(Modifier.fillMaxSize()) {
            // Material 3 Expressive's navigation for the window: the short navigation bar (on a
            // tablet in portrait its items side by side); wide windows show the tabs as panes.
            NavigationSuiteScaffold(
                navigationItems = {
                    NavigationSuiteItem(
                        navigationSuiteType = suiteType,
                        selected = shell.tab == Tab.Repertoires,
                        onClick = { shell.tab = Tab.Repertoires },
                        icon = { Icon(Symbols.repertoires, contentDescription = null) },
                        label = { Text("Repertoires") },
                    )
                    NavigationSuiteItem(
                        navigationSuiteType = suiteType,
                        selected = shell.tab == Tab.Statistics,
                        onClick = { shell.tab = Tab.Statistics },
                        icon = { Icon(Symbols.statistics, contentDescription = null) },
                        label = { Text("Statistics") },
                    )
                },
                navigationSuiteType = suiteType,
            ) {
                if (shell.tab == Tab.Statistics && !wide) {
                    StatisticsScreen(
                        app,
                        shell.statisticsScope,
                        navigate = shell::navigate,
                        onScopeChange = { shell.statisticsScope = it },
                    )
                } else {
                    LibraryPanes(app, shell, directive, if (shell.overlays.isEmpty()) backProgress else null)
                }
            }

            // Full-window screens over everything (Android's settings screens, the setup flow),
            // coming and going with Material's shared axis on the expressive motion scheme's
            // springs; the back gesture shrinks the one on top, as Android's predictive back does
            // a full-screen surface.
            val motion = MaterialTheme.motionScheme
            AnimatedContent(
                targetState = shell.overlays.lastOrNull(),
                transitionSpec = {
                    val forward = targetState != null && (initialState == null || shell.overlays.size > 1)
                    val shift = if (forward) 1 else -1
                    (slideInHorizontally(motion.defaultSpatialSpec()) { it / 10 * shift } + fadeIn(motion.defaultEffectsSpec()))
                        .togetherWith(slideOutHorizontally(motion.defaultSpatialSpec()) { -it / 10 * shift } + fadeOut(motion.fastEffectsSpec()))
                },
                label = "overlay",
            ) { overlay ->
                if (overlay != null) {
                    val progress = if (overlay == shell.overlays.lastOrNull()) backProgress ?: 0f else 0f
                    Surface(
                        Modifier.fillMaxSize().graphicsLayer {
                            val scale = 1f - 0.1f * PredictiveBackEasing.transform(progress)
                            scaleX = scale
                            scaleY = scale
                            shape = RoundedCornerShape(32.dp * progress)
                            clip = progress > 0f
                        },
                    ) { Overlay(app, shell, overlay) }
                }
            }

            // The tour's spotlight over the tour's screens, bars included; not over a screen or
            // sheet that covers them.
            if (shell.overlays.isEmpty() && shell.sheet == null) TourSpotlight(app.tour)
        }

        shell.sheet?.let { sheet ->
            // On the grouped pages' color, so the sheets' segmented lists and cards show.
            ModalBottomSheet(onDismissRequest = { shell.sheet = null }, containerColor = GroupedBackground) {
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
                confirmButton = { TextButton(onClick = { shell.error = null }, shapes = ButtonDefaults.shapes()) { Text("OK") } },
                title = { Text("Something went wrong") },
                text = { Text(message) },
            )
        }
    }
}

/**
 * The library's panes: list (the library) and detail (Today or an overview). On wide windows
 * Material's list-detail layout in two panes, the detail a dashboard of cards with the
 * statistics ([TodayDashboard], [OverviewDashboard]); on one pane the phone's screens. A board
 * screen (Build, Study, Analysis) is the one pane on a phone (the extra pane's role); on wide
 * windows it leaves the list and fills the window as its own list-detail layout ([BoardPanes]).
 */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
@Composable
private fun LibraryPanes(
    app: AppModel,
    shell: ShellModel,
    windowDirective: androidx.compose.material3.adaptive.layout.PaneScaffoldDirective,
    backProgress: Float?,
) {
    val top = shell.top
    val back: () -> Unit = shell::back
    val navigate: (Destination) -> Unit = shell::navigate
    if (top != null && top.role == ListDetailPaneScaffoldRole.Extra && windowDirective.maxHorizontalPartitions > 1) {
        BoardPanes(app, top, windowDirective, navigate, back)
        return
    }
    // Two panes at most: the statistics are in the detail pane's dashboard, not a third.
    val directive = windowDirective.copy(maxHorizontalPartitions = windowDirective.maxHorizontalPartitions.coerceAtMost(2))

    val history = listOf(ThreePaneScaffoldDestinationItem<Long>(ListDetailPaneScaffoldRole.List)) +
        shell.stack.map { ThreePaneScaffoldDestinationItem(it.role, it.id) }
    val value = calculateThreePaneScaffoldValue(
        maxHorizontalPartitions = directive.maxHorizontalPartitions,
        adaptStrategies = ListDetailPaneScaffoldDefaults.adaptStrategies(),
        destinationHistory = history,
    )
    // Material's predictive back for the panes: while the back gesture is in progress the
    // scaffold seeks toward the panes under the top screen (a fraction of the way, eased, as
    // Material's navigator seeks), animates there when it completes and back when cancelled.
    val previous = if (shell.stack.isEmpty()) null else calculateThreePaneScaffoldValue(
        maxHorizontalPartitions = directive.maxHorizontalPartitions,
        adaptStrategies = ListDetailPaneScaffoldDefaults.adaptStrategies(),
        destinationHistory = history.dropLast(1),
    )
    val scaffoldState = remember { MutableThreePaneScaffoldState(value) }
    LaunchedEffect(value) { scaffoldState.animateTo(value) }
    LaunchedEffect(backProgress, previous) {
        when {
            backProgress != null && previous != null && previous != value -> {
                val fraction = PredictiveBackEasing.transform(backProgress) * if (directive.maxHorizontalPartitions == 1) 1f / 8f else 1f / 10f
                scaffoldState.seekTo(fraction, previous, isPredictiveBackInProgress = true)
            }
            backProgress == null && scaffoldState.targetState != value -> scaffoldState.animateTo(value)
        }
    }
    val listShown = value[ListDetailPaneScaffoldRole.List] == PaneAdaptedValue.Expanded
    val detailShown = value[ListDetailPaneScaffoldRole.Detail] == PaneAdaptedValue.Expanded
    // Side by side: the list at a sidebar's width, the dashboard the rest of the window.
    val twoPanes = listShown && detailShown

    ListDetailPaneScaffold(
        directive = directive,
        scaffoldState = scaffoldState,
        modifier = Modifier.fillMaxSize().background(GroupedBackground),
        listPane = {
            AnimatedPane(if (twoPanes) Modifier.preferredWidth(LibraryListWidth) else Modifier) {
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
                    top == null -> TodayDashboard(app, navigate)
                    twoPanes && top.screen is Screen.Overview -> OpenDocument(app, top.screen.entryId) { doc ->
                        OverviewDashboard(app, doc, navigate, onBack = null)
                    }
                    else -> Screen(app, top, BoardPane.Whole, navigate, if (listShown) null else back)
                }
            }
        },
        extraPane = {
            // A phone: the board screen alone.
            AnimatedPane { if (top != null && top.role == ListDetailPaneScaffoldRole.Extra) Screen(app, top, BoardPane.Whole, navigate, back) }
        },
    )
}

/** Material's predictive back easing (the navigator's), for the gesture's progress. */
private val PredictiveBackEasing = CubicBezierEasing(0.1f, 0.1f, 0f, 1f)

/** The library's list pane beside the dashboard (iPad's sidebar is 260; Material's list pane 360). */
private val LibraryListWidth = 340.dp

/**
 * A board screen on a wide window: Material's list-detail layout, as on iPad. The panel (what you
 * pick from: replies, explorer, counts) is the list pane on the left, with the screen's top app
 * bar and back; the board, which shows the pick, is the detail pane taking the rest of the window,
 * with its move list and floating toolbar and no top app bar, so it is as large as it fits.
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
        adaptStrategies = ListDetailPaneScaffoldDefaults.adaptStrategies(),
        currentDestination = ThreePaneScaffoldDestinationItem(ListDetailPaneScaffoldRole.Detail, entry.id),
    )
    // A new layout for each screen, so a screen pushed on another starts from its own panes.
    key(entry.id) {
        ListDetailPaneScaffold(
            directive = directive,
            value = value,
            listPane = { AnimatedPane { Screen(app, entry, BoardPane.List, navigate, onBack) } },
            detailPane = { AnimatedPane { Screen(app, entry, BoardPane.Detail, navigate, onBack) } },
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
) {
    when (val screen = entry.screen) {
        is Screen.Overview -> OpenDocument(app, screen.entryId) { doc ->
            OverviewScreen(app, doc, navigate, onBack)
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
