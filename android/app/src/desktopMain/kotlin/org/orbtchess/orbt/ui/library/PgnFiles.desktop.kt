package org.orbtchess.orbt.ui.library

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.storage.RepertoireEntry
import org.orbtchess.orbt.storage.RepertoireLibrary
import org.orbtchess.orbt.storage.exportPgn
import org.orbtchess.orbt.storage.readImport
import java.awt.FileDialog
import java.awt.Frame
import java.io.File

@Composable
internal actual fun rememberPgnImport(
    onPicked: (RepertoireLibrary.ImportedFile) -> Unit,
    onError: (String) -> Unit,
): () -> Unit {
    val scope = rememberCoroutineScope()
    val picked by rememberUpdatedState(onPicked)
    val failed by rememberUpdatedState(onError)
    return {
        val dialog = FileDialog(null as Frame?, "Import PGN", FileDialog.LOAD).apply {
            setFilenameFilter { _, name -> name.endsWith(".pgn", ignoreCase = true) || name.endsWith(".txt", ignoreCase = true) }
            isVisible = true
        }
        val file = dialog.files.firstOrNull()
        if (file != null) {
            scope.launch {
                try {
                    picked(readImport(file))
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    failed(e.message ?: e.toString())
                }
            }
        }
    }
}

@Composable
internal actual fun rememberPgnExport(app: AppModel, onError: (String) -> Unit): (RepertoireEntry) -> Unit {
    val scope = rememberCoroutineScope()
    val failed by rememberUpdatedState(onError)
    return { entry ->
        val dialog = FileDialog(null as Frame?, "Export", FileDialog.SAVE).apply {
            file = "${entry.name}.pgn"
            isVisible = true
        }
        val name = dialog.file
        if (name != null) {
            val destination = File(dialog.directory, if (name.endsWith(".pgn", ignoreCase = true)) name else "$name.pgn")
            scope.launch {
                try {
                    exportPgn(app.documents, entry, destination)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    failed(e.message ?: e.toString())
                }
            }
        }
    }
}

@Composable
internal actual fun RefreshOnReturn(app: AppModel) {
    val focused = androidx.compose.ui.platform.LocalWindowInfo.current.isWindowFocused
    var wasFocused by remember { mutableStateOf(focused) }
    androidx.compose.runtime.LaunchedEffect(focused) {
        // Files added by hand while another window was in front.
        if (focused && !wasFocused) app.resume()
        wasFocused = focused
    }
}
