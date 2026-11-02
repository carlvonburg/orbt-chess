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
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.core.SeekableTransitionState
import androidx.compose.animation.core.rememberTransition
import androidx.compose.material3.MotionScheme
import androidx.compose.material3.adaptive.layout.AnimatedPaneScope
import androidx.compose.material3.adaptive.layout.PaneMotion
import androidx.compose.material3.adaptive.layout.ThreePaneScaffoldPaneScope
import androidx.compose.material3.adaptive.layout.calculateDefaultEnterTransition
import androidx.compose.material3.adaptive.layout.calculateDefaultExitTransition
import androidx.compose.animation.AnimatedContent
import org.orbtchess.orbt.ui.components.AdaptiveSheet
import org.orbtchess.orbt.ui.components.GroupedBackground
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
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
import androidx.compose.runtime.withFrameNanos
import androidx.compose.runtime.remember
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.clickable
import androidx.lifecycle.viewmodel.compose.LocalViewModelStoreOwner
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigationevent.NavigationEventInfo
import androidx.navigationevent.compose.NavigationBackHandler
import androidx.navigationevent.compose.rememberNavigationEventState
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.ui.analysis.AnalysisScreen
import org.orbtchess.orbt.ui.builder.BuilderScreen
import org.orbtchess.orbt.ui.components.BoardPane
import org.orbtchess.orbt.ui.components.LocalInDialog
import org.orbtchess.orbt.ui.components.LocalSheetHost
import org.orbtchess.orbt.ui.components.LocalWideWindow
import org.orbtchess.orbt.ui.components.SheetHost
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
    val sheets = remember { SheetHost() }
    CompositionLocalProvider(LocalTourGuide provides app.tour, LocalWideWindow provides wide, LocalSheetHost provides sheets) {
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
                    val progress = if (shell.overlays.isEmpty()) backProgress else null
                    if (wide) {
                        // A board screen leaves the library and fills the window: the library and
                        // the board screens come and go as whole screens, with Material's shared
                        // axis (as a phone pushes them), and the back gesture seeks toward the one
                        // under the top.
                        val board = top?.takeIf { it.role == ListDetailPaneScaffoldRole.Extra }
                        val under = shell.stack.getOrNull(shell.stack.lastIndex - 1)?.takeIf { it.role == ListDetailPaneScaffoldRole.Extra }
                        SharedAxisContent(board, previous = under, seeks = board != null, backProgress = progress) { entry ->
                            if (entry != null) {
                                BoardPanes(app, entry, directive, shell::navigate, shell::back)
                            } else {
                                LibraryPanes(app, shell, directive, if (board == null) progress else null)
                            }
                        }
                    } else {
                        LibraryPanes(app, shell, directive, progress)
                    }
                }
            }

            // Full-window screens over everything (Android's settings screens, the setup flow),
            // coming and going with Material's shared axis on the expressive motion scheme's
            // springs; the back gesture shrinks the one on top, as Android's predictive back does
            // a full-screen surface. A wide window shows them as a dialog over the dimmed app
            // (a desktop's settings), fading in.
            val motion = MaterialTheme.motionScheme
            AnimatedContent(
                targetState = shell.overlays.lastOrNull(),
                transitionSpec = {
                    if (wide) {
                        // Without a size transform: the overlay is the window's size from its first frame (a
                        // size animated from zero grows the dimmed window and the dialog from its corner).
                        (fadeIn(motion.defaultEffectsSpec()) togetherWith fadeOut(motion.defaultEffectsSpec())).using(null)
                    } else {
                        val forward = targetState != null && (initialState == null || shell.overlays.size > 1)
                        (sharedAxisEnter(motion, forward) togetherWith sharedAxisExit(motion, forward)).using(null)
                    }
                },
                label = "overlay",
            ) { overlay ->
                if (overlay != null) {
                    val progress = if (overlay == shell.overlays.lastOrNull()) backProgress ?: 0f else 0f
                    if (wide) {
                        // Settings save as they change, so a click outside closes them; a form
                        // with Save (Repertoire Settings, the setup) closes only by its buttons.
                        val lightDismiss = overlay == Destination.Settings || overlay == Destination.Acknowledgements
                        OverlayDialog(onDismiss = if (lightDismiss) shell::closeOverlay else null, Modifier.backPreview(progress)) {
                            Overlay(app, shell, overlay)
                        }
                    } else {
                        Surface(Modifier.fillMaxSize().backPreview(progress)) { Overlay(app, shell, overlay) }
                    }
                }
            }

            // The tour's spotlight over the tour's screens, bars included; not over a screen or
            // sheet that covers them.
            if (shell.overlays.isEmpty() && shell.sheet == null) TourSpotlight(app.tour)

            // A wide window's sheets, as dialogs over all of it.
            sheets.Dialogs()
        }

        shell.sheet?.let { sheet ->
            // On the grouped pages' color, so the sheets' segmented lists and cards show.
            AdaptiveSheet(onDismissRequest = { shell.sheet = null }, containerColor = GroupedBackground) {
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
    val back: () -> Unit = shell::back
    val navigate: (Destination) -> Unit = shell::navigate
    val wide = windowDirective.maxHorizontalPartitions > 1
    // On wide windows the board screens are not the library's panes ([BoardPanes] replaces it):
    // the library stays as it was under them, also while it goes and comes back.
    val stack = if (wide) shell.stack.takeWhile { it.role != ListDetailPaneScaffoldRole.Extra } else shell.stack.toList()
    val top = stack.lastOrNull()
    // The overview under a phone's board screen stays the detail pane's, and the board screen
    // stays the extra pane's while it leaves, so neither pane shows the other's screen.
    val detailEntry = stack.lastOrNull { it.role == ListDetailPaneScaffoldRole.Detail }
    val extraEntry = stack.lastOrNull { it.role == ListDetailPaneScaffoldRole.Extra }
    val leaving = remember { object { var extra: StackEntry? = null } }
    if (extraEntry != null) leaving.extra = extraEntry
    // Two panes at most: the statistics are in the detail pane's dashboard, not a third.
    val directive = windowDirective.copy(maxHorizontalPartitions = windowDirective.maxHorizontalPartitions.coerceAtMost(2))

    val history = listOf(ThreePaneScaffoldDestinationItem<Long>(ListDetailPaneScaffoldRole.List)) +
        stack.map { ThreePaneScaffoldDestinationItem(it.role, it.id) }
    val value = calculateThreePaneScaffoldValue(
        maxHorizontalPartitions = directive.maxHorizontalPartitions,
        adaptStrategies = ListDetailPaneScaffoldDefaults.adaptStrategies(),
        destinationHistory = history,
    )
    // Material's predictive back for the panes: while the back gesture is in progress the
    // scaffold seeks toward the panes under the top screen (a fraction of the way, eased, as
    // Material's navigator seeks), animates there when it completes and back when cancelled.
    val previous = if (stack.isEmpty()) null else calculateThreePaneScaffoldValue(
        maxHorizontalPartitions = directive.maxHorizontalPartitions,
        adaptStrategies = ListDetailPaneScaffoldDefaults.adaptStrategies(),
        destinationHistory = history.dropLast(1),
    )
    val scaffoldState = remember { MutableThreePaneScaffoldState(value) }
    LaunchedEffect(value, backProgress, previous) {
        when {
            backProgress != null && previous != null && previous != value -> {
                val fraction = PredictiveBackEasing.transform(backProgress) * if (directive.maxHorizontalPartitions == 1) 1f / 8f else 1f / 10f
                scaffoldState.seekTo(fraction, previous, isPredictiveBackInProgress = true)
            }
            // New panes: shown at the start of the motion until they are laid out and drawn.
            scaffoldState.currentState != value && scaffoldState.targetState != value -> {
                scaffoldState.seekTo(0f, value)
                awaitFirstFrames()
                scaffoldState.animateTo(value)
            }
            // A back gesture completed or cancelled, or an interrupted motion.
            scaffoldState.currentState != value || scaffoldState.targetState != value -> scaffoldState.animateTo(value)
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
            SharedAxisPane(if (twoPanes) Modifier.preferredWidth(LibraryListWidth) else Modifier) {
                LibraryScreen(
                    app,
                    selectedEntryId = if (detailShown) shell.selectedEntryId else null,
                    showToday = directive.maxHorizontalPartitions == 1,
                    navigate = navigate,
                )
            }
        },
        detailPane = {
            SharedAxisPane {
                when {
                    detailEntry == null -> TodayDashboard(app, navigate)
                    twoPanes && detailEntry.screen is Screen.Overview -> OpenDocument(app, detailEntry.screen.entryId) { doc ->
                        OverviewDashboard(app, doc, navigate, onBack = null)
                    }
                    else -> Screen(app, detailEntry, BoardPane.Whole, navigate, if (listShown) null else back)
                }
            }
        },
        extraPane = {
            // A phone: the board screen alone; one pushed on another (Analysis on Build) comes
            // with the same shared axis, and the back gesture seeks toward the one under it.
            SharedAxisPane {
                val entry = extraEntry ?: leaving.extra
                val under = stack.getOrNull(stack.lastIndex - 1)?.takeIf { it.role == ListDetailPaneScaffoldRole.Extra }
                SharedAxisContent(entry, previous = under, seeks = extraEntry != null && under != null, backProgress = backProgress) { shown ->
                    if (shown != null) Screen(app, shown, BoardPane.Whole, navigate, back)
                }
            }
        },
    )
}

/**
 * Material's shared axis (X) on the expressive motion scheme's springs: the screen coming in
 * slides a tenth of the width from the side it comes from and fades in, the one going slides on
 * and fades out quickly. Forward comes from the end, back from the start.
 */
private fun sharedAxisEnter(motion: MotionScheme, forward: Boolean): EnterTransition =
    slideInHorizontally(motion.defaultSpatialSpec()) { it / 10 * if (forward) 1 else -1 } + fadeIn(motion.defaultEffectsSpec())

private fun sharedAxisExit(motion: MotionScheme, forward: Boolean): ExitTransition =
    slideOutHorizontally(motion.defaultSpatialSpec()) { -it / 10 * if (forward) 1 else -1 } + fadeOut(motion.fastEffectsSpec())

/**
 * A pane of the library's layout: where Material's pane motion slides a pane in or out across
 * the window (one pane: a push or a pop), the shared axis instead, in the same direction; other
 * pane motions (the panes side by side) are Material's.
 */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
@Composable
private fun ThreePaneScaffoldPaneScope.SharedAxisPane(
    modifier: Modifier = Modifier,
    content: @Composable AnimatedPaneScope.() -> Unit,
) {
    val motion = MaterialTheme.motionScheme
    val enter = when (paneMotion) {
        PaneMotion.EnterFromRight, PaneMotion.EnterFromRightDelayed -> sharedAxisEnter(motion, forward = true)
        PaneMotion.EnterFromLeft, PaneMotion.EnterFromLeftDelayed -> sharedAxisEnter(motion, forward = false)
        else -> motionDataProvider.calculateDefaultEnterTransition(paneRole)
    }
    val exit = when (paneMotion) {
        PaneMotion.ExitToLeft -> sharedAxisExit(motion, forward = true)
        PaneMotion.ExitToRight -> sharedAxisExit(motion, forward = false)
        else -> motionDataProvider.calculateDefaultExitTransition(paneRole)
    }
    AnimatedPane(modifier, enterTransition = enter, exitTransition = exit, content = content)
}

/**
 * Whole screens (a back-stack entry, or null for what is under them) coming and going with the
 * shared axis: forward when the new entry is newer (entries are numbered as they are pushed).
 * While the back gesture is in progress the screen on top shrinks and, when back shows another
 * screen here ([seeks]: [previous]), it seeks toward it, as Material's navigation does; it
 * finishes there when the gesture completes, and returns when it is cancelled.
 */
@Composable
private fun SharedAxisContent(
    target: StackEntry?,
    previous: StackEntry?,
    seeks: Boolean,
    backProgress: Float?,
    content: @Composable (StackEntry?) -> Unit,
) {
    val motion = MaterialTheme.motionScheme
    val state = remember { SeekableTransitionState(target) }
    LaunchedEffect(target, previous, seeks, backProgress) {
        when {
            backProgress != null && seeks && previous?.id != target?.id ->
                state.seekTo(PredictiveBackEasing.transform(backProgress), previous)
            // A new screen: shown at the start of the motion until it is laid out and drawn.
            state.currentState != target && state.targetState != target -> {
                state.seekTo(0f, target)
                awaitFirstFrames()
                state.animateTo(target)
            }
            // A back gesture completed or cancelled, or an interrupted motion.
            state.currentState != target || state.targetState != target -> state.animateTo(target)
        }
    }
    rememberTransition(state, label = "screens").AnimatedContent(
        transitionSpec = {
            val forward = (targetState?.id ?: 0L) > (initialState?.id ?: 0L)
            sharedAxisEnter(motion, forward) togetherWith sharedAxisExit(motion, forward)
        },
        contentKey = { it?.id },
    ) { shown ->
        // The back gesture shrinks the screen on top, as the full-window screens do.
        val progress = if (shown != null && shown.id == target?.id) backProgress ?: 0f else 0f
        Box(Modifier.fillMaxSize().backPreview(progress)) { content(shown) }
    }
}

/**
 * Waits until what a transition brings in has been composed, laid out and drawn once. A board
 * screen's first frame is long (the board, the explorer, the lists): a motion started with it
 * would spend most of its time on that frame and look like a cut, so it starts after it.
 */
private suspend fun awaitFirstFrames() {
    repeat(2) { withFrameNanos { } }
}

/**
 * Android's predictive back for a full-screen surface: while the back gesture is in progress
 * ([progress], 0 to 1) the screen shrinks and rounds its corners, showing what back goes to.
 */
private fun Modifier.backPreview(progress: Float): Modifier = graphicsLayer {
    val scale = 1f - 0.1f * PredictiveBackEasing.transform(progress)
    scaleX = scale
    scaleY = scale
    shape = RoundedCornerShape(32.dp * progress)
    clip = progress > 0f
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
    // A new layout for each screen (the shell's shared axis brings it in as a whole), so a screen
    // pushed on another starts from its own panes, at their size from the first frame.
    key(entry.id) {
        ListDetailPaneScaffold(
            directive = directive,
            value = value,
            listPane = {
                AnimatedPane(enterTransition = EnterTransition.None, exitTransition = ExitTransition.None) {
                    Screen(app, entry, BoardPane.List, navigate, onBack)
                }
            },
            detailPane = {
                AnimatedPane(enterTransition = EnterTransition.None, exitTransition = ExitTransition.None) {
                    Screen(app, entry, BoardPane.Detail, navigate, onBack)
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

/**
 * A full-window screen as a dialog on a wide window: centered on the dimmed app, at most 760 by
 * 880 dp, rounded as Material's dialogs. [onDismiss]: a click on the dimmed app closes it.
 */
@Composable
private fun OverlayDialog(onDismiss: (() -> Unit)?, modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Box(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.scrim.copy(alpha = 0.32f))
            // Modal: the app under it takes no clicks.
            .clickable(interactionSource = null, indication = null) { onDismiss?.invoke() },
        contentAlignment = Alignment.Center,
    ) {
        Surface(
            modifier.padding(32.dp).widthIn(max = 760.dp).heightIn(max = 880.dp).fillMaxSize()
                // Clicks inside stay inside.
                .clickable(interactionSource = null, indication = null) {},
            shape = MaterialTheme.shapes.extraLarge,
            shadowElevation = 6.dp,
        ) { CompositionLocalProvider(LocalInDialog provides true) { content() } }
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
