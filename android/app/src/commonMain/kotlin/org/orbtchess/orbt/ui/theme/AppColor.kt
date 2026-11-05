package org.orbtchess.orbt.ui.theme

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import org.orbtchess.orbt.platform.Settings

/**
 * The app's color, chosen in Settings (`AppColor` in `apple/ORBT/UI/Components/Palette.swift`):
 * the tint of every control (the color scheme's primary), the board's tint and, except for
 * Multicolor, the color of the meanings (Design/COLORS.md).
 *
 * Multicolor is Material You on Android 12 and later (the wallpaper's colors, the system's
 * dynamic color), with the meanings in their own colors (Anki's for studying); elsewhere it is
 * blue. Every other app color is a fixed seed for a Material color scheme.
 */
enum class AppColor(
    /** The seed of the color scheme, the board's tint (Apple's system color of that name). */
    val seed: Color,
) {
    Multicolor(Hues.Blue),
    Blue(Hues.Blue),
    Indigo(Hues.Indigo),
    Purple(Hues.Purple),
    Pink(Hues.Pink),
    Red(Hues.Red),
    Orange(Hues.Orange),
    Yellow(Hues.Yellow),
    Green(Hues.Green),
    Graphite(Hues.Gray),
    ;

    val title: String get() = name

    /** The value stored in the settings, the same as the Swift app's (`multicolor`, `blue`, ...). */
    val key: String get() = name.lowercase()

    companion object {
        /** The settings key, as on Apple. */
        const val SETTINGS_KEY = "appColor"
        val Default = Multicolor

        fun fromKey(key: String?): AppColor = entries.firstOrNull { it.key == key } ?: Default
    }
}

/**
 * The app color setting, stored in the platform settings and read by the theme. Settings
 * changes it (`LocalAppColorSetting.current.appColor = ...`); the theme redraws.
 */
@Stable
class AppColorSetting(private val settings: Settings) {
    var appColor: AppColor by mutableStateOf(AppColor.fromKey(settings.getString(AppColor.SETTINGS_KEY)))
        private set

    fun select(color: AppColor) {
        appColor = color
        settings.putString(AppColor.SETTINGS_KEY, color.key)
    }
}

/** The app color setting, for Settings (provided by `App`). */
val LocalAppColorSetting = staticCompositionLocalOf<AppColorSetting> { error("No AppColorSetting provided") }
