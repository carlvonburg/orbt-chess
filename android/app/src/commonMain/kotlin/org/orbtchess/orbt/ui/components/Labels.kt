package org.orbtchess.orbt.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import org.orbtchess.orbt.ui.theme.ThemeColor
import org.orbtchess.orbt.ui.theme.color

/**
 * A symbol and its text in one color, as SwiftUI's `Label`: never a color alone (Design/COLORS.md
 * rule 3). Colored by a meaning, or the surrounding content color. For a list row use Material's
 * `ListItem` with a leading icon instead.
 */
@Composable
fun SymbolLabel(
    text: String,
    icon: ImageVector,
    modifier: Modifier = Modifier,
    meaning: ThemeColor? = null,
    style: TextStyle = MaterialTheme.typography.bodyMedium,
) {
    val color = meaning?.color ?: LocalContentColor.current
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
        // Decorative: the text says it.
        Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(18.dp))
        Text(text, color = color, style = style)
    }
}

/**
 * A small status label (`statusBadge` in Swift): text in a meaning's color on a light tint of
 * it, or secondary text on a neutral fill. Content, not a control (Material's chips are
 * controls; its `Badge` is for counts on icons).
 */
@Composable
fun StatusBadge(text: String, modifier: Modifier = Modifier, meaning: ThemeColor? = null) {
    val content: Color = meaning?.color ?: MaterialTheme.colorScheme.onSurfaceVariant
    val fill: Color = meaning?.opacity(0.18f)?.color ?: MaterialTheme.colorScheme.surfaceContainerHighest
    Surface(modifier, shape = CircleShape, color = fill, contentColor = content) {
        Text(text, style = MaterialTheme.typography.labelLarge, modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp))
    }
}
