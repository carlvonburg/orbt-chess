package org.orbtchess.orbt.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import com.materialkolor.PaletteStyle
import com.materialkolor.dynamicColorScheme
import com.materialkolor.ktx.harmonize
import com.materialkolor.ktx.toColor
import com.materialkolor.ktx.toHct

// The app's colors, by meaning (Design/COLORS.md), ported from apple/ORBT/UI/Components/Palette.swift.
// Views name a meaning (`ThemeColor.learned`), never a hue; the theme of the app color resolves
// it, always next to a symbol, text or shape. Controls take the app color from Material itself
// (`MaterialTheme.colorScheme.primary` is the app color): views use stock components and let
// them color themselves.

/**
 * A color by its meaning, resolved by the app's [Theme] where it is drawn: views say what a
 * color means, the theme decides the hue, so a change of app color reaches every view.
 *
 * ```
 * Text("12", color = ThemeColor.learned.color)
 * Box(Modifier.background(ThemeColor.learned.lighter().color))
 * ```
 */
@Immutable
data class ThemeColor(
    val role: Role,
    val alpha: Float = 1f,
    /** How far the color is mixed toward white: a lighter shade of the same meaning (young next to mature). */
    val lightening: Float = 0f,
) {
    enum class Role {
        /** Building: the covered part of coverage bars, your saved moves, transpositions. The app color. */
        Built,

        /** Learned: reviews due, Anki's young (lighter) and mature, studied today. */
        Learned,

        /** Being learned: Anki's learning (lighter) and relearning. */
        Learning,

        /** New, not studied yet (Anki). */
        New,

        /** Something to do: gaps, a missing move of yours, the streak, a leech, your alternative. */
        Todo,

        /** A correct answer: the check badge, "Correct", correct %. */
        Correct,

        /** A wrong answer: the cross badge, "Not quite", Again, overdue. */
        Wrong,

        /** Something failed: error messages, actions that delete (Material's error color). */
        Failure,

        /** Reviewed ahead (Anki's filtered decks). */
        Ahead,

        /** Inactive: suspended. */
        Inactive,
    }

    fun opacity(alpha: Float): ThemeColor = copy(alpha = this.alpha * alpha)

    /** A lighter shade of the same color, in light and dark appearance alike. */
    fun lighter(amount: Float = 0.45f): ThemeColor = copy(lightening = amount)

    companion object {
        val built = ThemeColor(Role.Built)
        val learned = ThemeColor(Role.Learned)
        val learning = ThemeColor(Role.Learning)
        val new = ThemeColor(Role.New)
        val todo = ThemeColor(Role.Todo)
        val correct = ThemeColor(Role.Correct)
        val wrong = ThemeColor(Role.Wrong)
        val failure = ThemeColor(Role.Failure)
        val ahead = ThemeColor(Role.Ahead)
        val inactive = ThemeColor(Role.Inactive)
    }
}

/** The color of a meaning where it is drawn: the theme's, or on a selected row the row's content color. */
val ThemeColor.color: Color
    @Composable @ReadOnlyComposable
    get() = LocalTheme.current.resolve(this, LocalSelectedRow.current, LocalContentColor.current)

/**
 * True inside a selected row (the list pane's selected repertoire, drawn by Material with the
 * secondary container): meaning colors turn into the row's content color, as the Swift app
 * turns them white on the Mac's accent selection. Lighter shades and learning keep apart by
 * strength. Set it with `CompositionLocalProvider(LocalSelectedRow provides true)`.
 */
val LocalSelectedRow = compositionLocalOf { false }

/**
 * The colors of one app color: every meaning's color, and the board. Multicolor gives each
 * meaning its own color (Anki's for studying); the other app colors are tinted: the app color
 * for building, learned, correct and to do, the label colors for learning (on-surface-variant)
 * and new (on-surface), red for wrong (purple where the app color is red or pink).
 */
@Immutable
class Theme internal constructor(
    val appColor: AppColor,
    val isDark: Boolean,
    /** The Material color scheme (its primary is the app color). */
    val scheme: ColorScheme,
    /** The tinted themes' color: the app color (graphite's gray would read as learning: indigo). */
    private val tint: Color,
    /** The board's tint: the app color itself (Material You's primary for Multicolor). */
    val boardTint: Color,
    /** Whether the scheme is Material You's (custom colors are then harmonized with it). */
    private val harmonize: Boolean,
) {
    private val multicolor get() = appColor == AppColor.Multicolor

    /**
     * A color outside the scheme as Material makes one (a custom color): its hue at tone 40 in
     * light and 80 in dark, harmonized with Material You's primary.
     */
    private fun custom(hue: Color): Color {
        val harmonized = if (harmonize) hue.harmonize(scheme.primary) else hue
        return harmonized.toHct().withTone(if (isDark) 80.0 else 40.0).toColor()
    }

    private val colors: Map<ThemeColor.Role, Color> = ThemeColor.Role.entries.associateWith { role ->
        when (role) {
            ThemeColor.Role.Built -> scheme.primary
            ThemeColor.Role.Learned, ThemeColor.Role.Correct -> if (multicolor) custom(Hues.Green) else tint
            ThemeColor.Role.Learning -> if (multicolor) custom(Hues.Red) else scheme.onSurfaceVariant
            ThemeColor.Role.New -> if (multicolor) custom(Hues.Blue) else scheme.onSurface
            ThemeColor.Role.Todo -> if (multicolor) custom(Hues.Orange) else tint
            ThemeColor.Role.Wrong ->
                custom(if (appColor == AppColor.Red || appColor == AppColor.Pink) Hues.Purple else Hues.Red)
            ThemeColor.Role.Failure -> scheme.error
            ThemeColor.Role.Ahead -> custom(Hues.Cyan)
            ThemeColor.Role.Inactive -> if (multicolor) scheme.outline else scheme.onSurfaceVariant.copy(alpha = 0.4f)
        }
    }

    /** The color of a meaning, at full strength. */
    fun color(role: ThemeColor.Role): Color = colors.getValue(role)

    /** A meaning's color as drawn, with its shade and opacity; on a selected row the row's content color. */
    fun resolve(color: ThemeColor, selectedRow: Boolean = false, rowContent: Color = scheme.onSecondaryContainer): Color {
        if (selectedRow) {
            val strength = when {
                color.role == ThemeColor.Role.Learning -> 0.55f
                color.lightening > 0f -> 0.75f
                else -> 1f
            }
            return rowContent.copy(alpha = rowContent.alpha * color.alpha * strength)
        }
        var base = color(color.role)
        if (color.lightening > 0f) base = lerp(base, Hues.White, color.lightening)
        return base.copy(alpha = base.alpha * color.alpha)
    }

    val board: BoardTheme by lazy { BoardTheme(this) }

    companion object {
        /** The theme of an app color, from Material You's scheme when the system gives one (Multicolor). */
        fun make(appColor: AppColor, isDark: Boolean, systemScheme: ColorScheme?): Theme {
            val dynamic = if (appColor == AppColor.Multicolor) systemScheme else null
            val scheme = dynamic ?: seededScheme(appColor.seed, isDark, appColor == AppColor.Graphite)
            val tint = if (appColor == AppColor.Graphite) seededScheme(Hues.Indigo, isDark, false).primary else scheme.primary
            val boardTint = if (dynamic != null) dynamic.primary.toHct().withTone(55.0).toColor() else appColor.seed
            return Theme(appColor, isDark, scheme, tint, boardTint, harmonize = dynamic != null)
        }

        private fun seededScheme(seed: Color, isDark: Boolean, monochrome: Boolean): ColorScheme =
            dynamicColorScheme(
                seedColor = seed,
                isDark = isDark,
                style = if (monochrome) PaletteStyle.Monochrome else PaletteStyle.TonalSpot,
            )
    }
}

/** The app's theme where it is drawn (set by [OrbtTheme]). */
val LocalTheme = staticCompositionLocalOf { Theme.make(AppColor.Default, isDark = false, systemScheme = null) }

/**
 * The app's theme: Material 3 with the app color as the scheme (Material You for Multicolor
 * where the system has it), light or dark with the system, and the meaning colors.
 */
@Composable
fun OrbtTheme(
    appColor: AppColor,
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    val system = systemDynamicColorScheme(darkTheme)
    val theme = remember(appColor, darkTheme, system) { Theme.make(appColor, darkTheme, system) }
    CompositionLocalProvider(LocalTheme provides theme) {
        MaterialTheme(colorScheme = theme.scheme, content = content)
    }
}

/** The theme from a view: `OrbtTheme.current`, `OrbtTheme.board`. */
object OrbtTheme {
    val current: Theme
        @Composable @ReadOnlyComposable
        get() = LocalTheme.current

    val board: BoardTheme
        @Composable @ReadOnlyComposable
        get() = LocalTheme.current.board
}

/** Material You's scheme on Android 12 and later; null elsewhere (the desktop, older Android). */
@Composable
internal expect fun systemDynamicColorScheme(darkTheme: Boolean): ColorScheme?
