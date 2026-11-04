package org.orbtchess.orbt.ui.components

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.click
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performMouseInput
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.runComposeUiTest
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.engine.MemorySettings
import org.orbtchess.orbt.platform.AppFolders
import org.orbtchess.orbt.platform.PlatformServices
import org.orbtchess.orbt.platform.SecretStore
import org.orbtchess.orbt.ui.SetupMode
import org.orbtchess.orbt.ui.library.SetupScreen
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertTrue

/** The rating menu opens with a click on the setup's second step (it did not on the desktop). */
@OptIn(ExperimentalTestApi::class)
class DropdownTest {
    @Test
    fun ratingOpensOnTheSetupScreensSecondStep() = runComposeUiTest {
        val root = Files.createTempDirectory("orbt-ui").toFile().apply { deleteOnExit() }
        val secrets = object : SecretStore {
            val values = mutableMapOf<String, String>()
            override fun get(key: String) = values[key]
            override fun set(key: String, value: String) { values[key] = value }
            override fun remove(key: String) { values.remove(key) }
        }
        val app = AppModel(PlatformServices(AppFolders(root.resolve("R"), root.resolve("S")), MemorySettings(), secrets, {}, { null }))
        setContent { SetupScreen(app, SetupMode.New, {}, {}) }
        onNodeWithText("Najdorf").performTextInput("Test")
        onNodeWithText("Next").performClick()
        waitForIdle()
        val ranges = { onAllNodesWithText("–", substring = true).fetchSemanticsNodes().size }
        val before = ranges()
        onNodeWithText("Their rating").performMouseInput { click() }
        waitForIdle()
        assertTrue(ranges() > before, "the rating menu did not open")
    }
}
