package org.orbtchess.orbt.ui.theme

import androidx.compose.runtime.Immutable
import androidx.compose.ui.graphics.Color
import com.materialkolor.ktx.toColor
import com.materialkolor.ktx.toHct

/**
 * The board for a theme (`BoardTheme` in Palette.swift), in Material's terms: content with its
 * own colors, the same in the app's light and dark appearance (dimmer squares in dark), every
 * color a tone of the theme's primary tonal palette (HCT: the primary's hue and chroma at another
 * tone; Material You's for Multicolor, the seeded scheme's for the other app colors, neutral for
 * graphite), as Material derives its own roles. Its overlays are one ink, the palette's dark
 * tone, told apart by width, opacity and dashes. Design/COLORS.md, "Android and desktop", has the
 * tones.
 */
@Immutable
class BoardTheme internal constructor(private val theme: Theme) {
    private val palette = theme.boardTint.toHct()
    private val graphite = theme.appColor == AppColor.Graphite

    /** The palette at [tone] (0 black, 100 white), its hue and chroma kept as far as sRGB allows. */
    private fun tone(tone: Double): Color = palette.withTone(tone).toColor()

    val light: Color = tone(if (theme.isDark) 80.0 else 90.0)
    val dark: Color = tone(if (theme.isDark) 55.0 else 68.0)

    /**
     * The board's ink: the palette at tone 28, which every board shows clearly (a board swallows
     * a mid tone of its own hue). Your moves, the hint, the replies you cover and, dashed, the
     * gaps; the check badge in tinted themes.
     */
    val ink: Color = tone(28.0)

    /** The check badge: Multicolor's correct color; tinted themes the ink. */
    val correct: Color = if (theme.appColor == AppColor.Multicolor) theme.color(ThemeColor.Role.Correct) else ink

    /** The cross badge. */
    val wrong: Color = theme.color(ThemeColor.Role.Wrong)

    /** The badges' glyph: white on its disc (SF Symbols' palette rendering in Swift). */
    val badgeGlyph: Color = Hues.White

    /** The palette's mid tone, for the highlights. */
    private val mid = tone(if (theme.isDark) 38.0 else 48.0)

    /** The last move: the palette's mid tone over the square (the ink for graphite, whose gray the board doesn't show). */
    val lastMove: Color = if (graphite) ink.copy(alpha = 0.25f) else mid.copy(alpha = 0.6f)

    /** The selected square. */
    val selected: Color = if (graphite) ink.copy(alpha = 0.4f) else mid.copy(alpha = 0.8f)

    /** The engine's lines: graphite (best 70%, then 45%, 30%). */
    val engine: Color = Hues.Engine

    /** Legal destinations: dots on empty squares. */
    val moveDot: Color = Hues.Black.copy(alpha = 0.22f)

    /** Legal captures: rings. */
    val captureRing: Color = Hues.Black.copy(alpha = 0.25f)

    /** The dimming behind the promotion picker. */
    val promotionScrim: Color = Hues.Black.copy(alpha = 0.35f)

    /** The explorer's result bar (`ScoreBar`): white, draws, black, each with its text color. */
    val whiteResult: Color = Color(0xFFF5F5F5)
    val drawResult: Color = Color(0xFF999999)
    val blackResult: Color = Color(0xFF262626)
    fun resultText(fill: Color): Color = if (fill == whiteResult) Hues.Black else Hues.White

    /** A square's coordinate label: the opposite square's color. */
    fun coordinate(onLightSquare: Boolean): Color = if (onLightSquare) dark else light
}
