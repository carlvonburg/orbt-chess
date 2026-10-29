package org.orbtchess.orbt

import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import kotlinx.coroutines.runBlocking
import org.orbtchess.orbt.platform.desktopPlatform

fun main() {
    // The core's library is one of the app's resources (app/build.gradle.kts, `copyHostLibrary`),
    // for `run` and the packaged app alike; a path set on the command line wins.
    System.getProperty("compose.application.resources.dir")?.let { resources ->
        if (System.getProperty("jna.library.path") == null) System.setProperty("jna.library.path", resources)
    }
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
