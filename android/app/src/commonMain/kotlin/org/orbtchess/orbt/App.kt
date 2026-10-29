package org.orbtchess.orbt

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import org.orbtchess.orbt.core.Position
import org.orbtchess.orbt.core.coreVersion

/** The app's root. For now: proof that the Rust core answers. */
@Composable
fun App() {
    val start = remember { Position.start() }
    MaterialTheme {
        Scaffold { padding ->
            Column(
                Modifier.fillMaxSize().padding(padding).padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text("ORBT Chess", style = MaterialTheme.typography.headlineMedium)
                Text("Core ${coreVersion()}")
                Text("${start.legalMoves().size} legal moves from the start: " +
                    start.legalMoves().joinToString(" ") { it.san })
            }
        }
    }
}
