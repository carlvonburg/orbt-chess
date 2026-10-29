package org.orbtchess.orbt.ui.training

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.FormatIndentIncrease
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Circle
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.automirrored.outlined.AltRoute
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material.icons.outlined.SportsScore
import androidx.compose.material3.BottomAppBar
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.FloatingActionButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameMillis
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.core.Counts
import org.orbtchess.orbt.core.Feedback
import org.orbtchess.orbt.core.Phase
import org.orbtchess.orbt.core.QueueKind
import org.orbtchess.orbt.storage.NodeId
import org.orbtchess.orbt.storage.RepertoireDocument
import org.orbtchess.orbt.ui.AnalysisOrigin
import org.orbtchess.orbt.ui.Destination
import org.orbtchess.orbt.ui.board.Board
import org.orbtchess.orbt.ui.components.BoardColumn
import org.orbtchess.orbt.ui.components.BoardPane
import org.orbtchess.orbt.ui.components.SymbolLabel
import org.orbtchess.orbt.ui.components.Symbols
import org.orbtchess.orbt.ui.components.tabularDigits
import org.orbtchess.orbt.ui.theme.ThemeColor
import org.orbtchess.orbt.ui.theme.color

/** The repertoire studied after this one in Study All, and how to start it. */
class NextRepertoire(val name: String, val start: () -> Unit)

/**
 * Study (`DrillView.swift`): lines played from move 1, your moves graded Again/Good, hints,
 * the due counts, the line history; when the session ends, [StudyFinishedScreen] in place (as
 * in Swift, not a separate destination). Called once per pane it fills ([BoardPane]); both
 * share [model].
 *
 * - [BoardPane.Whole] (a phone): the board, the moves played, the opening and what to do with
 *   the counts; Hint, Browse Repertoire and Analysis in the bottom app bar, Next Line its FAB.
 * - [BoardPane.Panel]: the counts with what each means, the opening and what to do; Hint and
 *   Browse Repertoire in the top app bar.
 * - [BoardPane.Board]: the board, with the moves played, Analysis and Next Line in the bottom
 *   app bar.
 *
 * @param next the next repertoire when studying all of them (Study All), else null.
 * @param navigate [Destination.Analysis] (origin [AnalysisOrigin.Study]), [Destination.Builder]
 *   (Browse Repertoire, from the move on the board).
 * @param onBack null where there is nothing to go back to in this pane.
 */
@Composable
fun DrillScreen(
    app: AppModel,
    model: DrillModel,
    pane: BoardPane,
    navigate: (Destination) -> Unit,
    onBack: (() -> Unit)?,
    modifier: Modifier = Modifier,
    next: NextRepertoire? = null,
) {
    // The pane with the board runs the clock: leaving it (Analysis, Browse pushed on top, or
    // the screen popped) stops the opponent's moves; training goes on (or waits for Next at a
    // line's end) when it is back. The coverage check runs while it shows (`checksCoverage`).
    if (pane != BoardPane.Panel) {
        DisposableEffect(model) {
            model.start()
            model.document.startCoverageCheck()
            onDispose {
                model.stop()
                model.document.stopCoverageCheck()
            }
        }
        Haptics(model)
    }

    val actions = DrillActions(model, navigate)
    when (pane) {
        BoardPane.Whole -> PhoneLayout(app, model, actions, navigate, onBack, next, modifier)
        BoardPane.Panel -> PanelLayout(app, model, actions, navigate, onBack, next, modifier)
        BoardPane.Board -> BoardLayout(model, actions, modifier)
    }
}

/** What the bars do: each leaves the board to look the move up, so counts as Again. */
private class DrillActions(private val model: DrillModel, private val navigate: (Destination) -> Unit) {
    fun browse() {
        val node = model.browseNode() ?: return
        navigate(Destination.Builder(model.document.entryId, start = node))
    }

    /** The analysis board from the position on the board, with the moves to it. */
    fun analyze() {
        val moves = model.analysisMoves()
        navigate(Destination.Analysis(model.document.entryId, null, moves, model.color, AnalysisOrigin.Study))
    }
}

/** Success or error, as the Swift app's `sensoryFeedback`. */
@Composable
private fun Haptics(model: DrillModel) {
    val haptics = LocalHapticFeedback.current
    val feedback = model.feedback
    LaunchedEffect(feedback) {
        when (feedback) {
            is Feedback.Correct -> haptics.performHapticFeedback(HapticFeedbackType.Confirm)
            is Feedback.Wrong -> haptics.performHapticFeedback(HapticFeedbackType.Reject)
            else -> Unit
        }
    }
}

// MARK: Layouts

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DrillTopBar(model: DrillModel, onBack: (() -> Unit)?, actions: @Composable () -> Unit = {}) {
    TopAppBar(
        title = {
            Column {
                Text(model.mode.title, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(
                    model.document.name,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        },
        navigationIcon = {
            if (onBack != null) {
                IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") }
            }
        },
        actions = { actions() },
    )
}

/** A phone: everything in one column, the actions in the bottom app bar (Swift's bottom toolbar). */
@Composable
private fun PhoneLayout(
    app: AppModel,
    model: DrillModel,
    actions: DrillActions,
    navigate: (Destination) -> Unit,
    onBack: (() -> Unit)?,
    next: NextRepertoire?,
    modifier: Modifier,
) {
    if (model.finished) {
        Scaffold(modifier, topBar = { DrillTopBar(model, onBack) }) { padding ->
            StudyFinishedScreen(app, model, next, navigate, onDone = { onBack?.invoke() }, Modifier.padding(padding))
        }
        return
    }
    Scaffold(
        modifier,
        topBar = { DrillTopBar(model, onBack) },
        bottomBar = {
            BottomAppBar(
                actions = {
                    // Disabled at a line's end (no move to ask about), in its place.
                    HintButton(model)
                    BrowseButton(actions)
                    AnalysisButton(actions)
                },
                floatingActionButton = { NextLineButton(model) },
            )
        },
    ) { padding ->
        Column(
            Modifier.padding(padding).fillMaxSize(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            // Edge to edge on a phone, as in the builder.
            DrillBoard(model, Modifier.widthIn(max = 680.dp).fillMaxWidth())
            // Laid out like the builder: move list, then opening name; then what to do, with
            // the counts (status, not a control, so not in a bar).
            Column(
                Modifier.widthIn(max = 680.dp).fillMaxWidth().padding(horizontal = 16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                LineHistory(model.document.tree, model.playedNodes)
                OpeningName(model)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Status(model, Modifier.weight(1f))
                    Spacer(Modifier.size(12.dp))
                    StudyCounts(model.counts, model.askedKind)
                }
            }
        }
    }
}

/** The detail pane beside the board: the counts with what each means, and what to do. */
@Composable
private fun PanelLayout(
    app: AppModel,
    model: DrillModel,
    actions: DrillActions,
    navigate: (Destination) -> Unit,
    onBack: (() -> Unit)?,
    next: NextRepertoire?,
    modifier: Modifier,
) {
    val finished = model.finished
    Scaffold(
        modifier,
        topBar = {
            DrillTopBar(model, onBack) {
                if (!finished) {
                    HintButton(model)
                    BrowseButton(actions)
                }
            }
        },
    ) { padding ->
        if (finished) {
            StudyFinishedScreen(app, model, next, navigate, onDone = { onBack?.invoke() }, Modifier.padding(padding))
        } else {
            Column(
                Modifier.padding(padding).fillMaxSize().verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                StudyCountsList(model.counts, model.askedKind)
                Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    OpeningName(model)
                    Status(model)
                }
            }
        }
    }
}

/** The extra pane: the board, the moves played, Analysis and Next Line in the bottom app bar. */
@Composable
private fun BoardLayout(model: DrillModel, actions: DrillActions, modifier: Modifier) {
    val finished = model.finished
    Scaffold(
        modifier,
        bottomBar = {
            if (!finished) {
                BottomAppBar(
                    actions = {
                        LineHistory(model.document.tree, model.playedNodes, Modifier.weight(1f).padding(start = 8.dp))
                        AnalysisButton(actions)
                    },
                    floatingActionButton = { NextLineButton(model) },
                )
            }
        },
    ) { padding ->
        BoardColumn(Modifier.padding(padding).fillMaxSize().padding(16.dp)) {
            DrillBoard(model)
        }
    }
}

// MARK: Bar items

@Composable
private fun HintButton(model: DrillModel) {
    IconButton(onClick = model::hint, enabled = model.canMove) { Icon(Symbols.hint, contentDescription = "Hint") }
}

@Composable
private fun BrowseButton(actions: DrillActions) {
    IconButton(onClick = actions::browse) {
        Icon(Icons.AutoMirrored.Outlined.FormatIndentIncrease, contentDescription = "Browse Repertoire")
    }
}

@Composable
private fun AnalysisButton(actions: DrillActions) {
    IconButton(onClick = actions::analyze) { Icon(Symbols.analysis, contentDescription = "Analysis") }
}

/** Next, once a finished line waits (paused, or looked at): the one thing to do, so the FAB. */
@Composable
private fun NextLineButton(model: DrillModel) {
    if (model.phase == Phase.LINE_DONE && model.nextLineAt == null) {
        ExtendedFloatingActionButton(
            onClick = model::nextLine,
            icon = { Icon(Symbols.nextLine, contentDescription = null) },
            text = { Text("Next Line") },
            elevation = FloatingActionButtonDefaults.bottomAppBarFabElevation(),
        )
    }
}

// MARK: Content

/** The study board: moves played on it answer the card. */
@Composable
private fun DrillBoard(model: DrillModel, modifier: Modifier = Modifier) {
    val end = model.nextLineAt
    Box(modifier, contentAlignment = Alignment.Center) {
        // While a finished line counts down to the next one the board dims under the countdown;
        // a tap on it pauses, and Next comes in the bar.
        Board(
            position = model.position,
            modifier = Modifier.fillMaxWidth().alpha(if (end == null) 1f else 0.4f),
            orientation = model.color,
            lastMove = model.lastMove,
            arrows = model.arrows,
            badge = model.badge,
            movableSide = if (model.canMove) model.color else null,
            onMove = model::userMoved,
        )
        if (end != null) {
            Box(
                Modifier.matchParentSize()
                    .clickable(onClickLabel = "Pause") { model.pause() }
                    .semantics { contentDescription = "Stays on this line until you choose Next" },
                contentAlignment = Alignment.Center,
            ) {
                LineCountdown(end)
            }
        }
    }
}

/** The time left before the next line, on the dimmed board: an emptying ring, "Next line in N" and what a tap does. */
@Composable
private fun LineCountdown(end: Long) {
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(end) {
        while (now < end) withFrameMillis { now = System.currentTimeMillis() }
    }
    val left = (end - now).coerceAtLeast(0)
    Surface(shape = MaterialTheme.shapes.extraLarge, color = MaterialTheme.colorScheme.surfaceContainerHigh, tonalElevation = 3.dp) {
        Column(
            Modifier.padding(20.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Box(contentAlignment = Alignment.Center) {
                CircularProgressIndicator(progress = { left.toFloat() / DrillModel.LINE_DONE_MS })
                Icon(Icons.Filled.Pause, contentDescription = null, modifier = Modifier.size(18.dp))
            }
            Text(
                "Next line in ${(left + 999) / 1000}",
                style = tabularDigits(MaterialTheme.typography.titleMedium),
            )
            Text(
                "Tap to pause",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun OpeningName(model: DrillModel) {
    model.openingName?.let {
        Text(it, style = MaterialTheme.typography.titleSmall, maxLines = 2, overflow = TextOverflow.Ellipsis)
    }
}

/** What to do now, or how the last move went. */
@Composable
private fun Status(model: DrillModel, modifier: Modifier = Modifier) {
    val style = MaterialTheme.typography.titleMedium
    when (val feedback = model.feedback) {
        is Feedback.Correct -> SymbolLabel("Correct", Icons.Filled.CheckCircle, modifier, ThemeColor.correct, style)
        is Feedback.Wrong ->
            SymbolLabel("Not quite, play ${feedback.expected.san}", Icons.Filled.Cancel, modifier, ThemeColor.wrong, style)
        is Feedback.Alternative ->
            SymbolLabel("That's your alternative. Play your main move.", Icons.AutoMirrored.Outlined.AltRoute, modifier, ThemeColor.todo, style)
        is Feedback.NewMove ->
            SymbolLabel("New move: play ${feedback.v1.san}", Icons.Outlined.AutoAwesome, modifier, ThemeColor.new, style)
        is Feedback.None -> when {
            model.phase == Phase.LINE_DONE -> SecondaryLabel("End of the line", Icons.Outlined.SportsScore, modifier)
            model.isUserTurn -> SymbolLabel("Your move", Icons.Filled.Circle, modifier, style = style)
            else -> SecondaryLabel("Playing the line…", Icons.Outlined.Circle, modifier)
        }
    }
}

@Composable
private fun SecondaryLabel(text: String, icon: ImageVector, modifier: Modifier) {
    CompositionLocalProvider(LocalContentColor provides MaterialTheme.colorScheme.onSurfaceVariant) {
        SymbolLabel(text, icon, modifier, style = MaterialTheme.typography.titleMedium)
    }
}

/** The moves played so far on a study line. Read-only: going to a move would show its answer. */
@Composable
private fun LineHistory(tree: RepertoireDocument.Tree, nodes: List<NodeId>, modifier: Modifier = Modifier) {
    val state = rememberLazyListState()
    LaunchedEffect(nodes.lastOrNull()) { if (nodes.isNotEmpty()) state.animateScrollToItem(nodes.lastIndex) }
    // Plies from the line's position: after a transposition a node's own ply can differ.
    val rootPly = tree.root.ply.toInt()
    LazyRow(modifier.fillMaxWidth(), state = state, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        itemsIndexed(nodes, key = { _, id -> id.toLong() }) { i, id ->
            val san = tree[id]?.mv?.san ?: return@itemsIndexed
            val ply = rootPly + i + 1
            val text = when {
                ply % 2 == 1 -> "${(ply + 1) / 2}. $san"
                i == 0 -> "${ply / 2}… $san"
                else -> san
            }
            val current = i == nodes.lastIndex
            Surface(
                shape = CircleShape,
                color = if (current) MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.surface,
            ) {
                Text(
                    text,
                    style = MaterialTheme.typography.labelLarge,
                    fontWeight = if (current) FontWeight.SemiBold else null,
                    modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
                )
            }
        }
    }
}

/** Anki's three counts, colored like the studied bar: New, Learning, To Review; the one asked underlined. */
@Composable
private fun StudyCounts(counts: Counts, highlight: QueueKind?) {
    val style = tabularDigits(MaterialTheme.typography.titleMedium)
    Row(
        Modifier.semantics(mergeDescendants = true) {
            contentDescription = "${counts.new} new, ${counts.learning} learning, ${counts.review} to review"
        },
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        CountText(counts.new, ThemeColor.new, highlight == QueueKind.NEW, style)
        CountText(counts.learning, ThemeColor.learning, highlight == QueueKind.LEARNING, style)
        CountText(counts.review, ThemeColor.learned, highlight == QueueKind.REVIEW, style)
    }
}

@Composable
private fun CountText(value: Long, meaning: ThemeColor, asked: Boolean, style: TextStyle) {
    Text(
        "$value",
        color = meaning.color,
        style = style,
        fontWeight = FontWeight.SemiBold,
        textDecoration = if (asked) TextDecoration.Underline else null,
    )
}

/** Anki's three counts one per row with what each means, where there is room (the panel). */
@Composable
private fun StudyCountsList(counts: Counts, highlight: QueueKind?) {
    Column {
        CountRow(counts.new, ThemeColor.new, highlight == QueueKind.NEW, "New", "Moves you haven't studied yet")
        CountRow(
            counts.learning, ThemeColor.learning, highlight == QueueKind.LEARNING,
            "Learning", "Moves you're learning, shown again within minutes",
        )
        CountRow(counts.review, ThemeColor.learned, highlight == QueueKind.REVIEW, "To Review", "Learned moves due today")
    }
}

@Composable
private fun CountRow(value: Long, meaning: ThemeColor, asked: Boolean, title: String, detail: String) {
    ListItem(
        headlineContent = { Text(title) },
        supportingContent = { Text(detail) },
        leadingContent = {
            CountText(value, meaning, asked, tabularDigits(MaterialTheme.typography.headlineSmall))
        },
        modifier = Modifier.semantics(mergeDescendants = true) {},
    )
}
