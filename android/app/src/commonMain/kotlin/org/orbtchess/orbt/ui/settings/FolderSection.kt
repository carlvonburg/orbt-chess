package org.orbtchess.orbt.ui.settings

import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import kotlinx.coroutines.launch
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.platform.FolderChooser
import java.io.File

/**
 * The repertoire folder (the desktop only): chosen with the system's folder chooser, so it can
 * be inside Dropbox or Google Drive for desktop, whose client keeps it the same on the user's
 * other devices. Switching shows the library of the new folder (`onSwitched`).
 */
@Composable
internal fun FolderSection(app: AppModel, chooser: FolderChooser, onSwitched: () -> Unit) {
    val scope = rememberCoroutineScope()
    var choosing by remember { mutableStateOf(false) }
    val current = app.library.folder
    fun switch(folder: File) {
        scope.launch {
            app.switchRepertoireFolder(folder)
            onSwitched()
        }
    }
    Section(
        "Folder",
        footer = "To have your repertoires on your other devices, choose a folder in Dropbox (Apps/ORBT Chess) " +
            "or Google Drive (ORBT Chess). Nothing is moved: the library shows the repertoires in the folder you choose.",
    ) {
        ValueRow("Repertoire folder", displayPath(current)) {
            if (choosing) return@ValueRow
            choosing = true
            scope.launch {
                try {
                    chooser.choose(current)?.let(::switch)
                } finally {
                    choosing = false
                }
            }
        }
        if (current.absoluteFile != chooser.default.absoluteFile) {
            ListItem(onClick = { switch(chooser.default) }) {
                Text("Use ${displayPath(chooser.default)}", color = MaterialTheme.colorScheme.primary)
            }
        }
    }
}

/** A path with the home folder as "~". */
private fun displayPath(folder: File): String {
    val home = System.getProperty("user.home")
    val path = folder.absolutePath
    return if (path == home || path.startsWith(home + File.separator)) "~" + path.removePrefix(home) else path
}
