package org.orbtchess.orbt.sync

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.orbtchess.orbt.core.Explorer
import org.orbtchess.orbt.core.Header
import org.orbtchess.orbt.core.HttpRequest
import org.orbtchess.orbt.core.HttpResponse
import org.orbtchess.orbt.core.Side
import org.orbtchess.orbt.core.StatsStore
import org.orbtchess.orbt.core.StoredStats
import org.orbtchess.orbt.core.SyncState
import org.orbtchess.orbt.core.databaseDefaultLichess
import org.orbtchess.orbt.core.defaultStudyDefaults
import org.orbtchess.orbt.core.newSidecar
import org.orbtchess.orbt.core.nowTimestamp
import org.orbtchess.orbt.platform.SecretStore
import org.orbtchess.orbt.platform.Settings
import org.orbtchess.orbt.storage.Documents
import org.orbtchess.orbt.storage.FileAccess
import org.orbtchess.orbt.storage.ROOT_NODE
import org.orbtchess.orbt.storage.RepertoireLibrary
import java.io.File
import java.nio.file.Files
import java.util.concurrent.Executors
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * `SyncService` with the core's real `RepertoireSync` against a fake Dropbox (the requests the
 * core builds, answered by URL), over a temporary folder. One thread stands in for the main
 * thread; the tests wait for the sync to settle.
 */
class SyncServiceTest {
    companion object {
        init {
            if (System.getProperty("jna.library.path") == null) {
                generateSequence(File("").absoluteFile) { it.parentFile }
                    .map { File(it, "core/build/host") }
                    .firstOrNull { it.isDirectory }
                    ?.let { System.setProperty("jna.library.path", it.path) }
            }
        }
    }

    private lateinit var root: File
    private lateinit var folder: File
    private val executor = Executors.newSingleThreadExecutor()
    private val main = executor.asCoroutineDispatcher()
    private val scope = CoroutineScope(SupervisorJob() + main)
    private val server = FakeDropbox()

    @BeforeTest
    fun setUp() {
        root = Files.createTempDirectory("orbt-sync").toFile()
        folder = File(root, "Repertoires").apply { mkdirs() }
    }

    @AfterTest
    fun tearDown() {
        scope.cancel()
        FileAccess.observer = null
        executor.shutdown()
        root.deleteRecursively()
    }

    private class MemoryStore : StatsStore {
        override fun load(databaseKey: String): List<StoredStats> = emptyList()
        override fun save(databaseKey: String, epd: String, json: ByteArray) {}
    }

    private class MemorySettings : Settings, SecretStore {
        private val values = mutableMapOf<String, Any>()
        override fun getInt(key: String) = values[key] as? Int
        override fun putInt(key: String, value: Int) { values[key] = value }
        override fun getLong(key: String) = values[key] as? Long
        override fun putLong(key: String, value: Long) { values[key] = value }
        override fun getBoolean(key: String) = values[key] as? Boolean
        override fun putBoolean(key: String, value: Boolean) { values[key] = value }
        override fun getString(key: String) = values[key] as? String
        override fun putString(key: String, value: String) { values[key] = value }
        override fun get(key: String) = getString(key)
        override fun set(key: String, value: String) = putString(key, value)
        override fun remove(key: String) { values.remove(key) }
    }

    /** Signs in to the fake Dropbox at once. */
    private class FakeAuth : SyncAuth {
        override val providers = listOf(SyncProvider.Dropbox)
        override val dropboxAppKey = "app-key"
        override suspend fun signIn(provider: SyncProvider) =
            SyncCredentials(accessToken = FakeDropbox.TOKEN, refreshToken = FakeDropbox.REFRESH, account = "me@example.com")
        override suspend fun token(provider: SyncProvider, rejected: String?): SyncCredentials? = null
        override suspend fun signOut(provider: SyncProvider, credentials: SyncCredentials?) {}
    }

    private class App(val documents: Documents, val sync: SyncService)

    /** The app's services over the folder, started on the main thread. */
    private suspend fun app(): App = onMain {
        val settings = MemorySettings()
        val library = RepertoireLibrary(folder, scope)
        library.setUp()
        val documents = Documents(library, Explorer(MemoryStore(), null, null), { defaultStudyDefaults() }, scope)
        val sync = SyncService(
            folder, root, settings, settings, FakeAuth(), documents,
            send = { server.handle(it) }, scope = scope,
        )
        sync.start()
        App(documents, sync)
    }

    private suspend fun <T> onMain(body: suspend () -> T): T = withContext(main) { body() }

    /** Waits (on the main thread) until `condition` holds. */
    private suspend fun until(what: String, condition: () -> Boolean) {
        repeat(500) {
            if (onMain { condition() }) return
            delay(20)
        }
        fail("Timed out waiting until $what")
    }

    /** Waits until the sync has nothing left to do. */
    private suspend fun settled(app: App) = until("synced") {
        app.sync.state == SyncState.Idle && app.sync.unsynced.isEmpty() && !server.busy
    }

    private fun sidecar(): ByteArray = newSidecar("test", Side.WHITE, databaseDefaultLichess(), 100, nowTimestamp())

    private fun local(name: String) = File(folder, name).readBytes()

    @Test
    fun firstSyncUploadsTheLocalFiles(): Unit = runBlocking {
        val app = app()
        onMain { app.documents.library.create("Italian", sidecar()) }
        assertTrue(onMain { app.sync.signIn(SyncProvider.Dropbox) })
        settled(app)
        assertEquals(SyncProvider.Dropbox, app.sync.provider)
        assertEquals("me@example.com", app.sync.account)
        assertContentEquals(local("Italian.pgn"), server.files.getValue("Italian.pgn").data)
        assertContentEquals(local("Italian.otrep.json"), server.files.getValue("Italian.otrep.json").data)
        // The state names what was uploaded.
        assertTrue(File(root, "Sync-dropbox.json").readText().contains("Italian.pgn"))
    }

    @Test
    fun aRemoteChangeIsWrittenAndHandedToTheOpenDocument(): Unit = runBlocking {
        val app = app()
        val entry = onMain { app.documents.library.create("Italian", sidecar()) }
        onMain { app.sync.signIn(SyncProvider.Dropbox) }
        settled(app)
        val doc = assertNotNull(onMain { app.documents.open(entry) })

        // Another device adds a move, and a repertoire.
        server.put("Italian.pgn", "[Event \"Italian\"]\n\n1. e4 e5 *\n".toByteArray())
        server.put("Najdorf.pgn", "[Event \"Najdorf\"]\n\n1. e4 c5 *\n".toByteArray())
        onMain { app.sync.syncNow() }
        until("the move is in the document") { doc.tree.childByUci(ROOT_NODE, "e2e4") != null }
        until("the new repertoire is in the library") { app.documents.library.entries.any { it.name == "Najdorf" } }
        settled(app)
        assertTrue(local("Italian.pgn").toString(Charsets.UTF_8).contains("e4 e5"))
        assertContentEquals(server.files.getValue("Najdorf.pgn").data, local("Najdorf.pgn"))
        // The sync's own writes are not sent back.
        assertEquals(0, server.uploads.count { it == "Najdorf.pgn" })
    }

    @Test
    fun aLocalSaveIsUploaded(): Unit = runBlocking {
        val app = app()
        val entry = onMain { app.documents.library.create("Italian", sidecar()) }
        onMain { app.sync.signIn(SyncProvider.Dropbox) }
        settled(app)
        val doc = assertNotNull(onMain { app.documents.open(entry) })
        onMain {
            doc.addMove("d2d4", ROOT_NODE)
            doc.flush()
        }
        until("the save is uploaded") { server.files.getValue("Italian.pgn").data.contentEquals(local("Italian.pgn")) }
        settled(app)
        assertTrue(server.files.getValue("Italian.pgn").data.toString(Charsets.UTF_8).contains("d4"))
    }

    @Test
    fun editsMadeOfflineUploadWhenTheNetworkIsBack(): Unit = runBlocking {
        val app = app()
        val entry = onMain { app.documents.library.create("Italian", sidecar()) }
        onMain { app.sync.signIn(SyncProvider.Dropbox) }
        settled(app)
        val doc = assertNotNull(onMain { app.documents.open(entry) })

        server.offline = true
        onMain {
            doc.addMove("c2c4", ROOT_NODE)
            doc.flush()
        }
        until("offline") { app.sync.state is SyncState.Offline }
        assertTrue("Italian.pgn" in onMain { app.sync.unsynced })

        server.offline = false
        onMain { app.sync.networkAvailable() }
        settled(app)
        assertTrue(server.files.getValue("Italian.pgn").data.toString(Charsets.UTF_8).contains("c4"))
    }

    @Test
    fun aRevokedSignInAsksToSignInAgain(): Unit = runBlocking {
        val app = app()
        onMain { app.documents.library.create("Italian", sidecar()) }
        onMain { app.sync.signIn(SyncProvider.Dropbox) }
        settled(app)

        // The user removed the app in Dropbox: every token is refused.
        server.revoke()
        onMain { app.sync.syncNow() }
        until("asked to sign in") { app.sync.needsSignIn }
        assertEquals(SyncState.NeedsSignIn, onMain { app.sync.state })

        // Signing in again goes on syncing.
        server.restore()
        assertTrue(onMain { app.sync.signIn(SyncProvider.Dropbox) })
        settled(app)
        assertTrue(!onMain { app.sync.needsSignIn })
    }

    @Test
    fun signingOutKeepsTheFiles(): Unit = runBlocking {
        val app = app()
        onMain { app.documents.library.create("Italian", sidecar()) }
        onMain { app.sync.signIn(SyncProvider.Dropbox) }
        settled(app)
        onMain { app.sync.signOut() }
        // Revoked on the server, not only forgotten here.
        assertTrue(server.revoked)
        assertNull(app.sync.provider)
        assertTrue(File(folder, "Italian.pgn").exists())
        assertTrue(server.files.containsKey("Italian.pgn"))
        assertTrue(!File(root, "Sync-dropbox.json").exists())
    }
}

/**
 * A fake Dropbox App folder answering the core's requests by URL (as the core's own test,
 * `orbt-core/tests/sync.rs`): revs counting up, conditional uploads and deletes.
 */
private class FakeDropbox {
    class Stored(val data: ByteArray, val rev: String)

    val files = java.util.concurrent.ConcurrentHashMap<String, Stored>()
    /** The names uploaded, in order. */
    val uploads = java.util.Collections.synchronizedList(mutableListOf<String>())
    @Volatile var offline = false
    @Volatile var busy = false
    @Volatile private var access = TOKEN
    /** Signed out with `auth/token/revoke`. */
    @Volatile var revoked = false
    @Volatile private var refresh = REFRESH
    private var nextRev = 0

    fun put(name: String, data: ByteArray): String = synchronized(this) {
        nextRev += 1
        val rev = "%09x".format(nextRev)
        files[name] = Stored(data, rev)
        rev
    }

    fun revoke() {
        access = "revoked"
        refresh = "revoked"
    }

    fun restore() {
        access = TOKEN
        refresh = REFRESH
    }

    fun handle(request: HttpRequest): HttpResponse? {
        if (offline) return null
        busy = true
        try {
            return answer(request)
        } finally {
            busy = false
        }
    }

    private fun answer(r: HttpRequest): HttpResponse {
        val endpoint = r.url.substringAfter(".com")
        val body = r.body.toString(Charsets.UTF_8)
        if (endpoint == "/oauth2/token") {
            return if ("refresh_token=$refresh" in body && refresh != "revoked") {
                respond(200, """{"access_token": "$access", "expires_in": 14400, "token_type": "bearer"}""")
            } else {
                respond(400, """{"error": "invalid_grant"}""")
            }
        }
        if (endpoint == "/2/files/list_folder/longpoll") return respond(200, """{"changes": false}""")
        if (header(r, "Authorization") != "Bearer $access" || access == "revoked") {
            return respond(401, """{"error_summary": "invalid_access_token/"}""")
        }
        if (endpoint == "/2/auth/token/revoke") {
            revoked = true
            revoke()
            return respond(200, "null")
        }
        val arg = header(r, "Dropbox-API-Arg") ?: body
        val name = field(arg, "path")?.removePrefix("/")
        return when (endpoint) {
            "/2/files/list_folder", "/2/files/list_folder/continue" -> {
                val entries = files.entries.sortedBy { it.key }.joinToString(",") { (n, f) ->
                    """{".tag": "file", "name": "$n", "rev": "${f.rev}", "id": "id:$n"}"""
                }
                respond(200, """{"entries": [$entries], "cursor": "c$nextRev", "has_more": false}""")
            }
            "/2/files/download" -> files[name]?.let { f ->
                respond(200, f.data, Header("Dropbox-API-Result", """{"name": "$name", "rev": "${f.rev}"}"""))
            } ?: conflict("path/not_found/")
            "/2/files/upload" -> {
                val current = files[name!!]?.rev
                val ok = when (Regex("\"\\.tag\":\\s*\"(\\w+)\"").find(arg)?.groupValues?.get(1)) {
                    "add" -> current == null
                    "update" -> current != null && current == field(arg, "update")
                    else -> false
                }
                if (!ok) return conflict("path/conflict/file/..")
                uploads += name
                val rev = put(name, r.body)
                respond(200, """{"name": "$name", "rev": "$rev"}""")
            }
            "/2/files/delete_v2" -> {
                val current = files[name!!] ?: return conflict("path_lookup/not_found/")
                if (current.rev != field(arg, "parent_rev")) return conflict("path_lookup/conflict/")
                files.remove(name)
                respond(200, "{}")
            }
            else -> error("unexpected endpoint $endpoint")
        }
    }

    companion object {
        const val TOKEN = "access"
        const val REFRESH = "refresh"

        fun header(r: HttpRequest, name: String) = r.headers.firstOrNull { it.name.equals(name, ignoreCase = true) }?.value

        /** A string field of the request's JSON (the fake's names are plain ASCII). */
        fun field(json: String, name: String) = Regex("\"$name\":\\s*\"([^\"]*)\"").find(json)?.groupValues?.get(1)

        fun respond(status: Int, body: String, vararg headers: Header) = respond(status, body.toByteArray(), *headers)

        fun respond(status: Int, body: ByteArray, vararg headers: Header) =
            HttpResponse(status.toUShort(), headers.toList(), body)

        fun conflict(summary: String) = respond(409, """{"error_summary": "$summary", "error": {".tag": "path"}}""")
    }
}
