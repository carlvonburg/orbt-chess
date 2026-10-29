package org.orbtchess.orbt

import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import kotlinx.coroutines.runBlocking
import org.orbtchess.orbt.platform.desktopPlatform

fun main() {
    val model = AppModel(desktopPlatform())
    application {
        Window(
            onCloseRequest = {
                runBlocking { model.flush() }
                exitApplication()
            },
            title = "ORBT Chess",
        ) { App(model) }
    }
}
