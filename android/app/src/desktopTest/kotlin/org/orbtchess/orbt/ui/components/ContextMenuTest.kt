package org.orbtchess.orbt.ui.components

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.click
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performMouseInput
import androidx.compose.ui.test.rightClick
import androidx.compose.ui.test.runComposeUiTest
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** A right click opens a row's menu at the pointer, as a long press does, without the row's click. */
@OptIn(ExperimentalTestApi::class, ExperimentalFoundationApi::class)
class ContextMenuTest {
    @Test
    fun rightClickOpensTheMenuWhereClicked() = runComposeUiTest {
        var clicks = 0
        setContent {
            var open by remember { mutableStateOf(false) }
            var at by remember { mutableStateOf<IntOffset?>(null) }
            Box {
                Box(
                    Modifier.fillMaxWidth().height(48.dp).testTag("row")
                        .onSecondaryClick { at = it; open = true }
                        .combinedClickable(onLongClick = { at = null; open = true }) { clicks++ },
                ) { Text("Row") }
                ExpressiveMenu(open, onDismissRequest = { open = false }, at = at) {
                    group { item("Delete") {} }
                }
            }
        }
        onNodeWithTag("row").performMouseInput { click() }
        waitForIdle()
        assertEquals(1, clicks)
        onNodeWithText("Delete").assertDoesNotExist()

        onNodeWithTag("row").performMouseInput { rightClick(Offset(200f, 10f)) }
        waitForIdle()
        assertEquals(1, clicks, "a right click is not a click")
        val item = onNodeWithText("Delete").fetchSemanticsNode().boundsInRoot
        assertTrue(item.left >= 150f && item.top >= 10f, "the menu is not at the pointer: $item")
    }
}
