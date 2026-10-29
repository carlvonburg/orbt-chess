package org.orbtchess.orbt

import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import org.orbtchess.orbt.ui.AppShell
import org.orbtchess.orbt.ui.theme.AppColorSetting
import org.orbtchess.orbt.ui.theme.LocalAppColorSetting
import org.orbtchess.orbt.ui.theme.OrbtTheme

/** The app's root (`RootView` in Swift): the theme of the app color around the navigation shell. */
@Composable
fun App(model: AppModel) {
    LaunchedEffect(Unit) { model.setUp() }
    val appColor = remember { AppColorSetting(model.platform.settings) }
    CompositionLocalProvider(LocalAppColorSetting provides appColor) {
        OrbtTheme(appColor.appColor) {
            AppShell(model)
        }
    }
}
