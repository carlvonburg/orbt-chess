package org.orbtchess.orbt.storage

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.orbtchess.orbt.core.Explorer
import org.orbtchess.orbt.core.Side
import org.orbtchess.orbt.core.StatsStore
import org.orbtchess.orbt.core.StoredStats
import org.orbtchess.orbt.core.databaseDefaultLichess
import org.orbtchess.orbt.core.defaultStudyDefaults
import org.orbtchess.orbt.core.newSidecar
import org.orbtchess.orbt.core.nowTimestamp
import java.io.File
import java.nio.file.Files
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/** The library and documents over a temporary folder. The `runBlocking` scope stands in for
 *  the main thread. */
class RepertoireStorageTest {
    private lateinit var folder: File

    companion object {
        init {
            // The core's host library, built by `core/scripts/build-android.sh`; the core
            // module's tests get it from Gradle, the app's set it here.
            if (System.getProperty("jna.library.path") == null) {
                generateSequence(File("").absoluteFile) { it.parentFile }
                    .map { File(it, "core/build/host") }
                    .firstOrNull { it.isDirectory }
                    ?.let { System.setProperty("jna.library.path", it.path) }
            }
        }
    }

    private class MemoryStore : StatsStore {
        override fun load(databaseKey: String): List<StoredStats> = emptyList()
        override fun save(databaseKey: String, epd: String, json: ByteArray) {}
    }

    private val explorer by lazy { Explorer(MemoryStore(), null, null) }

    private fun sidecar(): ByteArray =
        newSidecar("test", Side.WHITE, databaseDefaultLichess(), 100, nowTimestamp())

    private fun CoroutineScope.documents(): Documents =
        Documents(RepertoireLibrary(folder, this), explorer, { defaultStudyDefaults() }, this)

    @BeforeTest
    fun setUp() {
        folder = Files.createTempDirectory("orbt-storage").toFile()
    }

    @AfterTest
    fun tearDown() {
        folder.deleteRecursively()
    }

    @Test
    fun createEditReopen(): Unit = runBlocking {
        val docs = documents()
        docs.library.setUp()
        val entry = docs.library.create("Italian", sidecar())
        assertTrue(File(folder, "Italian.pgn").exists())
        assertTrue(File(folder, "Italian.${RepertoireLibrary.SIDECAR_EXTENSION}").exists())
        assertEquals(listOf("Italian"), docs.library.entries.map { it.name })
        assertFalse(docs.library.entries.single().needsSetup)

        val doc = assertNotNull(docs.open(entry))
        assertSame(doc, docs.open(entry))
        val e4 = assertNotNull(doc.addMove("e2e4", ROOT_NODE))
        doc.addMove("e7e5", e4)
        val revision = doc.revision
        assertTrue(revision > 0uL)
        assertTrue(doc.canUndo)

        // Saved on the core's delay, without a flush.
        withTimeout(10_000) {
            while (!File(folder, "Italian.pgn").readText().contains("e4")) delay(50)
        }
        docs.close(entry.id)
        docs.flushAll()
        assertTrue(docs.documents.isEmpty())

        val reopened = assertNotNull(documents().open(entry))
        val tree = reopened.tree
        val child = assertNotNull(tree.childByUci(ROOT_NODE, "e2e4"))
        assertNotNull(tree.childByUci(child, "e7e5"))
        assertNull(docs.openErrors[entry.id])
    }

    @Test
    fun flushWritesPendingEdits(): Unit = runBlocking {
        val docs = documents()
        docs.library.setUp()
        val entry = docs.library.create("Sicilian", sidecar())
        val doc = assertNotNull(docs.open(entry))
        doc.addLine(listOf("e2e4", "c7c5", "g1f3"), ROOT_NODE)
        docs.flushAll()
        assertTrue(File(folder, "Sicilian.pgn").readText().contains("Nf3"))
        assertNull(doc.saveError)
        docs.closeAll()
        docs.flushAll()
    }

    @Test
    fun renameMovesEveryFile(): Unit = runBlocking {
        val docs = documents()
        docs.library.setUp()
        val entry = docs.library.create("Old", sidecar())
        File(folder, "Old.${RepertoireLibrary.REVLOG_EXTENSION}").writeText("")
        val doc = assertNotNull(docs.open(entry))
        doc.addMove("d2d4", ROOT_NODE)
        docs.rename(doc, "New: Name")

        assertEquals("New - Name", doc.name)
        for (ext in listOf("pgn", RepertoireLibrary.SIDECAR_EXTENSION, RepertoireLibrary.REVLOG_EXTENSION)) {
            assertFalse(File(folder, "Old.$ext").exists(), ext)
            assertTrue(File(folder, "New - Name.$ext").exists(), ext)
        }
        assertEquals(doc.entryId, docs.currentId(entry.id))
        assertSame(doc, docs.documents[doc.entryId])
        assertEquals(listOf("New - Name"), docs.library.entries.map { it.name })

        // Saves go to the new file.
        doc.addMove("e2e4", ROOT_NODE)
        docs.flushAll()
        assertTrue(File(folder, "New - Name.pgn").readText().contains("e4"))
        assertFalse(File(folder, "Old.pgn").exists())

        // A case-only rename, and a name that is taken.
        docs.rename(doc, "new - name")
        assertEquals(listOf("new - name.pgn"), folder.list()!!.filter { it.endsWith(".pgn") })
        docs.library.create("Other", sidecar())
        assertFailsWith<RepertoireFileException> { docs.rename(doc, "Other") }
        docs.closeAll()
        docs.flushAll()
    }

    @Test
    fun deleteRemovesFilesWithoutSavingAgain(): Unit = runBlocking {
        val docs = documents()
        docs.library.setUp()
        val entry = docs.library.create("Gone", sidecar())
        val doc = assertNotNull(docs.open(entry))
        doc.addMove("e2e4", ROOT_NODE)
        docs.delete(entry)
        delay(1_500)
        assertTrue(folder.listFiles()!!.isEmpty())
        assertTrue(docs.library.entries.isEmpty())
        assertTrue(docs.documents.isEmpty())
    }

    @Test
    fun scanPairsFilesAndFindsUnsetPgns(): Unit = runBlocking {
        File(folder, "Dropped.pgn").writeText("1. e4 *\n")
        val library = RepertoireLibrary(folder, this)
        library.setUp()
        val dropped = library.entries.single()
        assertTrue(dropped.needsSetup)
        library.saveSidecar(sidecar(), dropped)
        assertFalse(library.entries.single().needsSetup)
        assertFailsWith<RepertoireFileException> { library.create("Dropped", sidecar()) }
        assertFailsWith<RepertoireFileException> { library.create("🎉", sidecar()) }
    }

    @Test
    fun remoteSidecarAndRevlog(): Unit = runBlocking {
        val docs = documents()
        docs.library.setUp()
        val entry = docs.library.create("Remote", sidecar())
        val doc = assertNotNull(docs.open(entry))
        doc.applyRemote(sidecar = sidecar(), revlog = ByteArray(0))
        assertTrue(File(folder, "Remote.${RepertoireLibrary.REVLOG_EXTENSION}").exists())
        doc.applyRemote(pgn = "[Event \"Remote\"]\n\n1. c4 *\n".toByteArray())
        assertNotNull(doc.tree.childByUci(ROOT_NODE, "c2c4"))
        docs.closeAll()
        docs.flushAll()
    }

    @Test
    fun cleanNames() {
        assertEquals("Ruy Lopez - Berlin-Wall", RepertoireLibrary.cleanName("Ruy Lopez: Berlin/Wall 🎉"))
        assertEquals("Caro-Kann (Advance)", RepertoireLibrary.cleanName("  ..Caro-Kann   (Advance) "))
        assertEquals("Défense Française", RepertoireLibrary.cleanName("Défense Française"))
        assertEquals(100, RepertoireLibrary.cleanName("a".repeat(150)).length)
        assertEquals("Imported", RepertoireLibrary.importName("🎉.pgn"))
    }
}
