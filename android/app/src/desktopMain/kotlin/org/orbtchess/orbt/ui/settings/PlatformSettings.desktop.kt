package org.orbtchess.orbt.ui.settings

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.lichess.AuthBrowser
import org.orbtchess.orbt.lichess.LoopbackAuthBrowser

@Composable
internal actual fun rememberAuthBrowser(app: AppModel): AuthBrowser =
    remember(app) { LoopbackAuthBrowser(app.platform.openUrl) }

/** jpackage sets the version of a packaged app; a run from Gradle has none. */
@Composable
internal actual fun appVersion(): String = System.getProperty("jpackage.app-version") ?: "development"
