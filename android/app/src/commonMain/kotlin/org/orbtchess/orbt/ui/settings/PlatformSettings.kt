package org.orbtchess.orbt.ui.settings

import androidx.compose.runtime.Composable
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.lichess.AuthBrowser

/**
 * The platform's browser for the Lichess sign-in (`webAuthenticationSession` in the Swift app):
 * a Custom Tab on Android, the default browser and a loopback redirect on the desktop.
 */
@Composable
internal expect fun rememberAuthBrowser(app: AppModel): AuthBrowser

/** The app's version and build, "0.1 (1)". */
@Composable
internal expect fun appVersion(): String
