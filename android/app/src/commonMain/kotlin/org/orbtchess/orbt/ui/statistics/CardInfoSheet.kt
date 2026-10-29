package org.orbtchess.orbt.ui.statistics

import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.storage.NodeId
import org.orbtchess.orbt.storage.RepertoireDocument

/**
 * Anki's Card Info for the move at [node] (`CardInfoSheet.swift`): dates, interval, memory
 * state, history. The content of a Material bottom sheet the shell shows.
 */
@Composable
fun CardInfoSheet(
    app: AppModel,
    document: RepertoireDocument,
    node: NodeId,
    modifier: Modifier = Modifier,
) {
    // STUB
    Text("Card Info (not ported yet)", modifier.padding(24.dp))
}
