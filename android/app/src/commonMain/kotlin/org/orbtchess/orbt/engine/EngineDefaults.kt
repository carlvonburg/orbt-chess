package org.orbtchess.orbt.engine

import org.orbtchess.orbt.core.EngineSettings
import org.orbtchess.orbt.core.defaultEngineSettings
import org.orbtchess.orbt.core.maxEngineLines
import org.orbtchess.orbt.platform.Settings

/**
 * The analysis engine's settings, edited in Settings (as Lichess's "Search time" and
 * "Multiple lines"). `apple/ORBT/Storage/EngineDefaults.swift`.
 */
class EngineDefaults(private val store: Settings, private val processors: Int) {
    companion object {
        const val SEARCH_TIME_KEY = "engine.searchTime"
        const val LINES_KEY = "engine.lines"
        const val CLOUD_KEY = "engine.cloud"
        const val FULL_NETWORK_KEY = "engine.fullNetwork"

        val searchTimes = 1..30
        val lineCounts by lazy { 1..maxEngineLines().toInt() }
    }

    /** Seconds per position. */
    var searchTime: Int
        get() = store.getInt(SEARCH_TIME_KEY) ?: 6
        set(value) = store.putInt(SEARCH_TIME_KEY, value)

    var lines: Int
        get() = store.getInt(LINES_KEY) ?: 3
        set(value) = store.putInt(LINES_KEY, value)

    /** Show Lichess's cloud eval first, and skip the engine where it is deep. */
    var cloud: Boolean
        get() = store.getBoolean(CLOUD_KEY) ?: true
        set(value) = store.putBoolean(CLOUD_KEY, value)

    /** Use the full network once it is downloaded. */
    var fullNetwork: Boolean
        get() = store.getBoolean(FULL_NETWORK_KEY) ?: true
        set(value) = store.putBoolean(FULL_NETWORK_KEY, value)

    /** Half the cores, at most four: fast, without draining a phone's battery. */
    val threads: Int get() = minOf(4, maxOf(1, processors / 2))

    val settings: EngineSettings
        get() = defaultEngineSettings().apply {
            lines = this@EngineDefaults.lines.coerceIn(lineCounts).toUInt()
            movetimeMs = (searchTime.coerceIn(searchTimes) * 1000).toUInt()
            threads = this@EngineDefaults.threads.toUInt()
            cloud = this@EngineDefaults.cloud
        }
}
