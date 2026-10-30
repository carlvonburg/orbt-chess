package org.orbtchess.orbt.ui.analysis

import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SecondaryTabRow
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.core.CloudEval
import org.orbtchess.orbt.core.NodeEval
import org.orbtchess.orbt.core.PvLine
import org.orbtchess.orbt.core.from
import org.orbtchess.orbt.core.to
import org.orbtchess.orbt.engine.EngineService
import org.orbtchess.orbt.explorer.CloudEvalClient
import org.orbtchess.orbt.lichess.LichessLinks
import org.orbtchess.orbt.ui.Destination
import org.orbtchess.orbt.ui.board.Board
import org.orbtchess.orbt.ui.board.BoardArrow
import org.orbtchess.orbt.ui.components.BoardColumn
import org.orbtchess.orbt.ui.components.BoardPane
import org.orbtchess.orbt.ui.components.DockedToolbar
import org.orbtchess.orbt.ui.components.Symbols
import org.orbtchess.orbt.ui.components.TitleWithSubtitle
import org.orbtchess.orbt.ui.components.TooltipIconButton
import org.orbtchess.orbt.ui.components.TooltipIconToggleButton
import org.orbtchess.orbt.ui.components.tabularDigits

/**
 * The analysis board (`AnalysisView.swift`), pushed on Build or Study and laid out as they are:
 * the engine's lines above the board (Lichess's cloud eval, then Stockfish), and in the panel
 * the moves with their variations and evaluations, and the explorer's moves. On a phone the
 * panel shows the explorer or the moves under the board; beside a board pane it shows both.
 * Going back (the shell calls [AnalysisModel.finish]) hands the line to Build or drops it.
 * Called once per pane it fills ([BoardPane]); both share [model].
 *
 * @param navigate [Destination.Settings] to sign in to Lichess.
 * @param onBack null where there is nothing to go back to in this pane.
 */
@Composable
fun AnalysisScreen(
    app: AppModel,
    model: AnalysisModel,
    pane: BoardPane,
    navigate: (Destination) -> Unit,
    onBack: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    // The engine follows the board, so it runs from the pane that shows it.
    if (pane != BoardPane.Panel) EngineEffects(app, model)
    // The settings are presented where the panel is (on wide windows the board pane's menu asks).
    if (pane != BoardPane.Board && model.showsSettings) {
        EngineSettingsSheet(app) {
            model.showsSettings = false
            reanalyse(app, model)
        }
    }
    when (pane) {
        BoardPane.Whole -> WholeScreen(app, model, navigate, onBack, modifier)
        BoardPane.Panel -> PanelScreen(app, model, navigate, onBack, modifier)
        BoardPane.Board -> BoardScreen(app, model, modifier)
    }
}

/**
 * Analyses the position on the board while the engine is on, records the best line's evaluation
 * in the move list once per depth, and stops the engine when the board leaves the screen.
 */
@Composable
private fun EngineEffects(app: AppModel, model: AnalysisModel) {
    val engine = app.engine
    val key = model.state.engineKey
    LaunchedEffect(key, model.engineOn) {
        if (model.engineOn) engine.analyse(key, model.state.position.epd()) else engine.stop()
    }
    // Covered (or popped): the engine stops, and runs again when the screen is back.
    DisposableEffect(engine) { onDispose { engine.stop() } }
    // The evaluation last written to the move list, so it is written once per depth.
    var recorded by remember { mutableStateOf<Pair<EngineService.Key, UInt>?>(null) }
    val lines = engine.lines
    LaunchedEffect(lines) {
        val current = model.state.engineKey
        val best = lines.lines.firstOrNull() ?: return@LaunchedEffect
        if (engine.analysed != current) return@LaunchedEffect
        if (recorded == current to lines.depth) return@LaunchedEffect
        recorded = current to lines.depth
        model.setEval(NodeEval(best.eval, lines.depth))
    }
}

/** Analyses the position again with the settings just changed. */
private fun reanalyse(app: AppModel, model: AnalysisModel) {
    if (!model.engineOn) return
    app.engine.stop()
    app.engine.analyse(model.state.engineKey, model.state.position.epd())
}

private enum class PanelTab { Explorer, Moves }

/** A phone: the board edge to edge under the engine's lines, the moves or the explorer below. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun WholeScreen(
    app: AppModel,
    model: AnalysisModel,
    navigate: (Destination) -> Unit,
    onBack: (() -> Unit)?,
    modifier: Modifier,
) {
    var tab by rememberSaveable { mutableStateOf(PanelTab.Explorer) }
    val status = app.engine.status(model)
    Scaffold(
        modifier = modifier.arrowKeys(model),
        topBar = {
            TopAppBar(
                // The subtitle says where the lines come from.
                title = { TitleWithSubtitle("Analysis", status) },
                navigationIcon = { BackButton(onBack) },
                actions = {
                    EngineToggle(model)
                    MoreMenu(app, model)
                },
            )
        },
        // The docked toolbar under the board, as beside a board pane: back, the moves, forward.
        bottomBar = { NavigationToolbar(model) },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            AnalysisEngineLines(app, model, Modifier.padding(horizontal = 16.dp))
            AnalysisBoard(app, model, Modifier.fillMaxWidth())
            // Two views of the panel's content: Material's secondary tabs (tabs switch between
            // content; segmented buttons choose options).
            SecondaryTabRow(selectedTabIndex = tab.ordinal) {
                PanelTab.entries.forEach { value ->
                    Tab(selected = tab == value, onClick = { tab = value }, text = { Text(value.name) })
                }
            }
            when (tab) {
                PanelTab.Explorer -> ExplorerList(app, model, showsHeader = false, navigate, Modifier.weight(1f))
                PanelTab.Moves -> MovesList(model, showsHeader = false, Modifier.weight(1f))
            }
        }
    }
}

/** Beside the board pane: the explorer first, where Build has its replies, the moves below; half each. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PanelScreen(
    app: AppModel,
    model: AnalysisModel,
    navigate: (Destination) -> Unit,
    onBack: (() -> Unit)?,
    modifier: Modifier,
) {
    Scaffold(
        modifier = modifier,
        topBar = { TopAppBar(title = { Text("Analysis") }, navigationIcon = { BackButton(onBack) }) },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            ExplorerList(app, model, showsHeader = true, navigate, Modifier.weight(1f))
            HorizontalDivider()
            MovesList(model, showsHeader = true, Modifier.weight(1f))
        }
    }
}

/**
 * The board pane: where the lines come from and the lines above the board; move navigation and
 * the history under it; the engine and the menu, which act on the board, end the top bar.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun BoardScreen(app: AppModel, model: AnalysisModel, modifier: Modifier) {
    Scaffold(
        modifier = modifier.arrowKeys(model),
        topBar = {
            TopAppBar(
                title = {},
                actions = {
                    EngineToggle(model)
                    MoreMenu(app, model)
                },
            )
        },
        bottomBar = { NavigationToolbar(model) },
    ) { padding ->
        BoardColumn(
            Modifier.fillMaxSize().padding(padding).padding(horizontal = 16.dp),
            above = {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    if (model.engineOn) {
                        Text(
                            app.engine.status(model),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    AnalysisEngineLines(app, model)
                }
            },
        ) {
            AnalysisBoard(app, model)
        }
    }
}

@Composable
private fun BackButton(onBack: (() -> Unit)?) {
    if (onBack != null) {
        IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") }
    }
}

/** The analysis board, the first moves of the engine's lines as arrows, the best one boldest. */
@Composable
private fun AnalysisBoard(app: AppModel, model: AnalysisModel, modifier: Modifier = Modifier) {
    val state = model.state
    Board(
        position = state.position,
        modifier = modifier,
        orientation = state.orientation,
        lastMove = state.lastMove,
        arrows = arrows(app.engine.shownLines(model)),
        movableSide = state.position.sideToMove(),
        onMove = model::play,
    )
}

private fun arrows(lines: List<PvLine>): List<BoardArrow> = lines.mapIndexedNotNull { index, line ->
    val move = line.moves.firstOrNull() ?: return@mapIndexedNotNull null
    BoardArrow(
        move.from,
        move.to,
        BoardArrow.Style.Engine,
        width = maxOf(0.1, 0.2 - index * 0.04),
        opacity = maxOf(0.3, 0.7 - index * 0.25),
    )
}

/** Back, the moves (tap one to go to it) and forward through the analysis (also ← and → on a keyboard). */
@Composable
private fun NavigationToolbar(model: AnalysisModel) {
    DockedToolbar {
        TooltipIconButton("Back", Symbols.previousMove, model::back, enabled = model.state.canBack, above = true)
        PathStrip(model, Modifier.weight(1f))
        TooltipIconButton("Forward", Symbols.nextMove, model::forward, enabled = model.state.canForward, above = true)
    }
}

/** ← and → go back and forward while the screen has focus (a keyboard on the desktop or a tablet). */
@Composable
private fun Modifier.arrowKeys(model: AnalysisModel): Modifier {
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }
    return onPreviewKeyEvent { event ->
        if (event.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
        when (event.key) {
            Key.DirectionLeft -> { model.back(); true }
            Key.DirectionRight -> { model.forward(); true }
            else -> false
        }
    }.focusRequester(focus).focusable()
}

/**
 * The moves to the board and the line ahead, as Build's history: tap a move to go to it. One
 * list for both, so going back or forward only moves the highlight; the moves ahead are faint.
 */
@Composable
private fun PathStrip(model: AnalysisModel, modifier: Modifier = Modifier) {
    val state = model.state
    val path = state.movesToBoard
    val line = path + state.lineAhead
    val firstPly = state.startPly + 1
    val list = rememberLazyListState()
    LaunchedEffect(path.size) {
        // The home button comes first.
        if (path.isNotEmpty()) list.animateScrollToItem(maxOf(0, path.size - 2))
    }
    LazyRow(
        modifier,
        state = list,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        item {
            TooltipIconButton("Start position", Icons.Outlined.Home, { model.goToPly(0) }, enabled = path.isNotEmpty(), above = true)
        }
        itemsIndexed(line) { index, move ->
            val ply = firstPly + index
            val current = index == path.size - 1
            FilterChip(
                selected = current,
                onClick = { model.goToPly(index + 1) },
                label = {
                    Text(
                        (if (ply % 2 == 1) "${ply / 2 + 1}. " else "") + move.san,
                        style = tabularDigits(),
                        fontWeight = if (current) FontWeight.Bold else FontWeight.Normal,
                    )
                },
                modifier = Modifier.alpha(if (index < path.size) 1f else 0.45f),
            )
        }
    }
}

/** The engine on or off. */
@Composable
private fun EngineToggle(model: AnalysisModel) {
    TooltipIconToggleButton("Engine", Symbols.analysis, checked = model.engineOn, onCheckedChange = { model.engineOn = it })
}

/** The analysis board's menu: Flip Board, Copy PGN, Open in Lichess, Engine Settings. */
@Suppress("DEPRECATION")
@Composable
private fun MoreMenu(app: AppModel, model: AnalysisModel) {
    var expanded by remember { mutableStateOf(false) }
    val clipboard = LocalClipboardManager.current
    val openPage = rememberOpenPage(app)
    TooltipIconButton("More", Symbols.more, { expanded = true })
    DropdownMenu(expanded, onDismissRequest = { expanded = false }) {
        DropdownMenuItem(
            text = { Text("Flip Board") },
            leadingIcon = { Icon(Symbols.flipBoard, contentDescription = null) },
            onClick = { expanded = false; model.flip() },
        )
        DropdownMenuItem(
            text = { Text("Copy PGN") },
            leadingIcon = { Icon(Icons.Outlined.ContentCopy, contentDescription = null) },
            onClick = { expanded = false; clipboard.setText(AnnotatedString(model.pgn())) },
        )
        DropdownMenuItem(
            text = { Text("Open in Lichess") },
            leadingIcon = { Icon(Symbols.openInBrowser, contentDescription = null) },
            onClick = {
                expanded = false
                openPage(LichessLinks.analysis(model.state.movesToBoard, model.state.orientation))
            },
        )
        HorizontalDivider()
        DropdownMenuItem(
            text = { Text("Engine Settings") },
            leadingIcon = { Icon(Symbols.settings, contentDescription = null) },
            onClick = { expanded = false; model.showsSettings = true },
        )
    }
}

/** The explorer's moves in the position on the board, with the Lichess cloud eval of each. */
@Composable
private fun ExplorerList(
    app: AppModel,
    model: AnalysisModel,
    showsHeader: Boolean,
    navigate: (Destination) -> Unit,
    modifier: Modifier = Modifier,
) {
    val epd = model.state.position.epd()
    val stats = model.document.stats(epd)
    var eval by remember { mutableStateOf<CloudEval?>(null) }
    LaunchedEffect(epd) {
        model.document.requestStats(epd)
        eval = null
        eval = CloudEvalClient.fetch(epd)
    }
    LazyColumn(modifier.fillMaxSize()) {
        analysisExplorer(app, model, stats, eval, showsHeader, navigate)
    }
}

/** The move list, scrolled so the move on the board stays in view. */
@Composable
private fun MovesList(model: AnalysisModel, showsHeader: Boolean, modifier: Modifier = Modifier) {
    val list = rememberLazyListState()
    val row = model.state.currentRow
    LaunchedEffect(row) {
        if (row == null) return@LaunchedEffect
        val index = row + if (showsHeader) 1 else 0
        val info = list.layoutInfo
        val item = info.visibleItemsInfo.firstOrNull { it.index == index }
        // Only when it is out of view, then with a row above it.
        val inView = item != null && item.offset >= info.viewportStartOffset &&
            item.offset + item.size <= info.viewportEndOffset
        if (!inView) list.animateScrollToItem(maxOf(0, index - 1))
    }
    LazyColumn(modifier.fillMaxSize(), state = list) {
        if (showsHeader) item { Heading("Moves") }
        analysisMoveList(model, model.state.moveList)
    }
}
