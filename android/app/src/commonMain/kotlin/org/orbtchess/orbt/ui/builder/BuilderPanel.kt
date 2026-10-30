package org.orbtchess.orbt.ui.builder

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.ui.tour.TourGuide
import org.orbtchess.orbt.ui.tour.tourTarget
import org.orbtchess.orbt.core.CloudEval
import org.orbtchess.orbt.core.Epd
import org.orbtchess.orbt.core.ExplorerMove
import org.orbtchess.orbt.core.Node
import org.orbtchess.orbt.core.NodeCoverage
import org.orbtchess.orbt.core.PlayedMove
import org.orbtchess.orbt.core.QueueState
import org.orbtchess.orbt.core.ReplyInfo
import org.orbtchess.orbt.core.Status
import org.orbtchess.orbt.core.cloudEvalText
import org.orbtchess.orbt.explorer.CloudEvalClient
import org.orbtchess.orbt.storage.NodeId
import org.orbtchess.orbt.storage.ROOT_NODE
import org.orbtchess.orbt.ui.Destination
import org.orbtchess.orbt.ui.components.CoverageBar
import org.orbtchess.orbt.ui.components.Format
import org.orbtchess.orbt.ui.components.ScoreBar
import org.orbtchess.orbt.ui.components.StatusBadge
import org.orbtchess.orbt.ui.components.Symbols
import org.orbtchess.orbt.ui.components.SymbolLabel
import org.orbtchess.orbt.ui.components.tabularDigits
import org.orbtchess.orbt.ui.theme.ThemeColor
import org.orbtchess.orbt.ui.theme.color

// Build's panel (BuilderView.swift's panel rows): the header of the position, then the
// opponent's replies with coverage (gaps), or your moves and the explorer's candidates.

/** Horizontal inset of the panel's rows (`builderRow`). */
private val RowInset = 12.dp

/**
 * What the panel lists: your moves at a position where it's your turn, else the opponent's
 * replies. [savedAt] is the saved node whose moves are shown (the current one, where its lines
 * continue, or the node a draft transposes into); null for an unsaved draft position.
 */
private class PanelContent(
    val savedAt: Node?,
    val epd: Epd,
    val yourMove: Boolean,
    val replies: List<ReplyInfo>?,
    /** A candidate not saved yet, tapped: previews it from a saved position, extends a draft. */
    val select: (String) -> Unit,
)

private fun panelContent(model: BuilderModel): PanelContent? {
    val document = model.document
    val color = document.color
    if (model.hasDraft) {
        val target = model.draftTransposition?.let { model.tree[it] }
        return when {
            // The draft reached a position you have lines for: they are shown with their coverage.
            target != null -> PanelContent(
                target, target.epd, target.sideToMove == color,
                document.coverage[target.id]?.replies, model::preview,
            )
            model.isUserTurnOnBoard -> PanelContent(null, model.position.epd(), true, null) { model.play(it) }
            else -> PanelContent(null, model.position.epd(), false, model.draftReplies) { model.play(it) }
        }
    }
    val node = model.node ?: return null
    // At a transposition the panels show the moves stored for this position elsewhere.
    val shown = model.shownNode ?: node
    return PanelContent(shown, shown.epd, shown.sideToMove == color, document.coverage[shown.id]?.replies, model::preview)
}

/**
 * The panel as one list: [header] (the board and the move strip on a phone), the position's
 * header, then one row per move.
 */
@Composable
internal fun BuilderList(
    app: AppModel,
    model: BuilderModel,
    navigate: (Destination) -> Unit,
    modifier: Modifier = Modifier,
    contentPadding: PaddingValues = PaddingValues(),
    header: LazyListScope.() -> Unit = {},
) {
    val content = panelContent(model)
    val epd = content?.epd
    // Lichess's cloud eval of each move, for your candidates and the opponent's replies.
    val eval by produceState<CloudEval?>(null, epd) {
        value = null
        if (epd != null) value = CloudEvalClient.fetch(epd)
    }
    // Once a move is saved, the other candidates stay behind "Add Alternative Move".
    var showOthers by remember(epd) { mutableStateOf(false) }
    val loading = app.isLoadingStats
    val draft = model.hasDraft
    val node = model.node
    val stats = StatsNote(app, navigate)

    LazyColumn(modifier, contentPadding = contentPadding) {
        header()
        if (draft) {
            item("draftHeader") { DraftHeader(model) }
            model.draftTransposition?.let { target ->
                item("draftTransposition") { TranspositionNote(model, target, inDraft = true) }
            }
        } else if (node != null) {
            item("header") { NodeHeader(app, model, node) }
            model.continuation?.let { target ->
                item("transposition") { TranspositionNote(model, target, inDraft = false) }
            }
        }
        if (content == null) return@LazyColumn
        if (content.yourMove) {
            candidates(model, content, eval, loading, showOthers, { showOthers = true }, stats)
        } else {
            replies(model, content, eval, loading, stats)
        }
    }
}

/** Why there are no statistics, with what to do about it (`StatsUnavailableNote`). */
private class StatsNote(val app: AppModel, val navigate: (Destination) -> Unit)

// MARK: Header

/** Opening name, reach, building progress and the note of the current node (`NodeHeader`). */
@Composable
private fun NodeHeader(app: AppModel, model: BuilderModel, node: Node) {
    val document = model.document
    val info = document.coverage[node.id]
    // At a transposition, the moves shown below are stored at the target.
    val saved = model.tree.subtree(model.shownNode?.id ?: node.id).size - 1
    Column(
        Modifier.fillMaxWidth().padding(horizontal = RowInset).padding(top = 8.dp, bottom = 4.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        document.openingName(node.id)?.let { name ->
            Text(name, style = MaterialTheme.typography.titleSmall, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        val leech = node.sideToMove == document.color && document.studyCards[node.epd]?.leech == true
        val reach = info?.reach?.takeIf { node.id != ROOT_NODE }
        if (info?.status.hasBadge || reach != null || leech) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                StatusChip(info?.status)
                if (reach != null) {
                    Text(
                        Format.seenGames(reach),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Spacer(Modifier.weight(1f))
                if (leech) {
                    // Anki's "leech" tag: a move you keep forgetting.
                    StatusBadge(
                        "Leech",
                        Modifier.semantics { contentDescription = "Leech. You keep forgetting this move." },
                        meaning = ThemeColor.todo,
                    )
                }
            }
        }
        CoverageCheckStatus(app, model)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            val completion = info?.completion ?: 0.0
            Text("Built", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            CoverageBar(completion, Modifier.width(96.dp))
            Text(Format.percent(completion), style = tabularDigits(MaterialTheme.typography.labelSmall))
            Spacer(Modifier.weight(1f))
            val gaps = info?.gapCount ?: 0
            if (gaps > 0) {
                Text(
                    "$gaps ${if (gaps == 1L) "gap" else "gaps"}",
                    style = tabularDigits(MaterialTheme.typography.labelSmall),
                    color = ThemeColor.todo.color,
                )
                Text(" · ", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Text(
                "$saved ${if (saved == 1) "move" else "moves"}",
                style = tabularDigits(MaterialTheme.typography.labelSmall),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        if (node.note.isNotEmpty()) {
            Card(onClick = { model.sheet = BuilderSheet.Note }, modifier = Modifier.fillMaxWidth()) {
                Text(node.note, Modifier.padding(12.dp), style = MaterialTheme.typography.bodyMedium)
            }
        }
    }
}

private val Status?.hasBadge: Boolean
    get() = when (this) {
        Status.Gap, Status.Pending, Status.BelowTarget, Status.Alternative, Status.Unknown, is Status.Transposition -> true
        else -> false
    }

@Composable
private fun StatusChip(status: Status?) {
    when (status) {
        Status.Gap -> StatusBadge("Your move is missing", meaning = ThemeColor.todo)
        Status.Pending -> StatusBadge("Stats not loaded yet")
        Status.BelowTarget -> StatusBadge("Beyond your target")
        is Status.Transposition -> StatusBadge("Transposes", meaning = ThemeColor.built)
        Status.Alternative -> StatusBadge("Alternative line")
        Status.Unknown -> StatusBadge("Stats unavailable")
        else -> Unit
    }
}

/** While a draft is on the board, laid out like [NodeHeader]: opening name, then status and reach (`DraftPanel`). */
@Composable
private fun DraftHeader(model: BuilderModel) {
    val document = model.document
    val target = model.draftTransposition
    // Every reply is below the target: the line is deep enough to save.
    val reached = model.draftReachedTarget
    val haptics = LocalHapticFeedback.current
    var wasReached by remember { mutableStateOf(reached) }
    LaunchedEffect(reached) {
        if (reached && !wasReached) haptics.performHapticFeedback(HapticFeedbackType.Confirm)
        wasReached = reached
    }
    val name = document.stats(model.position.epd())?.opening?.name ?: document.openingName(model.current)
    Column(
        Modifier.fillMaxWidth().padding(horizontal = RowInset).padding(top = 8.dp, bottom = 4.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (name != null) {
            Text(name, style = MaterialTheme.typography.titleSmall, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            when {
                target != null -> StatusBadge("Transposed", meaning = ThemeColor.built)
                reached -> StatusBadge("Coverage target reached", meaning = ThemeColor.built)
                else -> StatusBadge("New line, not saved")
            }
            model.reachOnBoard?.let { reach ->
                Text(
                    Format.seenGames(reach),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

/** The current position's lines are stored under another move order (`TranspositionNote`). */
@Composable
private fun TranspositionNote(model: BuilderModel, target: NodeId, inDraft: Boolean) {
    val tree = model.tree
    val content: @Composable ColumnScope.() -> Unit = {
        Row(Modifier.padding(12.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Icon(BuilderSymbols.transposition, contentDescription = null, tint = ThemeColor.built.color)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(if (inDraft) "Transposed into" else "Transposes. Lines continue after", style = MaterialTheme.typography.bodyMedium)
                Text(
                    Format.moveList(tree.moves(target), startPly = tree.root.ply.toInt()),
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                // Not a link: going there would drop the draft. Saving it covers this position.
                if (inDraft) {
                    Text(
                        "Save to cover this move order.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            if (!inDraft) {
                Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
    val modifier = Modifier.fillMaxWidth().padding(horizontal = RowInset, vertical = 6.dp)
    if (inDraft) {
        Card(modifier, content = content)
    } else {
        Card(onClick = { model.go(target) }, modifier = modifier, content = content)
    }
}

/** Shows the background coverage check while it runs (`CoverageCheckStatus`). */
@Composable
private fun CoverageCheckStatus(app: AppModel, model: BuilderModel) {
    val unchecked = model.document.uncheckedPositions
    if (unchecked <= 0) return
    val style = MaterialTheme.typography.bodySmall
    val color = MaterialTheme.colorScheme.onSurfaceVariant
    when (val state = app.explorer.state) {
        is QueueState.RateLimited -> {
            val minutes = ((state.until - System.currentTimeMillis()) / 60_000 + 1).coerceAtLeast(1)
            SymbolLabel(
                "Lichess asked to slow down · resuming in $minutes min",
                BuilderSymbols.rateLimited,
                style = style.copy(color = color),
            )
        }
        QueueState.Offline -> SymbolLabel("Offline · ${Format.positions(unchecked)} not checked yet", BuilderSymbols.offline, style = style.copy(color = color))
        QueueState.NeedsLogin -> SymbolLabel("Sign in to Lichess to check ${Format.positions(unchecked)}", Symbols.signIn, style = style.copy(color = color))
        else -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            CircularProgressIndicator(Modifier.size(12.dp), strokeWidth = 1.5.dp)
            Text("Checking coverage · $unchecked waiting", style = style, color = color)
        }
    }
}

// MARK: Replies

/**
 * Opponent to move: the replies from the explorer with coverage, plus moves in the repertoire
 * that the explorer does not list (`RepliesPanel`).
 */
private fun LazyListScope.replies(
    model: BuilderModel,
    content: PanelContent,
    eval: CloudEval?,
    loading: Boolean,
    stats: StatsNote,
) {
    val saved = content.savedAt
    item("repliesHeading") {
        Row(
            // The tour's replies step shows the heading row with the replies.
            Modifier.fillMaxWidth().tourTarget(TourGuide.Target.Replies, part = -1)
                .padding(horizontal = RowInset).padding(top = 12.dp, bottom = 4.dp),
            verticalAlignment = Alignment.Bottom,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text("Replies", Modifier.weight(1f), style = MaterialTheme.typography.titleMedium)
            ColumnHeading("Seen", SeenWidth)
            ColumnHeading("Covered", CoveredWidth)
            ColumnHeading("Games", GamesWidth)
        }
    }
    val replies = content.replies
    if (!replies.isNullOrEmpty()) {
        // Replies in the repertoire, needed or excluded first, then the ones not needed; each
        // group by how often it is played.
        val matters = { r: ReplyInfo -> r.child != null || r.transposesTo != null || r.required || r.excluded }
        val ordered = replies.filter(matters).sortedByDescending { it.share } +
            replies.filterNot(matters).sortedByDescending { it.share }
        for ((index, reply) in ordered.withIndex()) {
            item("reply-${reply.uci}") {
                // The first few, so the highlight ends above the bottom bar.
                Box(Modifier.tourTarget(TourGuide.Target.Replies, part = index.takeIf { it < 4 })) {
                    ReplyRow(model, reply, saved?.id, eval?.let { cloudEvalText(it, reply.uci) })
                }
            }
        }
        return
    }
    for (child in saved?.children.orEmpty()) {
        val move = model.tree[child]?.mv ?: continue
        item("replyChild-$child") {
            MoveRow(model, onClick = { model.go(child) }, menu = savedMoveMenu(child, promote = null)) {
                Text(move.san, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.SemiBold)
            }
        }
    }
    when {
        model.document.stats(content.epd) != null -> item("noGames") { NoGamesNote() }
        // Stand-ins until the stats come in; your saved replies are already above.
        loading -> repeat(4) { item("replyPlaceholder-$it") { ReplyPlaceholderRow() } }
        else -> item("statsUnavailable") { StatsUnavailableNote(stats) }
    }
}

private val SeenWidth = 74.dp
private val CoveredWidth = 76.dp
private val GamesWidth = 40.dp
private val SanWidth = 48.dp
private val EvalWidth = 40.dp

@Composable
private fun ColumnHeading(text: String, width: Dp) {
    Text(
        text,
        Modifier.width(width),
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        textAlign = TextAlign.End,
    )
}

/**
 * One reply (`ReplyRow`): tapping opens it; one not in the repertoire is played on the board so
 * you can add your answer, and is saved with it. Long press: delete a saved reply, or exclude an
 * opponent move you have no line for from coverage (or include it again).
 *
 * @param node the saved position the reply is at; null in a draft.
 */
@Composable
private fun ReplyRow(model: BuilderModel, reply: ReplyInfo, node: NodeId?, eval: String?) {
    val transposes = reply.child == null && (reply.transposesTo != null || model.transposition(reply.uci) != null)
    val inRepertoire = reply.child != null || transposes
    val menu = when {
        reply.child != null -> savedMoveMenu(reply.child!!, promote = null)
        node != null -> excludeMenu(model, reply, node)
        else -> null
    }
    MoveRow(
        model,
        onClick = {
            val child = reply.child
            when {
                child != null -> model.go(child)
                node != null -> model.preview(reply.uci)
                else -> model.play(reply.uci)
            }
        },
        menu = menu,
    ) {
        Row(Modifier.widthIn(min = SanWidth), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
                reply.san,
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = FontWeight.SemiBold,
                color = if (reply.required || inRepertoire) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (transposes) TranspositionIcon()
        }
        EvalText(eval)
        Spacer(Modifier.weight(1f))
        Text(
            Format.seenEvery(reply.reach),
            Modifier.width(SeenWidth),
            style = tabularDigits(MaterialTheme.typography.bodySmall),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.End,
        )
        Box(Modifier.width(CoveredWidth), contentAlignment = Alignment.CenterEnd) {
            when {
                inRepertoire && reply.required -> CoverageBar(reply.completion, height = 4.dp)
                reply.excluded -> FaintLabel("Excluded")
                !reply.required -> FaintLabel("Not needed")
                else -> CoverageBar(0.0, height = 4.dp)
            }
        }
        Text(
            if (reply.games > 0) Format.games(reply.games) else "",
            Modifier.width(GamesWidth),
            style = tabularDigits(MaterialTheme.typography.labelSmall),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.End,
            maxLines = 1,
        )
    }
}

@Composable
private fun FaintLabel(text: String) {
    Text(text, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.outline, maxLines = 1)
}

/** Lichess's cloud eval after a move, or nothing while unknown. */
@Composable
private fun EvalText(eval: String?) {
    Text(
        eval.orEmpty(),
        Modifier.width(EvalWidth),
        style = tabularDigits(MaterialTheme.typography.bodySmall),
        fontWeight = FontWeight.SemiBold,
        textAlign = TextAlign.Center,
        maxLines = 1,
    )
}

/** Stands in for an explorer reply while the stats load, laid out like [ReplyRow]. */
@Composable
private fun ReplyPlaceholderRow() {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = RowInset, vertical = 12.dp).clearAndSetSemantics {},
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        PlaceholderBox(36.dp, 16.dp)
        Spacer(Modifier.weight(1f))
        PlaceholderBox(56.dp, 12.dp)
        PlaceholderBox(CoveredWidth, 8.dp)
        PlaceholderBox(32.dp, 12.dp)
    }
}

// MARK: Candidates

/**
 * Your move (`CandidatesSection`): explorer moves with cloud eval, results, games and share of
 * games. Moves saved at [PanelContent.savedAt] come first (with their note and Main/Alternative
 * tag), then the other explorer moves; each group sorted by how often it is played. Once a move
 * is saved the heading reads "Your Moves" and the other moves stay behind "Add Alternative
 * Move". Tapping a row plays the move on the board (or opens a saved move).
 */
private fun LazyListScope.candidates(
    model: BuilderModel,
    content: PanelContent,
    eval: CloudEval?,
    loadingStats: Boolean,
    showOthers: Boolean,
    onShowOthers: () -> Unit,
    statsNote: StatsNote,
) {
    val tree = model.tree
    val stats = model.document.stats(content.epd)
    val explorer = stats?.moves.orEmpty()
    val total = stats?.let { it.white + it.draws + it.black } ?: 0L
    val parent = content.savedAt
    val savedIds = parent?.children.orEmpty()
    val saved = savedIds.mapNotNull { id -> tree[id]?.mv?.let { SavedMove(id, savedIds.indexOf(id), savedIds.size, it, tree[id]?.note.orEmpty()) } }
    val savedRows = saved.map { move -> move to explorer.firstOrNull { it.uci == move.move.uci } }
        .sortedByDescending { it.second?.games ?: -1 }
    val otherRows = explorer.filter { e -> saved.none { it.move.uci == e.uci } }.take(maxOf(0, 12 - savedRows.size))
    val collapsed = saved.isNotEmpty() && !showOthers
    val loading = stats == null && loadingStats
    val title = "Candidates"

    item("candidatesHeading") {
        // The tour's answer step shows the heading with the candidates under it.
        Box(Modifier.fillMaxWidth().tourTarget(TourGuide.Target.Candidates, part = -1)) {
            Heading(if (saved.isEmpty()) title else "Your Moves")
        }
    }
    for ((move, explorerMove) in savedRows) {
        item("saved-${move.move.uci}") {
            val promote = if (move.index > 0) ({ model.document.promote(move.id) }) else null
            CandidateRow(
                model, move.move.san, move.move.uci, explorerMove, total, eval, loading, move,
                onClick = { model.go(move.id) },
                menu = savedMoveMenu(move.id, promote),
            )
        }
    }
    if (collapsed) {
        item("addAlternative") {
            TextButton(onClick = onShowOthers, modifier = Modifier.padding(horizontal = 4.dp, vertical = 4.dp)) {
                Icon(Symbols.add, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text("Add Alternative Move")
            }
        }
        return
    }
    if (saved.isNotEmpty()) item("candidatesHeading2") { Heading(title) }
    for ((index, move) in otherRows.withIndex()) {
        item("candidate-${move.uci}") {
            // The tour's answer step points at the candidates: the first few, so the highlight
            // ends above the bottom bar.
            Box(Modifier.tourTarget(TourGuide.Target.Candidates, part = index.takeIf { it < 4 })) {
                CandidateRow(model, move.san, move.uci, move, total, eval, loading = false, saved = null, onClick = { content.select(move.uci) }, menu = null)
            }
        }
    }
    when {
        // Stand-ins until the stats come in; your saved moves are already above.
        loading -> repeat(4) { item("candidatePlaceholder-$it") { CandidatePlaceholderRow() } }
        stats == null -> item("statsUnavailable") { StatsUnavailableNote(statsNote) }
        explorer.isEmpty() -> item("noGames") { NoGamesNote() }
    }
}

/** A candidate that is already in the repertoire (`SavedMove`). */
private class SavedMove(val id: NodeId, val index: Int, val siblings: Int, val move: PlayedMove, val note: String) {
    val tag: String?
        get() = when {
            index > 0 -> "Alternative · not trained"
            siblings > 1 -> "Main"
            else -> null
        }
}

private val ExplorerMove.games: Long get() = white + draws + black

@Composable
private fun CandidateRow(
    model: BuilderModel,
    san: String,
    uci: String,
    move: ExplorerMove?,
    total: Long,
    eval: CloudEval?,
    loading: Boolean,
    saved: SavedMove?,
    onClick: () -> Unit,
    menu: MoveMenu?,
) {
    // Playing it reaches a position whose lines you already have elsewhere.
    val transposes = model.transposition(uci) != null
    val background = if (saved != null) Modifier.background(ThemeColor.built.opacity(0.08f).color) else Modifier
    MoveRow(model, onClick = onClick, menu = menu, modifier = background, vertical = 10.dp, below = {
        if (saved != null && (saved.tag != null || saved.note.isNotEmpty())) {
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                saved.tag?.let {
                    Text(it, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                if (saved.note.isNotEmpty()) {
                    Text(
                        saved.note,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
    }) {
        Row(Modifier.widthIn(min = SanWidth), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(san, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.SemiBold)
            if (transposes) TranspositionIcon()
        }
        EvalText(eval?.let { cloudEvalText(it, uci) })
        when {
            move != null -> {
                ScoreBar(move.white, move.draws, move.black, Modifier.weight(1f))
                // Games and share of games side by side, as in the Lichess explorer.
                val share = Format.percent(if (total > 0) move.games.toDouble() / total else 0.0)
                Text(
                    "${Format.games(move.games)} · $share",
                    Modifier.width(76.dp),
                    style = tabularDigits(MaterialTheme.typography.labelSmall),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.End,
                    maxLines = 1,
                )
            }
            loading -> StatsPlaceholder()
            else -> Spacer(Modifier.weight(1f))
        }
    }
}

/** The score bar and game counts of a candidate, greyed out while its stats load. */
@Composable
private fun RowScope.StatsPlaceholder() {
    PlaceholderBox(height = 18.dp, modifier = Modifier.weight(1f))
    Box(Modifier.width(76.dp), contentAlignment = Alignment.CenterEnd) { PlaceholderBox(56.dp, 12.dp) }
}

/** Stands in for an explorer candidate while the stats load. */
@Composable
private fun CandidatePlaceholderRow() {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = RowInset, vertical = 10.dp).clearAndSetSemantics {},
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Box(Modifier.width(SanWidth)) { PlaceholderBox(32.dp, 16.dp) }
        Spacer(Modifier.width(EvalWidth))
        StatsPlaceholder()
    }
}

// MARK: Rows

/** What a long-press menu's items can do: close the menu, or ask to confirm deleting a move. */
private class MenuActions(val close: () -> Unit, val delete: (NodeId) -> Unit)

/** A long-press menu's items. */
private typealias MoveMenu = @Composable ColumnScope.(MenuActions) -> Unit

/** One move of the panel: tap to open or play it, long press for its menu. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun MoveRow(
    model: BuilderModel,
    onClick: () -> Unit,
    menu: MoveMenu?,
    modifier: Modifier = Modifier,
    vertical: Dp = 12.dp,
    below: @Composable ColumnScope.() -> Unit = {},
    content: @Composable RowScope.() -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf<NodeId?>(null) }
    Box(modifier) {
        Column(
            Modifier.fillMaxWidth()
                .combinedClickable(onClick = onClick, onLongClick = menu?.let { { open = true } })
                .padding(horizontal = RowInset, vertical = vertical),
            verticalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp), content = content)
            below()
        }
        if (menu != null) {
            DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                menu(MenuActions(close = { open = false }, delete = { open = false; deleting = it }))
            }
        }
    }
    deleting?.let { id -> DeleteDialog(model, id, onDismiss = { deleting = null }) }
}

/**
 * Long press on a saved move (`DeleteMove`): Make Main Move for an alternative, and Delete,
 * confirmed in a dialog.
 */
private fun savedMoveMenu(id: NodeId, promote: (() -> Unit)?): MoveMenu = { actions ->
    if (promote != null) {
        DropdownMenuItem(
            text = { Text("Make Main Move") },
            onClick = { actions.close(); promote() },
            leadingIcon = { Icon(BuilderSymbols.makeMain, contentDescription = null) },
        )
    }
    DropdownMenuItem(
        text = { Text("Delete") },
        onClick = { actions.delete(id) },
        leadingIcon = { Icon(Symbols.delete, contentDescription = null) },
    )
}

/** Confirms deleting a saved move and the lines that follow it. */
@Composable
private fun DeleteDialog(model: BuilderModel, id: NodeId, onDismiss: () -> Unit) {
    val tree = model.tree
    val node = tree[id]
    val message = when {
        node?.children.isNullOrEmpty() -> "You can undo this."
        else -> tree.leaves(id).size.let { lines ->
            if (lines == 1) "This also deletes the line that follows it. You can undo this."
            else "This also deletes the $lines lines that follow it. You can undo this."
        }
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(node?.mv?.let { "Delete ${it.san}?" } ?: "Delete move?") },
        text = { Text(message) },
        confirmButton = {
            TextButton(onClick = { onDismiss(); model.delete(id) }) { Text("Delete", color = ThemeColor.failure.color) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

/** Long press on an opponent move you have no line for (`ExcludeMove`): exclude it from coverage, or include it again. */
private fun excludeMenu(model: BuilderModel, reply: ReplyInfo, node: NodeId): MoveMenu = { actions ->
    DropdownMenuItem(
        text = { Text("${if (reply.excluded) "Include" else "Exclude"} ${reply.san}") },
        onClick = {
            actions.close()
            model.document.setExcluded(reply.uci, node, !reply.excluded)
        },
        leadingIcon = { Icon(if (reply.excluded) BuilderSymbols.include else BuilderSymbols.exclude, contentDescription = null) },
    )
}

@Composable
private fun Heading(text: String) {
    Text(
        text,
        Modifier.fillMaxWidth().padding(horizontal = RowInset).padding(top = 12.dp, bottom = 4.dp),
        style = MaterialTheme.typography.titleMedium,
    )
}

/** Marks a move that leads into a position whose lines you already have. */
@Composable
private fun TranspositionIcon() {
    Icon(BuilderSymbols.transposition, contentDescription = "Transposes", tint = ThemeColor.built.color, modifier = Modifier.size(16.dp))
}

@Composable
private fun PlaceholderBox(width: Dp = Dp.Unspecified, height: Dp, modifier: Modifier = Modifier) {
    val sized = if (width == Dp.Unspecified) modifier else modifier.width(width)
    Box(sized.height(height).clip(RoundedCornerShape(4.dp)).background(MaterialTheme.colorScheme.surfaceContainerHighest))
}

@Composable
private fun NoGamesNote() {
    Text(
        "No games in this position.",
        Modifier.padding(horizontal = RowInset, vertical = 8.dp),
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

/** Why there are no statistics (`StatsUnavailableNote`); signing in is in Settings. */
@Composable
private fun StatsUnavailableNote(note: StatsNote) {
    val app = note.app
    val modifier = Modifier.padding(horizontal = RowInset, vertical = 8.dp)
    val style = MaterialTheme.typography.bodySmall.copy(color = MaterialTheme.colorScheme.onSurfaceVariant)
    @Composable
    fun signIn() {
        Column(Modifier.padding(horizontal = 4.dp)) {
            TextButton(onClick = { note.navigate(Destination.Settings) }) {
                Icon(Symbols.signIn, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text("Sign in with Lichess")
            }
            app.auth.lastError?.let {
                Text(it, Modifier.padding(horizontal = 8.dp), style = MaterialTheme.typography.bodySmall, color = ThemeColor.failure.color)
            }
        }
    }
    when (app.explorer.state) {
        QueueState.NeedsLogin -> signIn()
        QueueState.Offline -> SymbolLabel("Offline. Statistics will load when you're back online.", BuilderSymbols.offline, modifier, style = style)
        is QueueState.RateLimited -> SymbolLabel("Lichess asked us to slow down. Resuming in a minute.", BuilderSymbols.rateLimited, modifier, style = style)
        else -> if (app.auth.isSignedIn) {
            Row(modifier, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                Text("Loading statistics…", style = style)
            }
        } else {
            signIn()
        }
    }
}

/**
 * Stats for the position on screen are on their way: signed in, and not paused by Lichess or
 * offline.
 */
internal val AppModel.isLoadingStats: Boolean
    get() {
        if (!auth.isSignedIn) return false
        return when (explorer.state) {
            QueueState.NeedsLogin, QueueState.Offline, is QueueState.RateLimited -> false
            else -> true
        }
    }
