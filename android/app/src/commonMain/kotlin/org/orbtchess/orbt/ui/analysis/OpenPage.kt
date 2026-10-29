package org.orbtchess.orbt.ui.analysis

import androidx.compose.runtime.Composable
import org.orbtchess.orbt.AppModel

/**
 * Opens a web page over the app (Open in Lichess), as the Swift app's web sheet: a Custom Tab on
 * Android, the browser on the desktop.
 */
@Composable
internal expect fun rememberOpenPage(app: AppModel): (String) -> Unit
