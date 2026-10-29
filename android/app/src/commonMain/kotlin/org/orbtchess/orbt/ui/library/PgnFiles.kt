package org.orbtchess.orbt.ui.library

import androidx.compose.runtime.Composable
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.storage.RepertoireEntry
import org.orbtchess.orbt.storage.RepertoireLibrary

// Picking a PGN to import and a place to export one (SwiftUI's `fileImporter` and `ShareLink`):
// the system's document picker on Android, the file dialog on the desktop.

/**
 * Returns an action that asks for a PGN file; [onPicked] gets its bytes and a name for it (the
 * setup flow then adds it), [onError] why it could not be read. Nothing happens when cancelled.
 */
@Composable
internal expect fun rememberPgnImport(
    onPicked: (RepertoireLibrary.ImportedFile) -> Unit,
    onError: (String) -> Unit,
): () -> Unit

/** Returns an action that writes a repertoire's PGN, as saved, where the user chooses. */
@Composable
internal expect fun rememberPgnExport(app: AppModel, onError: (String) -> Unit): (RepertoireEntry) -> Unit

/**
 * Rescans the library when the app comes back to the front (iCloud's file presenters on Apple):
 * Android's activity does it in `onResume`; on the desktop, when the window is focused again.
 */
@Composable
internal expect fun RefreshOnReturn(app: AppModel)
