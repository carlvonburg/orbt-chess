package org.orbtchess.orbt.ui.theme

import androidx.compose.runtime.Immutable
import androidx.compose.ui.graphics.Color
import com.materialkolor.ktx.toColor
import com.materialkolor.hct.Hct
import com.materialkolor.ktx.toHct

/**
 * The board for a theme (`BoardTheme` in Palette.swift), in Material's terms: content with its
 * own colors, the same in the app's light and dark appearance (dimmer squares in dark). Its hue
 * is the theme's primary's (Material You's for Multicolor, the seeded scheme's for the other app
 * colors, neutral for graphite); the squares take that hue at low chroma, as the iPhone's calm
 * board (pale tinted light squares, muted mid-tone dark squares: there tone 87 chroma 17 and tone
 * 60 chroma 30, measured in HCT), never the primary's own chroma, which made a loud board. The
 * overlays are one ink, the palette's dark tone, told apart by width, opacity and dashes; the
 * highlights the primary itself at a mid tone (Design/COLORS.md, Board).
 */
@Immutable
class BoardTheme internal constructor(private val theme: Theme) {
    private val primary = theme.boardTint.toHct()
    private val graphite = theme.appColor == AppColor.Graphite

    /** The primary's hue at [tone] with at most [chroma] (0 black, 100 white). */
    private fun tone(tone: Double, chroma: Double = primary.chroma): Color =
        Hct.from(primary.hue, minOf(primary.chroma, chroma), tone).toColor()

    val light: Color = if (theme.isDark) tone(76.0, 8.0) else tone(88.0, 10.0)
    val dark: Color = if (theme.isDark) tone(52.0, 16.0) else tone(62.0, 18.0)

    /**
     * The board's ink: the primary's hue at tone 28 (chroma at most 40), which every board shows
     * clearly. Your moves, the hint, the replies you cover and, dashed, the gaps; the check badge
     * in tinted themes.
     */
    val ink: Color = tone(28.0, 40.0)

    /** The check badge: Multicolor's correct color; tinted themes the ink. */
    val correct: Color = if (theme.appColor == AppColor.Multicolor) theme.color(ThemeColor.Role.Correct) else ink

    /** The cross badge. */
    val wrong: Color = theme.color(ThemeColor.Role.Wrong)

    /** The badges' glyph: white on its disc (SF Symbols' palette rendering in Swift). */
    val badgeGlyph: Color = Hues.White

    /**
     * The highlights' color: the primary's hue at a mid tone with at least a tonal-spot primary's
     * chroma (36), so it shows on the low-chroma squares.
     */
    private val mid = Hct.from(primary.hue, maxOf(primary.chroma, 36.0), if (theme.isDark) 50.0 else 58.0).toColor()

    /** The last move: the highlight color over the square (the ink for graphite, whose gray the board doesn't show). */
    val lastMove: Color = if (graphite) ink.copy(alpha = 0.25f) else mid.copy(alpha = 0.5f)

    /** The selected square. */
    val selected: Color = if (graphite) ink.copy(alpha = 0.4f) else mid.copy(alpha = 0.75f)

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
