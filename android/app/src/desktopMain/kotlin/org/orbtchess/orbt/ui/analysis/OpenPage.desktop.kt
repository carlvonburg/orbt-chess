package org.orbtchess.orbt.ui.analysis

import androidx.compose.runtime.Composable
import org.orbtchess.orbt.AppModel

@Composable
internal actual fun rememberOpenPage(app: AppModel): (String) -> Unit = app.platform.openUrl
