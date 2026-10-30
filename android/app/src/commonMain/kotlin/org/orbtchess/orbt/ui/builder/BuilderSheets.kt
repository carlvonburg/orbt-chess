package org.orbtchess.orbt.ui.builder

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.input.clearText
import androidx.compose.foundation.text.input.rememberTextFieldState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SearchBar
import androidx.compose.material3.SearchBarDefaults
import androidx.compose.material3.SheetValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberBottomSheetState
import androidx.compose.material3.rememberSearchBarState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import org.orbtchess.orbt.core.CoverageGap
import org.orbtchess.orbt.core.GapKind
import org.orbtchess.orbt.core.OutlineItem
import org.orbtchess.orbt.storage.NodeId
import org.orbtchess.orbt.storage.ROOT_NODE
import org.orbtchess.orbt.ui.components.CoverageBar
import org.orbtchess.orbt.ui.components.EmptyState
import org.orbtchess.orbt.ui.components.Format
import org.orbtchess.orbt.ui.components.Symbols
import org.orbtchess.orbt.ui.components.tabularDigits
import org.orbtchess.orbt.ui.theme.ThemeColor
import org.orbtchess.orbt.ui.theme.color

// Build's sheets (BuilderSheets.swift): the outline, the gap list, the note editor. Material's
// modal bottom sheet in place of SwiftUI's sheets; Move Info is the shell's Card Info sheet.

/** Shows [BuilderModel.sheet]. */
@Composable
internal fun BuilderSheets(model: BuilderModel, onStudyBranch: (NodeId) -> Unit) {
    val dismiss = { model.sheet = null }
    when (model.sheet) {
        BuilderSheet.Outline -> OutlineSheet(model, onStudyBranch, dismiss)
        BuilderSheet.Gaps -> GapsSheet(model, dismiss)
        BuilderSheet.Note -> NoteSheet(model, model.current, dismiss)
        null -> Unit
    }
}

/** A sheet's title row, with its actions at the end. */
@Composable
private fun SheetTitle(title: String, actions: @Composable () -> Unit = {}) {
    Row(
        Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, Modifier.weight(1f), style = MaterialTheme.typography.titleLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
        actions()
    }
}

// MARK: Outline

/**
 * The repertoire as a collapsible tree; chains without branching are one row (`OutlineSheet`).
 * Search finds a move. Long press: Train This Branch, Make Main Line, Delete From Here.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun OutlineSheet(model: BuilderModel, onStudyBranch: (NodeId) -> Unit, dismiss: () -> Unit) {
    val document = model.document
    val searchField = rememberTextFieldState()
    val search = searchField.text.toString()
    // Rows whose children are shown; children are read from the core only when shown.
    val expanded = remember { mutableStateListOf<NodeId>() }
    val open = { id: NodeId ->
        model.go(id)
        dismiss()
    }
    ModalBottomSheet(onDismissRequest = dismiss, sheetState = rememberBottomSheetState(SheetValue.Hidden, enabledValues = setOf(SheetValue.Hidden, SheetValue.Expanded))) {
        SheetTitle("Outline")
        // Material's search bar, collapsed: the results are the list below it, not a view of its own.
        val searchBar = rememberSearchBarState()
        SearchBar(
            state = searchBar,
            inputField = {
                SearchBarDefaults.InputField(
                    textFieldState = searchField,
                    searchBarState = searchBar,
                    onSearch = {},
                    placeholder = { Text("Find a move, e.g. Nf3") },
                    leadingIcon = { Icon(Icons.Outlined.Search, contentDescription = null) },
                    trailingIcon = {
                        if (search.isNotEmpty()) {
                            IconButton(onClick = { searchField.clearText() }) { Icon(Icons.Filled.Clear, contentDescription = "Clear") }
                        }
                    },
                )
            },
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        )
        Spacer(Modifier.size(8.dp))
        if (search.isNotEmpty()) {
            val matches = remember(search, document.revision) { document.core.search(search, 100u) }
            LazyColumn {
                items(matches, key = { it.toLong() }) { id ->
                    ListItem(
                        onClick = { open(id) },
                    ) { Text(model.tree.lineText(id), maxLines = 2, overflow = TextOverflow.Ellipsis) }
                }
            }
        } else {
            document.revision
            val rows = buildList {
                fun add(id: NodeId, depth: Int) {
                    for (item in document.core.outlineChildren(id)) {
                        add(item to depth)
                        if (item.hasChildren && item.id in expanded) add(item.id, depth + 1)
                    }
                }
                add(ROOT_NODE, 0)
            }
            LazyColumn {
                items(rows, key = { it.first.id.toLong() }) { (item, depth) ->
                    OutlineRow(
                        model, item, depth,
                        expanded = item.id in expanded,
                        onToggle = { if (item.id in expanded) expanded.remove(item.id) else expanded.add(item.id) },
                        onOpen = { open(item.id) },
                        onStudyBranch = {
                            dismiss()
                            onStudyBranch(item.first)
                        },
                    )
                }
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun OutlineRow(
    model: BuilderModel,
    item: OutlineItem,
    depth: Int,
    expanded: Boolean,
    onToggle: () -> Unit,
    onOpen: () -> Unit,
    onStudyBranch: () -> Unit,
) {
    val document = model.document
    val coverage = document.coverage[item.id]
    val gaps = coverage?.gapCount ?: 0
    var menu by remember { mutableStateOf(false) }
    Box {
        Row(
            Modifier.fillMaxWidth()
                .combinedClickable(onClick = onOpen, onLongClick = { menu = true })
                .padding(start = 8.dp + 20.dp * depth, end = 16.dp, top = 4.dp, bottom = 4.dp)
                .heightIn(min = 48.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (item.hasChildren) {
                IconButton(onClick = onToggle) {
                    Icon(
                        if (expanded) Icons.Filled.ExpandMore else Icons.AutoMirrored.Filled.KeyboardArrowRight,
                        contentDescription = if (expanded) "Collapse" else "Expand",
                    )
                }
            } else {
                Spacer(Modifier.width(48.dp))
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    item.text,
                    style = tabularDigits(MaterialTheme.typography.bodyMedium),
                    fontWeight = if (item.id == model.current) FontWeight.Bold else FontWeight.Normal,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    CoverageBar(coverage?.completion ?: 0.0, Modifier.width(60.dp))
                    if (gaps > 0) Text("$gaps gaps", style = MaterialTheme.typography.labelSmall, color = ThemeColor.todo.color)
                }
            }
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(
                text = { Text("Train This Branch") },
                onClick = { menu = false; onStudyBranch() },
                leadingIcon = { Icon(Symbols.study, contentDescription = null) },
            )
            if (item.first != ROOT_NODE) {
                DropdownMenuItem(
                    text = { Text("Make Main Line") },
                    onClick = { menu = false; document.promote(item.first) },
                    leadingIcon = { Icon(BuilderSymbols.makeMain, contentDescription = null) },
                )
                DropdownMenuItem(
                    text = { Text("Delete From Here") },
                    onClick = { menu = false; model.delete(item.first) },
                    leadingIcon = { Icon(Symbols.delete, contentDescription = null) },
                )
            }
        }
    }
}

// MARK: Gaps

/** Every gap, biggest first (`GapsSheet`); tap to go there, long press to exclude a reply. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun GapsSheet(model: BuilderModel, dismiss: () -> Unit) {
    val document = model.document
    val gaps = document.coverage.gaps()
    ModalBottomSheet(onDismissRequest = dismiss) {
        SheetTitle("${gaps.size} Gaps")
        if (gaps.isEmpty()) {
            val loading = (document.coverage.root?.pendingCount ?: 0) > 0
            Box(Modifier.heightIn(max = 360.dp)) {
                EmptyState(
                    if (loading) "Still loading statistics" else "No gaps",
                    BuilderSymbols.noGaps,
                    description = "Every opponent move seen at least once in ${document.sidecar.targetGames} games has an answer.",
                )
            }
        } else {
            LazyColumn {
                items(gaps.take(200), key = { "${it.node}-${(it.kind as? GapKind.MissingReply)?.uci}" }) { gap ->
                    GapRow(model, gap, onOpen = {
                        model.go(gap)
                        dismiss()
                    })
                }
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun GapRow(model: BuilderModel, gap: CoverageGap, onOpen: () -> Unit) {
    val reply = gap.kind as? GapKind.MissingReply
    var menu by remember { mutableStateOf(false) }
    Box {
        ListItem(
            onClick = onOpen,
            onLongClick = reply?.let { { menu = true } },
            supportingContent = { Text(Format.seenGames(gap.mass), color = ThemeColor.todo.color) },
        ) { Text(model.document.core.gapText(gap), maxLines = 2, overflow = TextOverflow.Ellipsis) }
        if (reply != null) {
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                DropdownMenuItem(
                    text = { Text("Exclude ${reply.san}") },
                    onClick = {
                        menu = false
                        model.document.setExcluded(reply.uci, gap.node, true)
                    },
                    leadingIcon = { Icon(BuilderSymbols.exclude, contentDescription = null) },
                )
            }
        }
    }
}

// MARK: Note

/** Edits the note of [node] (`NoteSheet`). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun NoteSheet(model: BuilderModel, node: NodeId, dismiss: () -> Unit) {
    val document = model.document
    var text by remember(node) { mutableStateOf(document.tree[node]?.note.orEmpty()) }
    // The last move or two: "4. Bb5 a6".
    val title = document.tree.lineText(node).split(" ").takeLast(2).joinToString(" ").ifEmpty { "Note" }
    ModalBottomSheet(onDismissRequest = dismiss) {
        SheetTitle(title) {
            TextButton(onClick = dismiss) { Text("Cancel") }
            Button(onClick = {
                document.setNote(text, node)
                dismiss()
            }) { Text("Save") }
        }
        OutlinedTextField(
            value = text,
            onValueChange = { text = it },
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(bottom = 16.dp),
            placeholder = { Text("Note") },
            minLines = 6,
        )
    }
}
