package org.orbtchess.orbt.ui.analysis

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import org.orbtchess.orbt.ui.components.AdaptiveSheet
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.ui.settings.EngineSettingsSection

/**
 * The engine's settings over the analysis board, the same as in Settings (`EngineSettingsSheet`
 * in AnalysisView.swift): Settings' own section in a full sheet, under the sheet's title only.
 * Dismissing it analyses again.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun EngineSettingsSheet(app: AppModel, onDismiss: () -> Unit) {
    AdaptiveSheet(onDismissRequest = onDismiss, expandedOnly = true) {
        Column(Modifier.verticalScroll(rememberScrollState())) {
            Text(
                "Engine Settings",
                style = MaterialTheme.typography.titleLarge,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
            )
            // The sheet's title names it: no section heading under it.
            EngineSettingsSection(app, heading = null)
        }
    }
}
