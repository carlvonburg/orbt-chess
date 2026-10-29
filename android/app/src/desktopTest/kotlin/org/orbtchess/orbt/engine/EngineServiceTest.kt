package org.orbtchess.orbt.engine

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.orbtchess.orbt.core.EvalSource
import org.orbtchess.orbt.core.Position
import org.orbtchess.orbt.platform.AppFolders
import org.orbtchess.orbt.platform.Settings
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Settings in memory. */
class MemorySettings : Settings {
    private val values = mutableMapOf<String, Any>()
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

class EngineServiceTest {
    private fun folders(): AppFolders {
        val root = Files.createTempDirectory("orbt-engine").toFile().apply { deleteOnExit() }
        return AppFolders(repertoires = root.resolve("Repertoires"), support = root.resolve("Support"))
    }

    @Test
    fun defaultsClampAndHalveTheCores() {
        val defaults = EngineDefaults(MemorySettings(), processors = 10)
        assertEquals(4u, defaults.settings.threads)
        assertEquals(6000u, defaults.settings.movetimeMs)
        assertEquals(3u, defaults.settings.lines)
        defaults.lines = 99
        defaults.searchTime = 0
        assertEquals(EngineDefaults.lineCounts.last.toUInt(), defaults.settings.lines)
        assertEquals(1000u, defaults.settings.movetimeMs)
        assertEquals(1, EngineDefaults(MemorySettings(), processors = 1).threads)
    }

    @Test
    fun noNetworkUntilDownloaded() {
        val network = EngineNetwork(folders())
        assertEquals(EngineNetwork.State.Absent, network.state)
        assertNull(network.path)
    }

    @Test
    fun analysesWithTheLightNetwork() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
        val defaults = EngineDefaults(MemorySettings(), processors = 2).apply {
            cloud = false
            searchTime = 1
        }
        val service = EngineService(EngineNetwork(folders(), scope), defaults, scope)
        withContext(Dispatchers.Main) {
            val start = Position.start()
            val after = start.playUci("e2e4")!!.position
            service.analyse(EngineService.Key(start.fen(), listOf("e2e4")), after.epd())
            for (attempt in 1..50) {
                if (service.lines.lines.size >= 3 && !service.lines.searching) break
                delay(100)
            }
            val shown = service.lines
            assertEquals(3, shown.lines.size)
            assertEquals(EvalSource.LOCAL, shown.source)
            assertTrue(shown.depth > 0u)
            assertEquals("SF 19 · 1 MB", service.name)
            assertNull(service.error)
            service.quit()
            assertNull(service.analysed)
        }
        scope.cancel()
    }
}
