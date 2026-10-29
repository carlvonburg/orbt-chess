package org.orbtchess.orbt.ui.library

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.storage.RepertoireEntry
import org.orbtchess.orbt.storage.RepertoireLibrary
import org.orbtchess.orbt.storage.exportPgn
import org.orbtchess.orbt.storage.readImport

/** What a PGN may be typed as: providers rarely know the chess type, so plain text and untyped files too. */
private val pgnTypes = arrayOf("application/x-chess-pgn", "application/vnd.chess-pgn", "text/plain", "application/octet-stream")

@Composable
internal actual fun rememberPgnImport(
    onPicked: (RepertoireLibrary.ImportedFile) -> Unit,
    onError: (String) -> Unit,
): () -> Unit {
    val resolver = LocalContext.current.contentResolver
    val scope = rememberCoroutineScope()
    val picked by rememberUpdatedState(onPicked)
    val failed by rememberUpdatedState(onError)
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            try {
                picked(readImport(resolver, uri))
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                failed(e.message ?: e.toString())
            }
        }
    }
    return { launcher.launch(pgnTypes) }
}

@Composable
internal actual fun rememberPgnExport(app: AppModel, onError: (String) -> Unit): (RepertoireEntry) -> Unit {
    val resolver = LocalContext.current.contentResolver
    val scope = rememberCoroutineScope()
    val failed by rememberUpdatedState(onError)
    var pending by remember { mutableStateOf<RepertoireEntry?>(null) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/x-chess-pgn")) { uri ->
        val entry = pending
        pending = null
        if (uri == null || entry == null) return@rememberLauncherForActivityResult
        scope.launch {
            try {
                exportPgn(app.documents, entry, resolver, uri)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                failed(e.message ?: e.toString())
            }
        }
    }
    return { entry ->
        pending = entry
        launcher.launch("${entry.name}.pgn")
    }
}

/** `MainActivity.onResume` calls `AppModel.resume()`. */
@Composable
internal actual fun RefreshOnReturn(app: AppModel) = Unit
