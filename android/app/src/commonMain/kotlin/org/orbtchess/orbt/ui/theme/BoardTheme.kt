package org.orbtchess.orbt.ui.theme

import androidx.compose.runtime.Immutable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp

/**
 * The board for a theme (`BoardTheme` in Palette.swift): content with its own colors, the same
 * in the app's light and dark appearance (dimmer squares in dark), its squares tinted toward the
 * app color, its overlays one ink told apart by width, opacity and dashes. Design/COLORS.md,
 * "Board", has the table and the measurements.
 */
@Immutable
class BoardTheme internal constructor(private val theme: Theme) {
    private val tint = theme.boardTint
    private val graphite = theme.appColor == AppColor.Graphite

    val light: Color = lerp(if (theme.isDark) Hues.BoardLightDim else Hues.BoardLight, tint, 0.14f)
    val dark: Color = lerp(if (theme.isDark) Hues.BoardDarkDim else Hues.BoardDark, tint, 0.28f)

    /**
     * The board's ink: the app color mixed 55% toward black, which every board shows clearly (a
     * board swallows its own hue). Your moves, the hint, the replies you cover and, dashed, the
     * gaps; the check badge in tinted themes.
     */
    val ink: Color = lerp(tint, Hues.Black, 0.55f)

    /** The check badge: Multicolor's correct color; tinted themes the ink. */
    val correct: Color = if (theme.appColor == AppColor.Multicolor) theme.color(ThemeColor.Role.Correct) else ink

    /** The cross badge. */
    val wrong: Color = theme.color(ThemeColor.Role.Wrong)

    /** The badges' glyph: white on its disc (SF Symbols' palette rendering in Swift). */
    val badgeGlyph: Color = Hues.White

    /** The last move: the app color over the square (the ink for graphite, whose gray the board doesn't show). */
    val lastMove: Color = if (graphite) ink.copy(alpha = 0.25f) else tint.copy(alpha = 0.5f)

    /** The selected square. */
    val selected: Color = if (graphite) ink.copy(alpha = 0.4f) else tint.copy(alpha = 0.75f)

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
