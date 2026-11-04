package org.orbtchess.orbt.ui.components

import org.orbtchess.orbt.core.SchedTiming
import org.orbtchess.orbt.core.schedTiming
import org.orbtchess.orbt.platform.Settings
import org.orbtchess.orbt.platform.StoreReview

/**
 * Asks for a rating once the user has studied on three different days (`ReviewPrompt` in
 * Swift): after saving in Browse, or at the end of a line in Study. Once per app version; the
 * store decides whether its prompt shows. Without a store (the desktop) it never asks. Settings links to the store's page at any time.
 */
class ReviewPrompt(private val settings: Settings, private val store: StoreReview?) {
    private val days: List<Long>
        get() = settings.getString(DAYS_KEY)?.split(',')?.mapNotNull { it.toLongOrNull() } ?: emptyList()

    /** A move answered in Study: today counts as a day studied. */
    fun studied(timing: SchedTiming = schedTiming()) {
        val days = days
        val today = timing.daysElapsed
        if (days.size >= DAYS_NEEDED || today in days) return
        settings.putString(DAYS_KEY, (days + today).joinToString(","))
    }

    val isDue: Boolean
        get() = store != null &&
            days.size >= DAYS_NEEDED &&
            settings.getString(ASKED_VERSION_KEY) != store.version

    /** Asks for a rating when it is due. */
    fun ask() {
        if (!isDue) return
        val store = store ?: return
        settings.putString(ASKED_VERSION_KEY, store.version)
        store.request()
    }

    companion object {
        const val DAYS_KEY = "reviewPromptDays"
        const val ASKED_VERSION_KEY = "reviewPromptAskedVersion"
        const val DAYS_NEEDED = 3
    }
}
