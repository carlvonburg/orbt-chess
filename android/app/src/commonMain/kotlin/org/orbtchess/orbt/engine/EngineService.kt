package org.orbtchess.orbt.engine

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.orbtchess.orbt.core.Engine
import org.orbtchess.orbt.core.EngineFailure
import org.orbtchess.orbt.core.EngineKind
import org.orbtchess.orbt.core.EngineLines
import org.orbtchess.orbt.core.EngineListener
import org.orbtchess.orbt.core.Epd
import org.orbtchess.orbt.explorer.CloudEvalClient
import java.lang.ref.WeakReference

/**
 * The analysis board's engine, one for the app: the core (`Engine`) decides when Stockfish
 * searches and which evaluation to show; this starts it, fetches the Lichess cloud eval,
 * runs the core's timer and re-reads its lines when they change.
 * `apple/ORBT/Engine/EngineService.swift`. Used from the main thread; `scope` runs there.
 */
class EngineService(
    val network: EngineNetwork,
    private val defaults: EngineDefaults,
    private val scope: CoroutineScope = MainScope(),
) {
    var lines by mutableStateOf(EngineLines(emptyList(), 0u, null, false, null))
        private set
    /** The position the lines are for: start FEN and moves. */
    var analysed by mutableStateOf<Key?>(null)
        private set
    var name by mutableStateOf<String?>(null)
        private set
    var error by mutableStateOf<String?>(null)
        private set

    data class Key(val startFen: String, val moves: List<String>)

    private val core = Engine(EngineKind.STOCKFISH)
    private var wake: Job? = null
    private var refreshing = false

    init {
        core.setListener(Listener(this))
    }

    private val nowMs: ULong get() = System.currentTimeMillis().coerceAtLeast(0).toULong()

    /** Analyses the position after `moves` (UCI) from `startFen`. */
    fun analyse(key: Key, epd: Epd) {
        start()
        val settings = defaults.settings
        analysed = key
        schedule(core.analyse(key.startFen, key.moves, settings, nowMs))
        lines = core.lines()
        if (!settings.cloud) return
        scope.launch {
            val eval = CloudEvalClient.fetch(epd)
            if (analysed != key) return@launch
            schedule(core.onCloud(epd, eval, nowMs))
            lines = core.lines()
        }
    }

    /** Stops analysing (leaving the board, or the engine turned off). */
    fun stop() {
        wake?.cancel()
        core.stop()
        analysed = null
        lines = core.lines()
    }

    /** Ends Stockfish (the app is closing); the next `analyse` starts it again. */
    fun quit() {
        wake?.cancel()
        core.quit()
        analysed = null
        lines = core.lines()
    }

    /**
     * Starts Stockfish with the full network when it is downloaded and wanted, else the light
     * one; a running engine with the same network is kept.
     */
    private fun start() {
        val full = if (defaults.fullNetwork) network.path else null
        try {
            core.start(full)
            error = null
        } catch (failure: EngineFailure) {
            error = (failure as? EngineFailure.Failed)?.v1 ?: failure.message
            if (full != null) runCatching { core.start(null) }
        }
        name = core.name()
    }

    private fun schedule(wakeAt: ULong?) {
        wake?.cancel()
        if (wakeAt == null) return
        wake = scope.launch {
            val delayMs = wakeAt.toLong() - nowMs.toLong()
            if (delayMs > 0) delay(delayMs)
            schedule(core.poll(nowMs))
            lines = core.lines()
        }
    }

    /** The engine printed lines: re-read them at most ten times a second. */
    private fun changed() {
        if (refreshing) return
        refreshing = true
        scope.launch {
            delay(100)
            refreshing = false
            lines = core.lines()
        }
    }

    /** Called on the engine's thread; hops to the main thread. */
    private class Listener(service: EngineService) : EngineListener {
        private val service = WeakReference(service)
        override fun changed() {
            val service = service.get() ?: return
            service.scope.launch { service.changed() }
        }
    }
}
