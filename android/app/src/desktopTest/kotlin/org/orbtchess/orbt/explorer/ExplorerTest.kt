package org.orbtchess.orbt.explorer

import com.sun.net.httpserver.HttpServer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.orbtchess.orbt.core.ExplorerDatabase
import org.orbtchess.orbt.core.ExplorerSpeed
import org.orbtchess.orbt.core.QueueState
import org.orbtchess.orbt.platform.Settings
import java.io.File
import java.net.InetSocketAddress
import java.nio.file.Files
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

private class MemorySettings : Settings {
    val values = mutableMapOf<String, Any>()
    override fun getInt(key: String) = values[key] as? Int
    override fun putInt(key: String, value: Int) { values[key] = value }
    override fun getLong(key: String) = values[key] as? Long
    override fun putLong(key: String, value: Long) { values[key] = value }
    override fun getBoolean(key: String) = values[key] as? Boolean
    override fun putBoolean(key: String, value: Boolean) { values[key] = value }
    override fun getString(key: String) = values[key] as? String
    override fun putString(key: String, value: String) { values[key] = value }
    override fun remove(key: String) { values.remove(key) }
}

private fun rapid(rating: Long) = ExplorerDatabase.Lichess(listOf(rating), listOf(ExplorerSpeed.RAPID))

class ExplorerTest {
    private lateinit var folder: File
    private lateinit var scope: CoroutineScope

    @BeforeTest
    fun setUp() {
        folder = Files.createTempDirectory("orbt-explorer").toFile()
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    }

    @AfterTest
    fun tearDown() {
        scope.cancel()
        folder.deleteRecursively()
    }

    @Test
    fun statsStoreRoundTrip() {
        val epd = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq -"
        val store = ExplorerCacheStore.inFolder(folder)
        store.save("masters", epd, "{\"a\":1}".toByteArray())
        store.save("masters", "other", byteArrayOf(1, 2, 3))
        store.save("lichess", epd, byteArrayOf(9))
        store.save("masters", epd, "{\"a\":2}".toByteArray())
        store.close()

        val reopened = ExplorerCacheStore.inFolder(folder)
        assertEquals(3, reopened.entryCount)
        val masters = reopened.load("masters").associate { it.epd to it.json }
        assertEquals(setOf(epd, "other"), masters.keys)
        assertContentEquals("{\"a\":2}".toByteArray(), masters[epd])
        assertContentEquals(byteArrayOf(1, 2, 3), masters["other"])
        assertEquals(1, reopened.load("lichess").size)
        assertTrue(reopened.load("none").isEmpty())

        reopened.clear()
        assertEquals(0, reopened.entryCount)
        reopened.close()
    }

    @Test
    fun anIdleQueueFetchesNothing() {
        val service = ExplorerService(ExplorerCacheStore.inFolder(folder), MemorySettings(), { null }, scope)
        service.pump()
        assertEquals(QueueState.Idle, service.state)
        assertEquals(0, service.remaining)
    }

    @Test
    fun downloadsVerifiesAndKeepsTheManifest() = runBlocking {
        // "abc" matches the first file's size and hash; the second file's hash is wrong.
        val manifest = """{"version":1,"files":[
          {"file":"rapid_2000-2199_1in800.otcb.zst","database":{"lichess":{"ratings":[2000],"speeds":["rapid"]}},"targetGames":800,"bytes":3,"sha256":"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"},
          {"file":"rapid_1600-1799_1in800.otcb.zst","database":{"lichess":{"ratings":[1600],"speeds":["rapid"]}},"targetGames":800,"bytes":3,"sha256":"00"}
        ]}"""
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/") { exchange ->
            val body = when (exchange.requestURI.path) {
                "/manifest.json" -> manifest.toByteArray()
                else -> "abc".toByteArray()
            }
            exchange.sendResponseHeaders(200, body.size.toLong())
            exchange.responseBody.use { it.write(body) }
        }
        server.start()
        try {
            val service = ExplorerService(ExplorerCacheStore.inFolder(folder), MemorySettings(), { null }, scope)
            val tables = CoverageTables(service, folder, "http://127.0.0.1:${server.address.port}/", scope)
            tables.setUp(appFolder = null)
            assertEquals(2, tables.available.size)
            assertEquals(listOf(rapid(2000), rapid(1600)), tables.selections)
            assertTrue(File(tables.directory, "manifest.json").exists())

            val good = assertNotNull(tables.file(rapid(2000)))
            tables.download(good)
            assertNull(tables.failures[good.file])
            assertContentEquals("abc".toByteArray(), File(tables.directory, good.file).readBytes())
            // Not a real table: kept on disk, not loaded.
            assertFalse(tables.isReady(rapid(2000)))
            assertTrue(tables.downloads.isEmpty())

            val bad = assertNotNull(tables.file(rapid(1600)))
            tables.download(bad)
            assertNotNull(tables.failures[bad.file])
            assertFalse(File(tables.directory, bad.file).exists())
            assertTrue(tables.directory.listFiles()!!.none { it.name.endsWith(".part") })

            // The saved manifest is read on the next launch, before the server answers.
            server.stop(0)
            val offline = CoverageTables(service, folder, "http://127.0.0.1:${server.address.port}/", scope)
            offline.setUp(appFolder = null)
            assertEquals(2, offline.available.size)
        } finally {
            server.stop(0)
        }
    }

    @Test
    fun mastersHasNoTable() {
        val service = ExplorerService(ExplorerCacheStore.inFolder(folder), MemorySettings(), { null }, scope)
        val tables = CoverageTables(service, folder, "http://127.0.0.1:1/", scope)
        tables.want(ExplorerDatabase.Masters)
        assertTrue(tables.downloads.isEmpty())
        assertNull(tables.file(ExplorerDatabase.Masters))
    }
}
