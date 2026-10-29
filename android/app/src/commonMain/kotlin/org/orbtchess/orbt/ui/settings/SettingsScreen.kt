package org.orbtchess.orbt.ui.settings

import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.ui.Destination
import org.orbtchess.orbt.ui.Placeholder
import org.orbtchess.orbt.ui.theme.AppColor
import org.orbtchess.orbt.ui.theme.LocalAppColorSetting

/**
 * The app's settings (`SettingsView.swift`): app color (`LocalAppColorSetting`), Lichess
 * account, engine (search time, lines, cloud evals, the full net download), training defaults,
 * about. Full window.
 *
 * @param navigate [Destination.Acknowledgements].
 */
@Composable
fun SettingsScreen(
    app: AppModel,
    navigate: (Destination) -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    // STUB
    val appColor = LocalAppColorSetting.current
    Placeholder("Settings", onBack, modifier) {
        TextButton(onClick = {
            appColor.select(AppColor.entries[(appColor.appColor.ordinal + 1) % AppColor.entries.size])
        }) { Text("App color: ${appColor.appColor.title}") }
        TextButton(onClick = { navigate(Destination.Acknowledgements) }) { Text("Acknowledgements") }
    }
}
