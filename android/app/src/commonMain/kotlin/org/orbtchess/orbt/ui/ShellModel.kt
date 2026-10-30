package org.orbtchess.orbt.ui

import androidx.compose.material3.adaptive.ExperimentalMaterial3AdaptiveApi
import androidx.compose.material3.adaptive.layout.ListDetailPaneScaffoldRole
import androidx.compose.material3.adaptive.layout.ThreePaneScaffoldRole
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.core.DrillMode
import org.orbtchess.orbt.storage.ROOT_NODE
import org.orbtchess.orbt.storage.RepertoireDocument
import org.orbtchess.orbt.storage.TrainingDefaults
import org.orbtchess.orbt.ui.analysis.AnalysisModel
import org.orbtchess.orbt.ui.builder.BuilderModel
import org.orbtchess.orbt.ui.training.DrillModel
import org.orbtchess.orbt.ui.training.StudyAllModel

/** The phone's tabs (`AppTab`). Wide windows have no tabs: statistics are beside each overview. */
enum class Tab { Repertoires, Statistics }

/**
 * A screen on the library's back stack with what it shows: its pane (the overview in the detail
 * pane, board screens in the extra pane on a phone, the whole window on wider ones) and the
 * model made for it before it was shown.
 */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
class StackEntry internal constructor(
    val id: Long,
    val destination: Destination,
    val screen: Screen,
) {
    /** The overview is the list's detail; Build, Study and Analysis show their board beside their panel. */
    val role: ThreePaneScaffoldRole
        get() = if (screen is Screen.Overview) ListDetailPaneScaffoldRole.Detail else ListDetailPaneScaffoldRole.Extra
}

/** What a back-stack entry shows (`LibraryScreens.Screen`). */
sealed interface Screen {
    val entryId: String?

    class Overview(override val entryId: String) : Screen
    class Builder(val model: BuilderModel) : Screen { override val entryId get() = model.document.entryId }
    class Drill(val model: DrillModel) : Screen { override val entryId get() = model.document.entryId }
    class StudyAll(val model: StudyAllModel) : Screen { override val entryId: String? get() = null }
    class Analysis(val model: AnalysisModel) : Screen { override val entryId get() = model.document.entryId }
}

/**
 * The navigation state (LibraryView.swift's path, selection, sheets and `LibraryScreens`): the
 * library's back stack, the full-window screens over it, the bottom sheet and the phone's tab.
 * A ViewModel, so it outlives rotation with the models it made.
 *
 * Every navigation request from a screen comes through [navigate]; this decides where the
 * destination goes and makes its model, so screens never wire themselves into the shell.
 */
class ShellModel(private val app: AppModel) : ViewModel() {
    // The main thread's scope (viewModelScope needs a Main dispatcher the desktop gets from Swing).
    private val scope: CoroutineScope = MainScope()

    /** The library's back stack above the library itself: an overview, then the screens pushed on it. */
    val stack = mutableStateListOf<StackEntry>()

    /** Full-window screens over everything: Settings, Acknowledgements, a repertoire's settings, the setup. */
    val overlays = mutableStateListOf<Destination>()

    /** The bottom sheet shown: Card Info or Study Options. */
    var sheet: Destination? by mutableStateOf(null)

    var tab: Tab by mutableStateOf(Tab.Repertoires)

    /** The Statistics tab's scope (`AppModel.statisticsScope`): an overview's Statistics row sets it. */
    var statisticsScope: StatisticsScope by mutableStateOf(StatisticsScope.All)

    /** An error to show in a dialog. */
    var error: String? by mutableStateOf(null)

    /** Whether the window shows several panes side by side (set by the shell from the scaffold's directive). */
    var wide: Boolean by mutableStateOf(false)
        internal set

    private var nextId = 1L

    init {
        app.documents.onRemoved = ::closeEntry
    }

    /** A repertoire deleted elsewhere while shown: its screens, settings and sheet close. */
    private fun closeEntry(entryId: String) {
        val first = stack.indexOfFirst { it.screen.entryId == entryId }
        if (first >= 0) replaceStack(stack.take(first))
        overlays.removeAll { (it as? Destination.RepertoireSettings)?.entryId == entryId }
        when (val shown = sheet) {
            is Destination.CardInfo -> if (shown.entryId == entryId) sheet = null
            is Destination.StudyOptions -> if (shown.entryId == entryId) sheet = null
            else -> Unit
        }
    }

    val top: StackEntry? get() = stack.lastOrNull()

    /** The repertoire the library selects (its overview is at the bottom of the stack). */
    val selectedEntryId: String? get() = (stack.firstOrNull()?.screen as? Screen.Overview)?.entryId

    /** Shows [destination] where it belongs. */
    fun navigate(destination: Destination) {
        when (destination) {
            Destination.Library -> {
                tab = Tab.Repertoires
                replaceStack(emptyList())
            }
            is Destination.Overview -> {
                tab = Tab.Repertoires
                val id = app.documents.currentId(destination.entryId)
                if (selectedEntryId == id && stack.size == 1) return
                replaceStack(listOf(entry(Destination.Overview(id), Screen.Overview(id))))
            }
            // Wide windows show the statistics beside Today or the overview; a phone switches to
            // the Statistics tab with that scope, as the overview's Statistics row does in Swift.
            is Destination.Statistics -> when {
                !wide -> {
                    statisticsScope = destination.scope
                    tab = Tab.Statistics
                }
                destination.scope is StatisticsScope.Repertoire -> navigate(Destination.Overview(destination.scope.entryId))
                else -> navigate(Destination.Library)
            }
            Destination.Settings, Destination.Acknowledgements,
            is Destination.RepertoireSettings, is Destination.Setup -> overlays.add(destination)
            is Destination.CardInfo, is Destination.StudyOptions -> sheet = destination
            is Destination.Builder, is Destination.Drill, is Destination.StudyAll, is Destination.Analysis ->
                scope.launch { push(destination) }
        }
    }

    /** Goes back one step: the sheet, a full-window screen, the Statistics tab, then the stack. */
    fun back() {
        when {
            sheet != null -> sheet = null
            overlays.isNotEmpty() -> overlays.removeAt(overlays.lastIndex)
            tab == Tab.Statistics -> tab = Tab.Repertoires
            stack.isNotEmpty() -> replaceStack(stack.dropLast(1))
        }
    }

    val canGoBack: Boolean
        get() = sheet != null || overlays.isNotEmpty() || tab == Tab.Statistics || stack.isNotEmpty()

    /** Closes the top full-window screen. */
    fun closeOverlay() {
        if (overlays.isNotEmpty()) overlays.removeAt(overlays.lastIndex)
    }

    /** After a repertoire is deleted: nothing of it stays shown. */
    fun showLibrary() {
        overlays.clear()
        sheet = null
        navigate(Destination.Library)
    }

    /** Pushes a board screen once its model is made (`go(to:)`): on its repertoire's overview. */
    private suspend fun push(destination: Destination) {
        tab = Tab.Repertoires
        val screen = make(destination) ?: run {
            error = "The repertoire could not be opened."
            return
        }
        val new = entry(destination, screen)
        val entryId = screen.entryId
        val overview = stack.firstOrNull()?.takeIf { it.screen is Screen.Overview }
        val path: List<StackEntry> = when {
            // Study All starts from Today.
            entryId == null -> listOf(new)
            // Another repertoire (from Today or Statistics): its overview first.
            overview == null || (overview.screen as Screen.Overview).entryId != entryId ->
                listOf(entry(Destination.Overview(entryId), Screen.Overview(entryId)), new)
            // The analysis board covers the screen it is opened from, keeping everything under it.
            destination is Destination.Analysis -> stack + new
            // Build or Study from another board screen: the overview, only the screen it is
            // opened from, then the new one (`openScreen`), so switching doesn't pile up screens.
            else -> listOfNotNull(overview, stack.drop(1).lastOrNull()) + new
        }
        replaceStack(path)
    }

    private fun entry(destination: Destination, screen: Screen) = StackEntry(nextId++, destination, screen)

    /** Makes the model a board screen needs, opening its repertoire (`LibraryScreens.make`). */
    private suspend fun make(destination: Destination): Screen? {
        suspend fun open(id: String): RepertoireDocument? {
            val entry = app.library.entry(app.documents.currentId(id)) ?: return null
            return app.documents.open(entry)
        }
        return when (destination) {
            is Destination.Builder -> open(destination.entryId)?.let {
                Screen.Builder(BuilderModel(it, destination.start, destination.showGaps))
            }
            is Destination.Drill -> open(destination.entryId)?.let { doc ->
                Screen.Drill(
                    when (val kind = destination.kind) {
                        DrillKind.Study -> DrillModel(doc, DrillMode.Study)
                        DrillKind.LearnMore -> DrillModel(doc, DrillMode.Study, learnMore = TrainingDefaults.LEARN_MORE_COUNT)
                        DrillKind.Practice -> DrillModel(doc, DrillMode.Branch(ROOT_NODE))
                        is DrillKind.Branch -> DrillModel(doc, DrillMode.Branch(kind.node))
                    },
                )
            }
            is Destination.StudyAll -> {
                val entries = destination.entryIds.mapNotNull { app.library.entry(app.documents.currentId(it)) }
                Screen.StudyAll(StudyAllModel(app, entries).also { it.openCurrent() })
            }
            is Destination.Analysis -> open(destination.entryId)?.let { doc ->
                val origin = when (destination.origin) {
                    AnalysisOrigin.Study -> AnalysisModel.Origin.Study
                    AnalysisOrigin.Build -> (top?.screen as? Screen.Builder)?.let { AnalysisModel.Origin.Build(it.model) }
                        ?: AnalysisModel.Origin.Study
                }
                Screen.Analysis(AnalysisModel(doc, destination.startFen, destination.moves, destination.orientation, origin))
            }
            else -> null
        }
    }

    /**
     * Sets the back stack. Screens no longer on it are finished (the analysis board hands its
     * line back) and their models closed once their pane has animated away.
     */
    private fun replaceStack(path: List<StackEntry>) {
        val removed = stack.filter { old -> path.none { it.id == old.id } }
        stack.clear()
        stack.addAll(path)
        if (removed.isEmpty()) return
        removed.forEach { (it.screen as? Screen.Analysis)?.model?.finish() }
        scope.launch {
            delay(1_000)
            removed.forEach { close(it.screen) }
        }
    }

    private fun close(screen: Screen) {
        when (screen) {
            is Screen.Builder -> screen.model.close()
            is Screen.Drill -> screen.model.close()
            is Screen.StudyAll -> screen.model.close()
            is Screen.Analysis -> screen.model.close()
            is Screen.Overview -> Unit
        }
    }

    override fun onCleared() {
        stack.forEach { close(it.screen) }
        scope.cancel()
    }
}
