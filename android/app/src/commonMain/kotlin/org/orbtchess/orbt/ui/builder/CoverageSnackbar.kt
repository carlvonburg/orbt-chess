package org.orbtchess.orbt.ui.builder

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.SubdirectoryArrowRight
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Snackbar
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarVisuals
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import org.orbtchess.orbt.core.NodeCoverage
import org.orbtchess.orbt.ui.components.Format
import org.orbtchess.orbt.ui.components.tabularDigits
import java.text.NumberFormat

/** What a save did to the repertoire's coverage (`CoverageChange` in CoverageToast.swift). */
internal class CoverageChange private constructor(
    val before: Snapshot,
    val after: Snapshot,
    /** The saved line still has a gap below it (stopped before a reply that needs an answer). */
    val lineOpen: Boolean,
) {
    data class Snapshot(val completion: Double, val gaps: Long) {
        constructor(root: NodeCoverage?) : this(root?.completion ?: 0.0, root?.gapCount ?: 0L)
    }

    /** Coverage went up: a gap filled, or a required reply answered further. */
    val raised: Boolean get() = after.gaps < before.gaps || after.completion > before.completion + 0.0005

    val title: String
        get() {
            val filled = before.gaps - after.gaps
            return when {
                !raised -> "Line Saved"
                filled < 1 -> "Coverage Up"
                filled == 1L -> "Gap Filled"
                else -> "$filled Gaps Filled"
            }
        }

    val detail: String
        get() {
            // Saved, but a reply it reaches still needs an answer: the gap moved down the line.
            if (!raised) return "Not covered yet: a common reply in it still needs your answer."
            val left = when (after.gaps) {
                0L -> "no gaps left"
                1L -> "1 gap left"
                else -> "${NumberFormat.getIntegerInstance().format(after.gaps)} gaps left"
            }
            return "${Format.percent(before.completion)} → ${Format.percent(after.completion)} complete, $left"
        }

    val icon: ImageVector
        get() = when {
            !raised -> Icons.Filled.SubdirectoryArrowRight
            after.gaps == 0L -> Icons.Filled.Verified
            else -> Icons.Filled.CheckCircle
        }

    companion object {
        /** Null when there is nothing to tell: coverage unchanged and the line has no gap (beyond the target). */
        fun of(before: Snapshot, after: Snapshot, lineOpen: Boolean): CoverageChange? =
            CoverageChange(before, after, lineOpen).takeIf { it.raised || lineOpen }
    }
}

/** A coverage change as a snackbar's visuals; its message is what a screen reader says. */
private class CoverageVisuals(val change: CoverageChange) : SnackbarVisuals {
    override val message: String = "${change.title}. ${change.detail}"
    override val actionLabel: String? = null
    override val withDismissAction: Boolean = false
    override val duration: SnackbarDuration = SnackbarDuration.Short
}

/**
 * The last save's effect on coverage, for a few seconds above the bottom bar (`CoverageToast`,
 * Material's snackbar here): shows that filling a gap raises coverage, and that a line stopped
 * above the target leaves one. A new save replaces it.
 */
internal suspend fun SnackbarHostState.showCoverageChange(change: CoverageChange) {
    currentSnackbarData?.dismiss()
    showSnackbar(CoverageVisuals(change))
}

/** Where Browse shows [showCoverageChange]'s snackbar; tap it to dismiss. */
@Composable
internal fun CoverageSnackbarHost(state: SnackbarHostState) {
    SnackbarHost(state) { data ->
        val change = (data.visuals as? CoverageVisuals)?.change
        Snackbar(Modifier.clickable { data.dismiss() }) {
            if (change == null) {
                Text(data.visuals.message)
                return@Snackbar
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Icon(change.icon, contentDescription = null, tint = MaterialTheme.colorScheme.inversePrimary)
                Column {
                    Text(change.title, style = MaterialTheme.typography.titleSmall)
                    Text(change.detail, style = tabularDigits(MaterialTheme.typography.bodySmall))
                }
            }
        }
    }
}
