package org.orbtchess.orbt.ui.builder

import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FlexibleBottomAppBar
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
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
import org.orbtchess.orbt.ui.tour.TourGuide
import org.orbtchess.orbt.ui.tour.TourScreen
import org.orbtchess.orbt.ui.tour.tourTarget
import org.orbtchess.orbt.storage.ROOT_NODE
import org.orbtchess.orbt.ui.AnalysisOrigin
import org.orbtchess.orbt.ui.Destination
import org.orbtchess.orbt.ui.DrillKind
import org.orbtchess.orbt.ui.board.Board
import org.orbtchess.orbt.ui.components.BoardDetailPane
import org.orbtchess.orbt.ui.components.BoardToolbar
import org.orbtchess.orbt.ui.components.BoardToolbarFab
import org.orbtchess.orbt.ui.components.BoardPane
import org.orbtchess.orbt.ui.components.Symbols
import org.orbtchess.orbt.ui.components.TooltipIconButton

/**
 * Build (`BuilderView.swift`, `BuilderSheets.swift`): the board with your moves, replies and
 * gaps, the explorer, the move history and navigation, adding and deleting moves, the gap list,
 * notes. Called once per pane it fills ([BoardPane]); both share [model].
 *
 * - [BoardPane.Whole] (a phone): the board, the move strip and the panel in one list; move
 *   navigation and the actions in the docked toolbar, the menu top trailing.
 * - [BoardPane.List] (the list pane on wide windows): the panel under the same top app bar. It
 *   presents the sheets and runs the explorer fetches and the coverage check.
 * - [BoardPane.Detail] (the detail pane): the board, and under it the floating toolbar with
 *   the move strip and the same actions, Save its FAB.
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
    val actions = BuilderActions(model, navigate, app.tour)
    when (pane) {
        BoardPane.Whole -> WholeScreen(app, model, actions, onBack, modifier)
        BoardPane.List -> PanelScreen(app, model, actions, onBack, modifier)
        BoardPane.Detail -> BoardScreen(model, actions, modifier)
    }
    if (pane != BoardPane.Detail) {
        BuilderEffects(model)
        TourEffects(model, app.tour, actions.inTour)
        BuilderSheets(model, onStudyBranch = { actions.studyBranch(it) })
        SaveErrorDialog(model)
    }
}

/** What the bars and menus do, the same in every pane. */
private class BuilderActions(val model: BuilderModel, val navigate: (Destination) -> Unit, val tour: TourGuide) {
    private val document get() = model.document

    /** The bundled sample, where the tour's tips show. */
    val inTour: Boolean get() = TourGuide.isSample(document.pgnFile)

    fun biggestGap() {
        model.goToBiggestGap()
        if (inTour) tour.advance(from = TourGuide.Step.BiggestGap, to = TourGuide.Step.Answer)
    }

    fun save() {
        // Where the draft starts, and its first move (Biggest Gap's reply).
        val start = model.current
        val first = model.draft.firstOrNull()?.uci
        model.saveDraft()
        if (inTour && tour.step == TourGuide.Step.Save) {
            tour.saved()
            // To the first new move, so Study Branch trains only the line just added (from
            // `start`, it would also train the rest of the repertoire).
            model.go(first?.let { model.tree.childByUci(start, it) } ?: start)
        }
    }

    /** The analysis board on the position on the board; going back puts its line here as a draft. */
    fun analysis() = navigate(
        Destination.Analysis(document.entryId, null, model.movesToBoard, model.orientation, AnalysisOrigin.Build),
    )

    fun studyBranch(node: UInt = model.current) {
        // The tour's last step.
        if (inTour) tour.advance(from = TourGuide.Step.Study, to = TourGuide.Step.Studying)
        navigate(Destination.Drill(document.entryId, DrillKind.Branch(node)))
    }

    fun moveInfo() = navigate(Destination.CardInfo(document.entryId, model.current))

    val canBiggestGap: Boolean get() = document.coverage.root?.biggestGap != null
    val canStudyBranch: Boolean get() = document.learningProgress(model.current).cards > 0

    /** Move Info: the current position is one of your moves with a card. */
    val canMoveInfo: Boolean
        get() {
            val node = model.node ?: return false
            return node.sideToMove == document.color && document.studyCards[node.epd] != null
        }

    /** "Save" or "Save 3". */
    val saveTitle: String get() = model.draft.size.let { if (it == 1) "Save" else "Save $it" }
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
 * The tour on the sample: Build is its next step; it builds the line until coverage is reached
 * (your answer, then a reply that needs one, and so on; Save only once every reply is below the
 * target).
 */
@Composable
private fun TourEffects(model: BuilderModel, tour: TourGuide, inTour: Boolean) {
    TourScreen(running = inTour)
    LaunchedEffect(inTour) {
        if (!inTour) return@LaunchedEffect
        tour.advance(from = TourGuide.Step.Browse, to = TourGuide.Step.BiggestGap)
        // A line being built is gone (the app was closed): find the gap again.
        if (!model.hasDraft) {
            for (step in listOf(TourGuide.Step.Answer, TourGuide.Step.Extend, TourGuide.Step.Save)) {
                tour.advance(from = step, to = TourGuide.Step.BiggestGap)
            }
        }
    }
    val draftStep = when {
        !inTour || tour.step !in listOf(TourGuide.Step.Answer, TourGuide.Step.Extend, TourGuide.Step.Save) || !model.hasDraft -> null
        model.isUserTurnOnBoard -> TourGuide.Step.Answer
        model.draftReachedTarget -> TourGuide.Step.Save
        else -> TourGuide.Step.Extend
    }
    LaunchedEffect(draftStep) { draftStep?.let { tour.draftChanged(to = it) } }
}

// MARK: Panes

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun WholeScreen(app: AppModel, model: BuilderModel, actions: BuilderActions, onBack: (() -> Unit)?, modifier: Modifier) {
    Scaffold(
        modifier = modifier.builderKeys(model),
        topBar = { BuilderTopBar(model, actions, onBack) },
        bottomBar = { BuilderToolbar(model, actions) },
    ) { padding ->
        BuilderList(app, model, actions.navigate, Modifier.fillMaxSize().padding(padding)) {
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

/** The list pane beside the board: the replies, the explorer and the rest of the panel, under the screen's top app bar. */
@Composable
private fun PanelScreen(app: AppModel, model: BuilderModel, actions: BuilderActions, onBack: (() -> Unit)?, modifier: Modifier) {
    Scaffold(modifier, topBar = { BuilderTopBar(model, actions, onBack) }) { padding ->
        BuilderList(app, model, actions.navigate, Modifier.fillMaxSize().padding(padding))
    }
}

/** The detail pane: the board, and the floating toolbar with its moves under it. */
@Composable
private fun BoardScreen(model: BuilderModel, actions: BuilderActions, modifier: Modifier) {
    BoardDetailPane(
        modifier.builderKeys(model),
        toolbar = { BuilderFloatingToolbar(model, actions) },
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

/** "Browse" over the repertoire's name, back, and the menu. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun BuilderTopBar(model: BuilderModel, actions: BuilderActions, onBack: (() -> Unit)?) {
    TopAppBar(
        title = { Text("Browse") },
        subtitle = { Text(model.document.name) },
        navigationIcon = { BackButton(onBack) },
        actions = { BuilderMoreMenu(model, actions) },
    )
}

/**
 * Material's docked toolbar: move navigation, then the actions, each named by its tooltip;
 * while a line is being built, Discard and Save, labelled (the toolbar's primary action, in
 * place of a FAB).
 */
@Composable
private fun BuilderToolbar(model: BuilderModel, actions: BuilderActions) {
    FlexibleBottomAppBar {
        NavigationButtons(model)
        if (model.hasDraft) {
            TooltipIconButton(
                "Analysis", Symbols.analysis, actions::analysis,
                Modifier.tourTarget(TourGuide.Target.Analysis), above = true,
            )
            DraftButtons(model, actions)
        } else {
            GapAndStudyButtons(actions)
            TooltipIconButton("Analysis", Symbols.analysis, actions::analysis, above = true)
        }
    }
}

/**
 * The detail pane's floating toolbar: back and forward, the move strip, then the docked
 * toolbar's actions; while a line is being built, Save is its FAB (Material's toolbar and FAB
 * pairing) and Discard a text button ending the toolbar, labelled as it drops the line (a text
 * button beside the main action, as in a dialog).
 */
@Composable
private fun BuilderFloatingToolbar(model: BuilderModel, actions: BuilderActions) {
    val save: (@Composable () -> Unit)? = if (model.hasDraft) {
        { BoardToolbarFab(actions.saveTitle, Symbols.correct, actions::save, Modifier.tourTarget(TourGuide.Target.Save)) }
    } else {
        null
    }
    BoardToolbar(mainAction = save) {
        NavigationButtons(model)
        MovePathStrip(model, Modifier.weight(1f))
        if (model.hasDraft) {
            TooltipIconButton(
                "Analysis", Symbols.analysis, actions::analysis,
                Modifier.tourTarget(TourGuide.Target.Analysis), above = true,
            )
            TextButton(onClick = model::discardDraft) { Text("Discard") }
        } else {
            GapAndStudyButtons(actions)
            TooltipIconButton("Analysis", Symbols.analysis, actions::analysis, above = true)
        }
    }
}

@Composable
private fun BackButton(onBack: (() -> Unit)?) {
    if (onBack != null) {
        IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") }
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

@Composable
private fun GapAndStudyButtons(actions: BuilderActions) {
    TooltipIconButton(
        "Biggest Gap", BuilderSymbols.biggestGap, actions::biggestGap,
        Modifier.tourTarget(TourGuide.Target.BiggestGap), enabled = actions.canBiggestGap, above = true,
    )
    TooltipIconButton(
        "Study Branch", Symbols.study, { actions.studyBranch() },
        Modifier.tourTarget(TourGuide.Target.StudyBranch), enabled = actions.canStudyBranch, above = true,
    )
}

/**
 * While a new line is on the board: drop it or keep it, side by side and named (Material's
 * text button beside the filled button for the main action, as in a dialog), Save the filled one.
 */
@Composable
private fun DraftButtons(model: BuilderModel, actions: BuilderActions, modifier: Modifier = Modifier) {
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        TextButton(onClick = model::discardDraft) { Text("Discard") }
        Button(onClick = actions::save, modifier = Modifier.tourTarget(TourGuide.Target.Save)) {
            Icon(Symbols.correct, contentDescription = null, modifier = Modifier.size(ButtonDefaults.IconSize))
            Spacer(Modifier.width(ButtonDefaults.IconSpacing))
            Text(actions.saveTitle)
        }
    }
}

/** The builder's menu (`BuilderMoreMenu`): top trailing, over the panel on wide windows. */
@Composable
private fun BuilderMoreMenu(model: BuilderModel, actions: BuilderActions) {
    var open by remember { mutableStateOf(false) }
    TooltipIconButton("More", Symbols.more, { open = true })
    DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
        fun pick(action: () -> Unit): () -> Unit = {
            open = false
            action()
        }
        DropdownMenuItem(
            text = { Text("Undo") },
            onClick = pick(model::undo),
            leadingIcon = { Icon(BuilderSymbols.undo, contentDescription = null) },
            enabled = model.document.canUndo,
        )
        HorizontalDivider()
        DropdownMenuItem(
            text = { Text("Outline") },
            onClick = pick { model.sheet = BuilderSheet.Outline },
            leadingIcon = { Icon(BuilderSymbols.outline, contentDescription = null) },
        )
        DropdownMenuItem(
            text = { Text("Gaps") },
            onClick = pick { model.sheet = BuilderSheet.Gaps },
            leadingIcon = { Icon(BuilderSymbols.gaps, contentDescription = null) },
        )
        DropdownMenuItem(
            text = { Text("Edit Note") },
            onClick = pick { model.sheet = BuilderSheet.Note },
            leadingIcon = { Icon(BuilderSymbols.note, contentDescription = null) },
        )
        DropdownMenuItem(
            text = { Text("Move Info") },
            onClick = pick(actions::moveInfo),
            leadingIcon = { Icon(Symbols.info, contentDescription = null) },
            enabled = actions.canMoveInfo,
        )
        DropdownMenuItem(
            text = { Text("Flip Board") },
            onClick = pick(model::flip),
            leadingIcon = { Icon(Symbols.flipBoard, contentDescription = null) },
        )
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
                command && event.isShiftPressed && event.key == Key.G -> true.also { model.goToBiggestGap() }
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
        confirmButton = { TextButton(onClick = document::dismissSaveError) { Text("OK") } },
        title = { Text("Could not save") },
        text = { Text(error) },
    )
}
