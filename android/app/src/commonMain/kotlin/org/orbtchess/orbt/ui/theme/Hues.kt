package org.orbtchess.orbt.ui.theme

import androidx.compose.ui.graphics.Color

/**
 * Every hue the app names: the only place besides the other `ui/theme` files where a color is
 * written by its hue. Views never use these; they name a meaning (`ThemeColor`) or a Material
 * role (`MaterialTheme.colorScheme`).
 *
 * Apple's system colors (light appearance), so the seeds and the meanings match the Swift app.
 * The meanings are not used as they are: `Theme` turns each into a Material custom color (tone
 * 40 in light, 80 in dark, harmonized with Material You's primary), as Material asks for colors
 * outside the scheme.
 */
internal object Hues {
    val Blue = Color(0xFF007AFF)
    val Indigo = Color(0xFF5856D6)
    val Purple = Color(0xFFAF52DE)
    val Pink = Color(0xFFFF2D55)
    val Red = Color(0xFFFF3B30)
    val Orange = Color(0xFFFF9500)
    val Yellow = Color(0xFFFFCC00)
    val Green = Color(0xFF34C759)
    val Cyan = Color(0xFF32ADE6)
    val Gray = Color(0xFF8E8E93)

    /** The board's squares (`BoardLight` / `BoardDark` asset colors), light and dark appearance. */
    val BoardLight = Color(0xFFE4E6E9)
    val BoardDark = Color(0xFF8E959E)
    val BoardLightDim = Color(0xFFC4C8CD)
    val BoardDarkDim = Color(0xFF737A84)

    /** The engine's lines: graphite, quiet (there are often three). */
    val Engine = Color(0xFF2C2C2E)

    val Black = Color.Black
    val White = Color.White
}
