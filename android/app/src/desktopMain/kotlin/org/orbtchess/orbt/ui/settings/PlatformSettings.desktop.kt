package org.orbtchess.orbt.ui.settings

import androidx.compose.runtime.Composable

/** jpackage sets the version of a packaged app; a run from Gradle has none. */
@Composable
internal actual fun appVersion(): String = System.getProperty("jpackage.app-version") ?: "development"
