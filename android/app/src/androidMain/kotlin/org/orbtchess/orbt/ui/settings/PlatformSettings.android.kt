package org.orbtchess.orbt.ui.settings

import android.os.Build
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.lichess.AuthBrowser
import org.orbtchess.orbt.lichess.CustomTabAuthBrowser

@Composable
internal actual fun rememberAuthBrowser(app: AppModel): AuthBrowser {
    val context = LocalContext.current.applicationContext
    return remember(context) { CustomTabAuthBrowser(context) }
}

@Composable
internal actual fun appVersion(): String {
    val context = LocalContext.current
    return remember(context) {
        runCatching {
            val info = context.packageManager.getPackageInfo(context.packageName, 0)
            val build = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else @Suppress("DEPRECATION") info.versionCode.toLong()
            "${info.versionName} ($build)"
        }.getOrDefault("?")
    }
}
