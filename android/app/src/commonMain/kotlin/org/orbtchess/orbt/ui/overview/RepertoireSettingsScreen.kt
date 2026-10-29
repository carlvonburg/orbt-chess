package org.orbtchess.orbt.ui.overview

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.storage.RepertoireDocument
import org.orbtchess.orbt.storage.RepertoireLibrary
import org.orbtchess.orbt.ui.components.Symbols
import org.orbtchess.orbt.ui.library.rememberPgnExport
import org.orbtchess.orbt.ui.theme.ThemeColor
import org.orbtchess.orbt.ui.theme.color

/**
 * A repertoire's settings (`RepertoireSettingsSheet` in LibraryView.swift and
 * `RepertoireSettingsForm.swift`): name, side, coverage database (tables download), coverage
 * target; its file, export and delete (the library row's menu on Apple, which wide windows here
 * reach from the overview). Full window, Material's full-screen dialog: close, then Save.
 *
 * @param onDeleted the repertoire was deleted: the shell goes back to the library.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RepertoireSettingsScreen(
    app: AppModel,
    document: RepertoireDocument,
    onBack: () -> Unit,
    onDeleted: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var draft by remember(document) { mutableStateOf(RepertoireSettingsDraft.of(document.sidecar)) }
    var name by remember(document) { mutableStateOf(document.name) }
    var error by remember { mutableStateOf<String?>(null) }
    var confirmDelete by remember { mutableStateOf(false) }
    var showWarnings by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val export = rememberPgnExport(app) { error = it }

    fun save() {
        scope.launch {
            val newName = name.trim()
            if (newName != document.name) {
                try {
                    app.documents.rename(document, newName)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    error = e.message ?: e.toString()
                    return@launch
                }
            }
            document.updateSettings(draft.color, draft.database, draft.targetGames)
            onBack()
        }
    }

    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                title = { Text("Repertoire Settings") },
                navigationIcon = {
                    IconButton(onClick = onBack) { Icon(Icons.Filled.Close, contentDescription = "Cancel") }
                },
                actions = {
                    TextButton(onClick = ::save, enabled = name.isNotBlank()) { Text("Save") }
                },
            )
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState())) {
            FormSection("Name") {
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = RepertoireLibrary.safeRepertoireName(it) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words),
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                )
            }
            RepertoireSettingsForm(app, draft) { draft = it }
            error?.let {
                Text(it, color = ThemeColor.failure.color, modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
            }
            HorizontalDivider()
            FormSection("File") {
                ListItem(
                    headlineContent = { Text("PGN") },
                    trailingContent = { Text(document.pgnFile.name, style = MaterialTheme.typography.bodyMedium) },
                )
                val warnings = document.loadWarnings
                if (warnings.isNotEmpty()) {
                    ListItem(
                        headlineContent = { Text("${warnings.size} moves could not be read") },
                        trailingContent = {
                            Icon(if (showWarnings) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore, contentDescription = null)
                        },
                        modifier = Modifier.clickable { showWarnings = !showWarnings },
                    )
                    if (showWarnings) {
                        for (warning in warnings) {
                            Text(warning, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(horizontal = 16.dp, vertical = 2.dp))
                        }
                    }
                }
                ListItem(
                    headlineContent = { Text("Export") },
                    leadingContent = { Icon(Symbols.share, contentDescription = null) },
                    modifier = Modifier.clickable { app.library.entry(document.entryId)?.let(export) },
                )
                ListItem(
                    headlineContent = { Text("Delete Repertoire", color = ThemeColor.failure.color) },
                    leadingContent = { Icon(Symbols.delete, contentDescription = null, tint = ThemeColor.failure.color) },
                    modifier = Modifier.clickable { confirmDelete = true },
                )
            }
        }
    }

    if (confirmDelete) {
        DeleteRepertoireDialog(
            name = document.name,
            onDismiss = { confirmDelete = false },
            onDelete = {
                confirmDelete = false
                val entry = app.library.entry(document.entryId) ?: return@DeleteRepertoireDialog
                scope.launch {
                    try {
                        app.documents.delete(entry)
                        onDeleted()
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        error = e.message ?: e.toString()
                    }
                }
            },
        )
    }
}

/** Asks before deleting a repertoire's files (the library's confirmation dialog). */
@Composable
fun DeleteRepertoireDialog(name: String, onDismiss: () -> Unit, onDelete: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Delete $name?") },
        text = { Text("Deletes the PGN and its training progress from this device.") },
        confirmButton = {
            TextButton(onClick = onDelete) { Text("Delete", color = ThemeColor.failure.color) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
