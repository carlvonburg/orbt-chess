package org.orbtchess.orbt

import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.graphics.painter.BitmapPainter
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.jetbrains.compose.resources.decodeToImageBitmap
import org.orbtchess.orbt.platform.desktopPlatform
import org.orbtchess.orbt.storage.FolderWatcher
import java.awt.event.WindowAdapter
import java.awt.event.WindowEvent

fun main() {
    // The core's library is one of the app's resources (app/build.gradle.kts, `copyHostLibrary`),
    // for `run` and the packaged app alike; a path set on the command line wins.
    System.getProperty("compose.application.resources.dir")?.let { resources ->
        if (System.getProperty("jna.library.path") == null) System.setProperty("jna.library.path", resources)
    }
    val model = AppModel(desktopPlatform())
    val watcher = FolderWatcher(model.documents)
    application {
        // Changes the provider's client makes in the folder (Dropbox, Google Drive for desktop),
        // once the library is read.
        LaunchedEffect(Unit) {
            snapshotFlow { model.library.isLoaded }.first { it }
            watcher.run()
        }
        // The app icon (app/build.gradle.kts says how it is made from Design/AppIcon-light.svg).
        val icon = remember {
            object {}.javaClass.getResourceAsStream("/orbt-icon.png")?.use { BitmapPainter(it.readBytes().decodeToImageBitmap()) }
        }
        Window(
            onCloseRequest = {
                runBlocking { model.flush() }
                exitApplication()
            },
            title = "ORBT Chess",
            icon = icon,
        ) {
            // Back in front (Android's onResume): files changed meanwhile; the network may be back.
            val scope = rememberCoroutineScope()
            DisposableEffect(window) {
                val focus = object : WindowAdapter() {
                    override fun windowGainedFocus(e: WindowEvent) {
                        model.sync.networkAvailable()
                        scope.launch { model.resume() }
                    }
                }
                window.addWindowFocusListener(focus)
                onDispose { window.removeWindowFocusListener(focus) }
            }
            App(model)
        }
    }
}
