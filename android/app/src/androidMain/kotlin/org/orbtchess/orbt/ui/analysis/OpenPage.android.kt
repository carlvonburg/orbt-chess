package org.orbtchess.orbt.ui.analysis

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.lichess.openInCustomTab

@Composable
internal actual fun rememberOpenPage(app: AppModel): (String) -> Unit {
    val context = LocalContext.current
    return remember(context) { { url -> openInCustomTab(context, url) } }
}
