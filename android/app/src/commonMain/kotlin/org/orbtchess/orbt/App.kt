package org.orbtchess.orbt

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import orbt.app.generated.resources.Res
import org.jetbrains.compose.resources.ExperimentalResourceApi
import org.orbtchess.orbt.storage.RepertoireDocument

/** The app's root. For now the library and an opened repertoire; the real screens follow. */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalResourceApi::class)
@Composable
fun App(model: AppModel) {
    val scope = rememberCoroutineScope()
    var opened by remember { mutableStateOf<RepertoireDocument?>(null) }
    LaunchedEffect(Unit) { model.setUp() }
    MaterialTheme {
        Scaffold(topBar = { TopAppBar(title = { Text("Repertoires") }) }) { padding ->
            Column(Modifier.fillMaxSize().padding(padding).padding(horizontal = 16.dp)) {
                if (model.library.isLoaded && model.library.entries.isEmpty()) {
                    Button(onClick = {
                        scope.launch {
                            val bytes = Res.readBytes("files/sample.pgn")
                            model.library.addSample { bytes }
                        }
                    }) { Text("Add the sample repertoire") }
                }
                LazyColumn {
                    items(model.library.entries, key = { it.id }) { entry ->
                        ListItem(
                            headlineContent = { Text(entry.name) },
                            supportingContent = { Text(if (entry.needsSetup) "Needs setup" else "Ready") },
                            modifier = Modifier.clickable {
                                scope.launch { opened = model.documents.open(entry) }
                            },
                        )
                    }
                }
                opened?.let { doc ->
                    Text("Opened ${doc.name} (revision ${doc.revision})", style = MaterialTheme.typography.bodyLarge)
                }
            }
        }
    }
}
