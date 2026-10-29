package org.orbtchess.orbt.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import org.orbtchess.orbt.core.Counts
import org.orbtchess.orbt.core.Progress
import org.orbtchess.orbt.core.studied
import org.orbtchess.orbt.ui.theme.ThemeColor
import org.orbtchess.orbt.ui.theme.color

/**
 * New / Learning / To Review, as on Anki's deck list (`DueCounts` in Swift). Nothing when the
 * repertoire has no moves of yours yet, only the new count before anything was studied, zeros
 * faint. Colored like the studied bar: [ThemeColor.new], [ThemeColor.learning],
 * [ThemeColor.learned]. Tabular digits, so counts don't shift as they change.
 */
@Composable
fun DueCounts(
    counts: Counts,
    progress: Progress,
    modifier: Modifier = Modifier,
    style: TextStyle = MaterialTheme.typography.titleSmall,
) {
    val numbers = style.copy(fontWeight = FontWeight.SemiBold, fontFeatureSettings = "tnum")
    when {
        progress.cards == 0L -> Unit
        progress.studied == 0L ->
            Text("${counts.new} new", modifier, color = countColor(counts.new, ThemeColor.new), style = numbers)
        else -> Row(
            modifier.clearAndSetSemantics {
                contentDescription = "${counts.new} new, ${counts.learning} learning, ${counts.review} to review"
            },
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text("${counts.new}", color = countColor(counts.new, ThemeColor.new), style = numbers)
            Text("${counts.learning}", color = countColor(counts.learning, ThemeColor.learning), style = numbers)
            Text("${counts.review}", color = countColor(counts.review, ThemeColor.learned), style = numbers)
        }
    }
}

/** A count in its meaning's color, or faint at zero (nothing to do). */
@Composable
fun countColor(value: Long, meaning: ThemeColor) =
    if (value > 0) meaning.color else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.38f)

/** Body text with tabular digits, for numbers that change in place. */
@Composable
fun tabularDigits(style: TextStyle = LocalTextStyle.current): TextStyle = style.copy(fontFeatureSettings = "tnum")
