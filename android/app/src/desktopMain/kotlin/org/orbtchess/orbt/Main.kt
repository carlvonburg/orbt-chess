package org.orbtchess.orbt

import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application

fun main() = application {
    Window(onCloseRequest = ::exitApplication, title = "ORBT Chess") { App() }
}
