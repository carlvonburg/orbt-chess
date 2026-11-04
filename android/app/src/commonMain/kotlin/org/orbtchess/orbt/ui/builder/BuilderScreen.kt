package org.orbtchess.orbt.ui.builder

import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import org.orbtchess.orbt.core.Status
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.SnackbarHostState
import kotlinx.coroutines.launch
import kotlinx.coroutines.CoroutineScope
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isAltPressed
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.isMetaPressed
import androidx.compose.ui.input.key.isShiftPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.unit.dp
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.core.studied
import org.orbtchess.orbt.storage.ROOT_NODE
import org.orbtchess.orbt.ui.AnalysisOrigin
import org.orbtchess.orbt.ui.Destination
import org.orbtchess.orbt.ui.DrillKind
import org.orbtchess.orbt.ui.board.Board
import org.orbtchess.orbt.ui.components.BoardDetailPane
import org.orbtchess.orbt.ui.components.BoardPane
import org.orbtchess.orbt.ui.components.BoardToolbar
import org.orbtchess.orbt.ui.components.ExpressiveMenu
import org.orbtchess.orbt.ui.components.FloatingToolbarScaffold
import org.orbtchess.orbt.ui.components.Symbols
import org.orbtchess.orbt.ui.components.Tooltip
import org.orbtchess.orbt.ui.components.TooltipIconButton
import org.orbtchess.orbt.ui.components.ReviewPrompt
import org.orbtchess.orbt.ui.tips.CountShown
import org.orbtchess.orbt.ui.tips.LocalPopoverTip
import org.orbtchess.orbt.ui.tips.Tip
import org.orbtchess.orbt.ui.tips.TipCard
import org.orbtchess.orbt.ui.tips.Tips

/**
 * Build (`BuilderView.swift`, `BuilderSheets.swift`): the board with your moves, replies and
 * gaps, the explorer, the move history and navigation, adding and deleting moves, the gap list,
 * notes. Called once per pane it fills ([BoardPane]); both share [model].
 *
 * - [BoardPane.Whole] (a phone): the board, the move strip and the panel in one list scrolling
 *   under the floating toolbar (move navigation and the actions, as iPhone's bottom bar), the
 *   menu top trailing.
 * - [BoardPane.List] (the list pane on wide windows): the panel under the top app bar, which
 *   also has Biggest Gap and Study Branch (as iPad's panel bar). It presents the sheets and runs
 *   the explorer fetches and the coverage check.
 * - [BoardPane.Detail] (the detail pane): the board, and under it the floating toolbar with
 *   move navigation, the move strip and Analysis.
 *
 * @param navigate [Destination.Analysis] (origin [AnalysisOrigin.Build]), [Destination.Drill]
 *   (Study Branch), [Destination.CardInfo].
 * @param onBack null where there is nothing to go back to in this pane.
 */
@Composable
fun BuilderScreen(
    app: AppModel,
    model: BuilderModel,
    pane: BoardPane,
    navigate: (Destination) -> Unit,
    onBack: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    val snackbar = remember { SnackbarHostState() }
    val actions = BuilderActions(model, navigate, app.tips, app.reviewPrompt) { change -> snackbar.showCoverageChange(change) }
    // The one tip Browse shows (`AppTips`): on a phone a popover from what it explains, over the
    // board; beside the board, under the panel.
    val tip = if (pane != BoardPane.Detail) builderTip(model, app.tips) else null
    when (pane) {
        BoardPane.Whole -> CompositionLocalProvider(LocalPopoverTip provides tip) {
            WholeScreen(app, model, actions, snackbar, onBack, modifier)
        }
        BoardPane.List -> PanelScreen(app, model, actions, tip, snackbar, onBack, modifier)
        BoardPane.Detail -> BoardScreen(model, actions, modifier)
    }
    if (pane != BoardPane.Detail) {
        BuilderEffects(model)
        TipEffects(model, app.tips, tip)
        BuilderSheets(model, onStudyBranch = { actions.studyBranch(it) })
        SaveErrorDialog(model)
    }
}

/** What the bars and menus do, the same in every pane. */
private class BuilderActions(
    val model: BuilderModel,
    val navigate: (Destination) -> Unit,
    private val tips: Tips,
    private val reviewPrompt: ReviewPrompt,
    /** What a save did to coverage, shown for a moment. */
    private val showChange: suspend (CoverageChange) -> Unit,
) {
    private val document get() = model.document

    fun biggestGap() {
        tips.invalidate(Tip.BiggestGap)
        model.goToBiggestGap()
    }

    fun save(scope: CoroutineScope) {
        val before = CoverageChange.Snapshot(document.coverage.root)
        // Where the line starts and its first move, to find it once saved.
        val start = model.current
        val first = model.draft.firstOrNull()?.uci
        if (model.draftReachedTarget) tips.invalidate(Tip.LineCovered)
        tips.invalidate(Tip.SaveDraft)
        // The study tip's turn only once the gaps tip has had its own.
        tips.justSaved = tips.isDone(Tip.BiggestGap)
        model.saveDraft()
        val saved = first?.let { model.tree.childByUci(start, it) }
        val open = saved?.let { (document.coverage[it]?.gapCount ?: 0) > 0 } ?: false
        CoverageChange.of(before, CoverageChange.Snapshot(document.coverage.root), open)?.let { scope.launch { showChange(it) } }
        reviewPrompt.ask()
    }

    /** The analysis board on the position on the board; going back puts its line here as a draft. */
    fun analysis() = navigate(
        Destination.Analysis(document.entryId, null, model.movesToBoard, model.orientation, AnalysisOrigin.Build),
    )

    fun studyBranch(node: UInt = model.current) = study(DrillKind.Branch(node))

    /** Study Branch, Study Repertoire or Practice from the Study menu. */
    fun study(kind: DrillKind) {
        tips.invalidate(Tip.StudyBranch)
        navigate(Destination.Drill(document.entryId, kind))
    }

    val atRoot: Boolean get() = model.current == ROOT_NODE
    val canPractice: Boolean get() = document.learningProgress(model.current).studied > 0

    fun moveInfo() = navigate(Destination.CardInfo(document.entryId, model.current))

    val canBiggestGap: Boolean get() = model.canGoToBiggestGap
    val canStudyBranch: Boolean get() = document.learningProgress(model.current).cards > 0

    /** Move Info: the current position is one of your moves with a card. */
    val canMoveInfo: Boolean
        get() {
            val node = model.node ?: return false
            return node.sideToMove == document.color && document.studyCards[node.epd] != null
        }

}

/** The explorer fetch of the position on screen, and the coverage check while Build shows. */
@Composable
private fun BuilderEffects(model: BuilderModel) {
    val document = model.document
    DisposableEffect(document) {
        document.startCoverageCheck()
        onDispose { document.stopCoverageCheck() }
    }
    // The core waits until the position has been on screen for 300 ms.
    val epd = model.position.epd()
    LaunchedEffect(epd) { document.requestStats(epd) }
}

/**
 * Browse's tip (`AppTips.swift`): the first whose rule holds, from what the board shows. Your
 * move missing (a gap, or a new line at your move); in a new line at the opponent's move, the
 * replies that still need an answer, then (from your second move on) that it can be saved
 * already, or that it reached the target; on saved moves, the gaps below for Biggest Gap, and
 * after a later save the moves to study.
 */
private fun builderTip(model: BuilderModel, tips: Tips): Tip? {
    val document = model.document
    if (model.hasDraft) {
        if (model.draftTransposition != null) return null
        if (model.isUserTurnOnBoard) return tips.first(Tip.Answer to true)
        if (model.draftReachedTarget) return tips.first(Tip.LineCovered to true)
        // From the third move of the line (two of yours as White, the second of yours as Black
        // at the fourth): by then the replies' tip has been shown.
        if (model.draft.size >= 3) return tips.first(Tip.SaveDraft to true)
        return tips.first(Tip.Replies to (model.draftReplies?.any { it.required } == true))
    }
    val missing = model.node?.let { document.coverage[it.id]?.status } == Status.Gap
    // Gaps below this move (Biggest Gap's own fallback, the repertoire's biggest gap elsewhere,
    // is not "in this line").
    val canJump = model.canGoToBiggestGap && (document.coverage[model.current]?.gapCount ?: 0) > 0
    val canStudy = document.learningProgress(model.current).cards > 0
    return tips.first(
        Tip.Answer to missing,
        Tip.BiggestGap to canJump,
        Tip.StudyBranch to (canStudy && tips.justSaved),
    )
}

/**
 * The tips' actions: your move played where it was missing, a reply that needs an answer played
 * in a new line; a new line started ends the study tip's turn, and so does leaving Browse.
 */
@Composable
private fun TipEffects(model: BuilderModel, tips: Tips, tip: Tip?) {
    CountShown(tip)
    val count = model.draft.size
    var last by remember { mutableIntStateOf(count) }
    LaunchedEffect(count) {
        if (count > last) {
            tips.justSaved = false
            if (model.isUserTurnOnBoard) {
                if (count >= 2) tips.invalidate(Tip.Replies)
            } else {
                tips.invalidate(Tip.Answer)
            }
        }
        last = count
    }
    DisposableEffect(Unit) { onDispose { tips.justSaved = false } }
}

// MARK: Panes

@Composable
private fun WholeScreen(
    app: AppModel,
    model: BuilderModel,
    actions: BuilderActions,
    snackbar: SnackbarHostState,
    onBack: (() -> Unit)?,
    modifier: Modifier,
) {
    FloatingToolbarScaffold(
        modifier = modifier.builderKeys(model),
        topBar = { BuilderTopBar(model, actions, onBack, listPane = false) },
        toolbar = { BuilderFloatingToolbar(model, actions, phone = true) },
        snackbarHost = { CoverageSnackbarHost(snackbar) },
    ) { padding ->
        BuilderList(app, model, actions.navigate, Modifier.fillMaxSize(), contentPadding = padding) {
            item("board") {
                // Edge to edge on a phone; no larger than a tablet's column in a window alone.
                Board(
                    position = model.position,
                    modifier = Modifier.fillMaxWidth().wrapContentWidth().widthIn(max = 640.dp),
                    orientation = model.orientation,
                    lastMove = model.lastMove,
                    arrows = model.arrows,
                    movableSide = model.position.sideToMove(),
                    onMove = model::play,
                )
            }
            if (model.current != ROOT_NODE || model.hasDraft) {
                item("strip") { MovePathStrip(model) }
            }
        }
    }
}

/**
 * The list pane beside the board: the replies, the explorer and the rest of the panel, under the
 * screen's top app bar, and the tip pinned under them (the board is in its own pane, so no
 * popover over it).
 */
@Composable
private fun PanelScreen(
    app: AppModel,
    model: BuilderModel,
    actions: BuilderActions,
    tip: Tip?,
    snackbar: SnackbarHostState,
    onBack: (() -> Unit)?,
    modifier: Modifier,
) {
    Scaffold(
        modifier,
        topBar = { BuilderTopBar(model, actions, onBack, listPane = true) },
        snackbarHost = { CoverageSnackbarHost(snackbar) },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            BuilderList(app, model, actions.navigate, Modifier.weight(1f).fillMaxWidth())
            TipCard(tip, Modifier.padding(horizontal = 12.dp, vertical = 12.dp))
        }
    }
}

/** The detail pane: the board, and the floating toolbar with its moves under it. */
@Composable
private fun BoardScreen(model: BuilderModel, actions: BuilderActions, modifier: Modifier) {
    BoardDetailPane(
        modifier.builderKeys(model),
        toolbar = { BuilderFloatingToolbar(model, actions, phone = false) },
    ) {
        Board(
            position = model.position,
            orientation = model.orientation,
            lastMove = model.lastMove,
            arrows = model.arrows,
            movableSide = model.position.sideToMove(),
            onMove = model::play,
        )
    }
}

// MARK: Bars

/**
 * "Browse" over the repertoire's name, back, and the menu. In the list pane beside the board
 * (as iPad's panel bar), Biggest Gap and Study Branch before the menu.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun BuilderTopBar(model: BuilderModel, actions: BuilderActions, onBack: (() -> Unit)?, listPane: Boolean) {
    TopAppBar(
        title = { Text("Browse") },
        subtitle = { Text(model.document.name) },
        navigationIcon = { BackButton(onBack) },
        actions = {
            if (listPane) {
                if (model.hasDraft) DraftButtons(model, actions, above = false) else GapAndStudyButtons(actions, above = false)
            }
            BuilderMoreMenu(model, actions)
        },
    )
}

/**
 * The floating toolbar (iPhone's bottom bar; iPad's bar under the board). On a phone: back and
 * forward, then Biggest Gap, Study Branch and Analysis. Beside the board: back and forward, the
 * move strip, then Analysis (Biggest Gap and Study Branch are in the list pane's top app bar).
 * While a line is being built, on a phone: Analysis, then Discard and Save as one pair at the end
 * ([DraftButtons], iPhone's ✕ and ✓); beside the board they are in the list pane's top app bar.
 */
@Composable
private fun BuilderFloatingToolbar(model: BuilderModel, actions: BuilderActions, phone: Boolean) {
    BoardToolbar {
        NavigationButtons(model)
        if (phone) Spacer(Modifier.weight(1f)) else MovePathStrip(model, Modifier.weight(1f))
        if (model.hasDraft) {
            TooltipIconButton("Analysis", Symbols.analysis, actions::analysis, above = true)
            if (phone) DraftButtons(model, actions, above = true)
        } else {
            if (phone) GapAndStudyButtons(actions, above = true)
            TooltipIconButton("Analysis", Symbols.analysis, actions::analysis, above = true)
        }
    }
}

/**
 * While a line is being built: Discard (✕, tonal) and Save (✓, filled, the screen's one strong
 * action) side by side as one pair, as iPhone and iPad show them: at the end of the phone's
 * floating toolbar, and in the list pane's top app bar beside the board (where they replace
 * Biggest Gap and Study Branch, as in iPad's panel bar).
 */
@Composable
private fun DraftButtons(model: BuilderModel, actions: BuilderActions, above: Boolean) {
    Row(Modifier.padding(horizontal = 4.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Tooltip("Discard", above) {
            FilledTonalIconButton(onClick = model::discardDraft, shapes = IconButtonDefaults.shapes()) {
                Icon(Symbols.wrong, contentDescription = "Discard")
            }
        }
        val scope = rememberCoroutineScope()
        Tooltip("Save", above) {
            FilledIconButton(onClick = { actions.save(scope) }, shapes = IconButtonDefaults.shapes()) {
                Icon(Symbols.correct, contentDescription = "Save")
            }
        }
    }
}

@Composable
private fun BackButton(onBack: (() -> Unit)?) {
    if (onBack != null) {
        IconButton(onClick = onBack, shapes = IconButtonDefaults.shapes()) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") }
    }
}

/** Back and forward through the line (← and → on a keyboard), kept together as one group of the toolbar. */
@Composable
private fun NavigationButtons(model: BuilderModel) {
    Row {
        TooltipIconButton("Back", Symbols.previousMove, model::back, enabled = model.canBack, above = true)
        TooltipIconButton("Forward", Symbols.nextMove, model::forward, enabled = model.canForward, above = true)
    }
}

/** Biggest Gap and the Study menu; [above]: their tooltips above (a bottom toolbar) or below (a top app bar). */
@Composable
private fun GapAndStudyButtons(actions: BuilderActions, above: Boolean) {
    TooltipIconButton("Biggest Gap", BuilderSymbols.biggestGap, actions::biggestGap, enabled = actions.canBiggestGap, above = above)
    StudyMenu(actions, above)
}

/**
 * Today's moves in this branch (Anki's subdeck), the whole repertoire's session, or every learned
 * move in the branch again (`StudyMenu` in BuilderView.swift).
 */
@Composable
private fun StudyMenu(actions: BuilderActions, above: Boolean) {
    var open by remember { mutableStateOf(false) }
    val root = actions.atRoot
    Box {
        TooltipIconButton("Study", Symbols.study, { open = true }, above = above)
        ExpressiveMenu(open, onDismissRequest = { open = false }) {
            group {
                item("Study Repertoire", Symbols.study) { actions.study(DrillKind.Study) }
                if (!root) {
                    item("Study Branch", Symbols.study, enabled = actions.canStudyBranch) { actions.studyBranch() }
                }
                item(if (root) "Practice Repertoire" else "Practice Branch", Symbols.practice, enabled = actions.canPractice) {
                    actions.study(DrillKind.Practice(actions.model.current))
                }
            }
        }
    }
}

/** The builder's menu (`BuilderMoreMenu`): top trailing (over the panel on wide windows). */
@Composable
private fun BuilderMoreMenu(model: BuilderModel, actions: BuilderActions) {
    var open by remember { mutableStateOf(false) }
    val canUndo = model.document.canUndo
    val canMoveInfo = actions.canMoveInfo
    Box {
        TooltipIconButton("More", Symbols.more, { open = true })
        ExpressiveMenu(open, onDismissRequest = { open = false }) {
            group { item("Undo", BuilderSymbols.undo, enabled = canUndo) { model.undo() } }
            group {
                item("Outline", BuilderSymbols.outline) { model.sheet = BuilderSheet.Outline }
                item("Gaps", BuilderSymbols.gaps) { model.sheet = BuilderSheet.Gaps }
                item("Edit Note", BuilderSymbols.note) { model.sheet = BuilderSheet.Note }
                item("Move Info", Symbols.info, enabled = canMoveInfo) { actions.moveInfo() }
            }
            group { item("Flip Board", Symbols.flipBoard) { model.flip() } }
        }
    }
}

/**
 * The Swift app's Move commands on a keyboard: ←/→ through the line, ↑/↓ to the previous or
 * next line, ⇧⌘G (Ctrl+Shift+G) Biggest Gap, ⇧⌘F Flip Board.
 */
@Composable
private fun Modifier.builderKeys(model: BuilderModel): Modifier {
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }
    return this
        .onPreviewKeyEvent { event ->
            if (event.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
            val command = event.isMetaPressed || event.isCtrlPressed
            val plain = !command && !event.isShiftPressed && !event.isAltPressed
            when {
                plain && event.key == Key.DirectionLeft -> model.canBack.also { if (it) model.back() }
                plain && event.key == Key.DirectionRight -> model.canForward.also { if (it) model.forward() }
                plain && event.key == Key.DirectionUp -> true.also { model.sibling(-1) }
                plain && event.key == Key.DirectionDown -> true.also { model.sibling(1) }
                command && event.isShiftPressed && event.key == Key.G -> true.also { if (model.canGoToBiggestGap) model.goToBiggestGap() }
                command && event.isShiftPressed && event.key == Key.F -> true.also { model.flip() }
                else -> false
            }
        }
        .focusRequester(focus)
        .focusable()
}

/** Shows the document's save error. */
@Composable
internal fun SaveErrorDialog(model: BuilderModel) {
    val document = model.document
    val error = document.saveError ?: return
    AlertDialog(
        onDismissRequest = document::dismissSaveError,
        confirmButton = { TextButton(onClick = document::dismissSaveError, shapes = ButtonDefaults.shapes()) { Text("OK") } },
        title = { Text("Could not save") },
        text = { Text(error) },
    )
}
