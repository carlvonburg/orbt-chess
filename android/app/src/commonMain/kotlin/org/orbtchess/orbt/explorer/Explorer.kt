package org.orbtchess.orbt.explorer

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.sqlite.SQLiteConnection
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import androidx.sqlite.execSQL
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.orbtchess.orbt.core.CloudEval
import org.orbtchess.orbt.core.CloudEvalLookup
import org.orbtchess.orbt.core.CloudEvals
import org.orbtchess.orbt.core.Epd
import org.orbtchess.orbt.core.Explorer
import org.orbtchess.orbt.core.ExplorerListener
import org.orbtchess.orbt.core.Fetch
import org.orbtchess.orbt.core.QueueState
import org.orbtchess.orbt.core.StatsStore
import org.orbtchess.orbt.core.StoredStats
import org.orbtchess.orbt.core.databaseCacheKey
import org.orbtchess.orbt.platform.Http
import org.orbtchess.orbt.platform.Settings
import java.io.File
import java.lang.ref.WeakReference
import java.util.logging.Logger

/**
 * Cloud evaluations from lichess.org (no token needed). The request, the answer and the
 * session cache (a 404 is remembered, other failures are asked again) are in the core.
 */
object CloudEvalClient {
    private val core = CloudEvals()

    suspend fun fetch(epd: Epd): CloudEval? = when (val lookup = core.lookup(epd)) {
        is CloudEvalLookup.Cached -> lookup.v1
        is CloudEvalLookup.Fetch -> core.onResponse(epd, Http.send(lookup.v1))
    }
}

/**
 * Local, unsynced store of explorer stats keyed by (database, EPD), for the Rust core's
 * cache: SQLite in the app's support folder (SwiftData on Apple). It can always be re-fetched,
 * so it is not stored with the repertoires. The core loads a database's entries once and keeps
 * them in memory.
 *
 * The core calls it from whichever thread called into the core (often while it holds a
 * document's lock), so it uses its own connection behind a lock and never hops to another thread.
 */
class ExplorerCacheStore(private val file: File) : StatsStore {
    private val lock = Any()
    private var storedConnection: SQLiteConnection? = null

    /** Runs `body` with the connection, one caller at a time. */
    private fun <T> withConnection(body: (SQLiteConnection) -> T): T = synchronized(lock) {
        val connection = storedConnection ?: run {
            val driver = BundledSQLiteDriver()
            val opened = try {
                file.parentFile?.mkdirs()
                driver.open(file.path).also(::createSchema)
            } catch (e: Exception) {
                log.severe("explorer cache ${file.path}: $e")
                driver.open(":memory:").also(::createSchema)
            }
            opened.also { storedConnection = it }
        }
        body(connection)
    }

    private fun createSchema(connection: SQLiteConnection) {
        connection.execSQL(
            "CREATE TABLE IF NOT EXISTS entry (database TEXT NOT NULL, epd TEXT NOT NULL, " +
                "payload BLOB NOT NULL, fetched_at INTEGER NOT NULL, PRIMARY KEY (database, epd))",
        )
    }

    override fun load(databaseKey: String): List<StoredStats> = withConnection { connection ->
        try {
            connection.prepare("SELECT epd, payload FROM entry WHERE database = ?").use { statement ->
                statement.bindText(1, databaseKey)
                buildList {
                    while (statement.step()) add(StoredStats(statement.getText(0), statement.getBlob(1)))
                }
            }
        } catch (e: Exception) {
            log.severe("explorer cache load: $e")
            emptyList()
        }
    }

    override fun save(databaseKey: String, epd: Epd, json: ByteArray) = withConnection { connection ->
        try {
            connection.prepare("INSERT OR REPLACE INTO entry (database, epd, payload, fetched_at) VALUES (?, ?, ?, ?)")
                .use { statement ->
                    statement.bindText(1, databaseKey)
                    statement.bindText(2, epd)
                    statement.bindBlob(3, json)
                    statement.bindLong(4, System.currentTimeMillis())
                    statement.step()
                }
        } catch (e: Exception) {
            log.severe("explorer cache save: $e")
        }
        Unit
    }

    val entryCount: Int
        get() = withConnection { connection ->
            try {
                connection.prepare("SELECT COUNT(*) FROM entry").use { if (it.step()) it.getInt(0) else 0 }
            } catch (_: Exception) {
                0
            }
        }

    fun clear() = withConnection { connection ->
        try {
            connection.execSQL("DELETE FROM entry")
        } catch (e: Exception) {
            log.severe("explorer cache clear: $e")
        }
    }

    /** Closes the connection; the next call opens it again. */
    fun close() = synchronized(lock) {
        storedConnection?.close()
        storedConnection = null
    }

    companion object {
        /** The store's file in the app's support folder. */
        fun inFolder(support: File) = ExplorerCacheStore(File(support, "ExplorerCache.sqlite"))

        private val log = Logger.getLogger("org.orbtchess.orbt.explorer")
    }
}

/**
 * Runs the core's explorer queue: sends the requests it hands out (the core adds the
 * Lichess token) and reports the answers. The rules (300 ms focus, one paced coverage request at a
 * time, the shared 429 pause, offline retry, 401) are in the core.
 *
 * `token` gives the Lichess token (or null when signed out); [tokenRejected] tells the sign-in
 * that Lichess answered 401. `scope` runs on the main thread: every core call here is made there.
 */
class ExplorerService(
    val store: ExplorerCacheStore,
    private val settings: Settings,
    private val token: () -> String?,
    private val scope: CoroutineScope = MainScope(),
) {
    var state: QueueState by mutableStateOf(QueueState.Idle)
        private set

    val core: Explorer
    private var wake: Job? = null

    private val rejected = MutableSharedFlow<Unit>(extraBufferCapacity = 1, onBufferOverflow = BufferOverflow.DROP_OLDEST)

    /**
     * Lichess rejected the token (401: revoked or expired): the sign-in clears it and asks to
     * sign in again. Collect it from launch: an answer nobody collects is dropped.
     */
    val tokenRejected: SharedFlow<Unit> = rejected.asSharedFlow()

    init {
        val bannedUntil = settings.getLong(BANNED_UNTIL_KEY)
        // The setting `explorerInterval` (seconds) overrides the pace for testing.
        val override = settings.getString(INTERVAL_KEY)?.toDoubleOrNull() ?: 0.0
        core = Explorer(store, bannedUntil, if (override > 0) (override * 1000).toLong() else null)
        core.setListener(Listener(this))
    }

    val remaining: Int get() = core.remaining().toInt()

    /** Call after signing in or when the network is back. */
    fun resume() = core.resume()

    /** Sends what the queue hands out and sleeps until it wants to be asked again. */
    fun pump() {
        val poll = core.poll(millis(), token())
        state = core.state()
        for (fetch in poll.fetches) {
            scope.launch { perform(fetch) }
        }
        wake?.cancel()
        wake = poll.wakeAt?.let { wakeAt ->
            scope.launch {
                val delay = wakeAt - millis()
                if (delay > 0) delay(delay)
                if (isActive) pump()
            }
        }
    }

    private suspend fun perform(fetch: Fetch) {
        val started = System.nanoTime()
        val response = Http.send(fetch.request)
        log.info(
            "explorer ${databaseCacheKey(fetch.database)} ${response?.status?.toString() ?: "offline"} in " +
                "${(System.nanoTime() - started) / 1_000_000} ms, $remaining queued",
        )
        val outcome = core.onResponse(fetch, response, millis())
        if (outcome.unauthorized) rejected.tryEmit(Unit)
        outcome.bannedUntil?.let { until ->
            settings.putLong(BANNED_UNTIL_KEY, until)
            log.severe("explorer 429, paused until $until")
        }
        state = core.state()
    }

    /** The core asks to be polled from any thread; hop to the main thread so it is not re-entered. */
    private class Listener(service: ExplorerService) : ExplorerListener {
        private val service = WeakReference(service)
        override fun wake() {
            val service = service.get() ?: return
            service.scope.launch { service.pump() }
        }
    }

    companion object {
        /** The end of a ban, kept across launches: a relaunch must not restart Lichess's penalty. */
        const val BANNED_UNTIL_KEY = "explorerBannedUntil"
        const val INTERVAL_KEY = "explorerInterval"
        private val log = Logger.getLogger("org.orbtchess.orbt.explorer")

        fun millis(): Long = System.currentTimeMillis()
    }
}
