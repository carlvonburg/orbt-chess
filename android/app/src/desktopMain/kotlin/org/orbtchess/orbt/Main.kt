package org.orbtchess.orbt

import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.painter.BitmapPainter
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.WindowPlacement
import androidx.compose.ui.window.WindowPosition
import androidx.compose.ui.window.WindowState
import androidx.compose.ui.window.application
import org.orbtchess.orbt.platform.Settings
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
        // Changes made to the folder outside the app, once the library is read.
        LaunchedEffect(Unit) {
            snapshotFlow { model.library.isLoaded }.first { it }
            watcher.run()
        }
        // The app icon (app/build.gradle.kts says how it is made from Design/AppIcon-light.svg).
        val icon = remember {
            object {}.javaClass.getResourceAsStream("/orbt-icon.png")?.use { BitmapPainter(it.readBytes().decodeToImageBitmap()) }
        }
        val windowState = remember { savedWindowState(model.platform.settings) }
        Window(
            onCloseRequest = {
                windowState.save(model.platform.settings)
                runBlocking { model.flush() }
                exitApplication()
            },
            state = windowState,
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

/**
 * The window as it was left (size, place, maximized); the first time, 1200 × 800 in the middle
 * of the screen (Compose's own default, 800 × 600, is too small for the board and its panel).
 */
private fun savedWindowState(settings: Settings): WindowState {
    val width = settings.getInt(WINDOW_WIDTH)
    val height = settings.getInt(WINDOW_HEIGHT)
    val x = settings.getInt(WINDOW_X)
    val y = settings.getInt(WINDOW_Y)
    return WindowState(
        placement = if (settings.getBoolean(WINDOW_MAXIMIZED) == true) WindowPlacement.Maximized else WindowPlacement.Floating,
        position = if (x != null && y != null) WindowPosition(x.dp, y.dp) else WindowPosition(Alignment.Center),
        size = if (width != null && height != null) DpSize(width.dp, height.dp) else DpSize(1200.dp, 800.dp),
    )
}

private fun WindowState.save(settings: Settings) {
    settings.putBoolean(WINDOW_MAXIMIZED, placement == WindowPlacement.Maximized)
    // A maximized window keeps the size and place it had before.
    if (placement != WindowPlacement.Floating) return
    settings.putInt(WINDOW_WIDTH, size.width.value.toInt())
    settings.putInt(WINDOW_HEIGHT, size.height.value.toInt())
    if (position.isSpecified) {
        settings.putInt(WINDOW_X, position.x.value.toInt())
        settings.putInt(WINDOW_Y, position.y.value.toInt())
    }
}

private const val WINDOW_WIDTH = "windowWidth"
private const val WINDOW_HEIGHT = "windowHeight"
private const val WINDOW_X = "windowX"
private const val WINDOW_Y = "windowY"
private const val WINDOW_MAXIMIZED = "windowMaximized"
