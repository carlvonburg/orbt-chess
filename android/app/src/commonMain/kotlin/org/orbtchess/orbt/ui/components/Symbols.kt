package org.orbtchess.orbt.ui.components

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.NavigateBefore
import androidx.compose.material.icons.automirrored.filled.NavigateNext
import androidx.compose.material.icons.automirrored.outlined.Login
import androidx.compose.material.icons.automirrored.outlined.OpenInNew
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.outlined.BarChart
import androidx.compose.material.icons.outlined.Book
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.FileOpen
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Lightbulb
import androidx.compose.material.icons.outlined.Memory
import androidx.compose.material.icons.outlined.Repeat
import androidx.compose.material.icons.outlined.Route
import androidx.compose.material.icons.outlined.School
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material.icons.outlined.SwapVert
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material.icons.outlined.Warning
import androidx.compose.ui.graphics.vector.ImageVector

/**
 * The Material Symbols standing in for the Swift app's SF Symbols, by what they mean, so every
 * screen uses the same symbol for the same thing. Add one here when a second screen needs it;
 * a symbol only one screen uses can stay in that screen.
 */
object Symbols {
    /** "book": the Repertoires tab. */
    val repertoires: ImageVector get() = Icons.Outlined.Book
    /** "chart.bar": Statistics. */
    val statistics: ImageVector get() = Icons.Outlined.BarChart
    /** "gearshape": Settings. */
    val settings: ImageVector get() = Icons.Outlined.Settings
    /** "slider.horizontal.3": a repertoire's settings and study options. */
    val options: ImageVector get() = Icons.Outlined.Tune
    /** "plus": New Repertoire. */
    val add: ImageVector get() = Icons.Filled.Add
    /** "square.and.arrow.down": Import PGN. */
    val importFile: ImageVector get() = Icons.Outlined.FileOpen
    /** "square.and.arrow.up": Export. */
    val share: ImageVector get() = Icons.Outlined.Share
    /** "trash": Delete. */
    val delete: ImageVector get() = Icons.Outlined.Delete
    /** "pencil": Build / Edit Lines. */
    val build: ImageVector get() = Icons.Outlined.Edit
    /** "graduationcap": Study. */
    val study: ImageVector get() = Icons.Outlined.School
    /** "arrow.counterclockwise": Practice. */
    val practice: ImageVector get() = Icons.Outlined.Repeat
    /** "cpu": Analysis, the engine. */
    val analysis: ImageVector get() = Icons.Outlined.Memory
    /** "point.topleft.down.to.point.bottomright.curvepath": the tour (Take the Tour, Show Tour). */
    val tour: ImageVector get() = Icons.Outlined.Route
    /** "lightbulb": Hint. */
    val hint: ImageVector get() = Icons.Outlined.Lightbulb
    /** "arrow.up.arrow.down": Flip Board. */
    val flipBoard: ImageVector get() = Icons.Outlined.SwapVert
    /** "chevron.left" / "chevron.right": previous and next move. */
    val previousMove: ImageVector get() = Icons.AutoMirrored.Filled.NavigateBefore
    val nextMove: ImageVector get() = Icons.AutoMirrored.Filled.NavigateNext
    /** "forward.fill": Next Line. */
    val nextLine: ImageVector get() = Icons.Filled.SkipNext
    /** "checkmark": correct. */
    val correct: ImageVector get() = Icons.Filled.Check
    /** "xmark": wrong. */
    val wrong: ImageVector get() = Icons.Filled.Close
    /** "exclamationmark.triangle": something failed or is unavailable. */
    val warning: ImageVector get() = Icons.Outlined.Warning
    /** "info.circle": Card Info, About. */
    val info: ImageVector get() = Icons.Outlined.Info
    /** "ellipsis.circle": the More menu. */
    val more: ImageVector get() = Icons.Filled.MoreVert
    /** "safari": open on Lichess. */
    val openInBrowser: ImageVector get() = Icons.AutoMirrored.Outlined.OpenInNew
    /** "person.crop.circle": Sign in with Lichess. */
    val signIn: ImageVector get() = Icons.AutoMirrored.Outlined.Login
}
