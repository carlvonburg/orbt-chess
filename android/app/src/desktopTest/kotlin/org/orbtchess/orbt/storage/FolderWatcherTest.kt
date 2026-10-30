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
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The desktop's synced folder over a temporary folder: changes the provider's client makes
 * (written here with plain file writes), conflict copies, and saves in place. The `runBlocking`
 * scope stands in for the main thread; `check` is one round of the watcher's loop, with no
 * settling time.
 */
class FolderWatcherTest {
    private lateinit var folder: File
    private lateinit var journal: File

    companion object {
        init {
            if (System.getProperty("jna.library.path") == null) {
                generateSequence(File("").absoluteFile) { it.parentFile }
                    .map { File(it, "core/build/host") }
                    .firstOrNull { it.isDirectory }
                    ?.let { System.setProperty("jna.library.path", it.path) }
            }
        }

        private const val E4 = "[Event \"?\"]\n\n1. e4 *\n"
        private const val D4 = "[Event \"?\"]\n\n1. d4 *\n"
    }

    private class MemoryStore : StatsStore {
        override fun load(databaseKey: String): List<StoredStats> = emptyList()
        override fun save(databaseKey: String, epd: String, json: ByteArray) {}
    }

    private val explorer by lazy { Explorer(MemoryStore(), null, null) }

    private fun sidecar(): ByteArray =
        newSidecar("test", Side.WHITE, databaseDefaultLichess(), 100, nowTimestamp())

    private suspend fun CoroutineScope.watched(): Pair<Documents, FolderWatcher> {
        val docs = Documents(RepertoireLibrary(folder, this), explorer, { defaultStudyDefaults() }, this)
        val watcher = FolderWatcher(docs, settle = 0)
        FileAccess.watcher = watcher.observer
        docs.library.setUp()
        return docs to watcher
    }

    /** Another device's write: a new modification time and size, as the provider's client leaves. */
    private fun remoteWrite(name: String, text: String) {
        val file = File(folder, name)
        val before = file.lastModified()
        file.writeText(text)
        if (file.lastModified() == before) file.setLastModified(before + 1_000)
    }

    @BeforeTest
    fun setUp() {
        folder = Files.createTempDirectory("orbt-watch").toFile()
        journal = Files.createTempDirectory("orbt-journal").toFile()
        FileAccess.journal = journal
    }

    @AfterTest
    fun tearDown() {
        FileAccess.journal = null
        FileAccess.watcher = null
        folder.deleteRecursively()
        journal.deleteRecursively()
    }

    @Test
    fun conflictCopyNames() {
        assertEquals("Italian.pgn", conflictCopyOriginal("Italian (Carl's conflicted copy 2026-10-30).pgn"))
        assertEquals("Italian.otrep.json", conflictCopyOriginal("Italian.otrep (Carl's conflicted copy 2026-10-30).json"))
        assertEquals("Italian.pgn", conflictCopyOriginal("Italian (1).pgn"))
        assertNull(conflictCopyOriginal("Italian.pgn"))
        assertNull(conflictCopyOriginal("Ruy Lopez (Berlin).pgn"))
        // Only with its original there.
        assertEquals(
            mapOf("Najdorf (2).pgn" to "Najdorf.pgn"),
            conflictCopies(listOf("Najdorf.pgn", "Najdorf (2).pgn", "Dragon (2).pgn")),
        )
    }

    @Test
    fun aRepertoireNamedLikeACopyStaysWithoutItsOriginal(): Unit = runBlocking {
        File(folder, "Dragon (2).pgn").writeText(E4)
        File(folder, "Dragon (2).${RepertoireLibrary.SIDECAR_EXTENSION}").writeBytes(sidecar())
        val (docs, watcher) = watched()
        watcher.check()
        remoteWrite("Dragon (2).pgn", D4)
        watcher.check()
        assertTrue(File(folder, "Dragon (2).pgn").exists())
        assertEquals(listOf("Dragon (2)"), docs.library.entries.map { it.name })
    }

    @Test
    fun savesInPlace() {
        val file = File(folder, "Italian.pgn")
        FileAccess.write(E4.toByteArray(), file)
        val id = Files.getAttribute(file.toPath(), "unix:ino")
        FileAccess.write("short".toByteArray(), file)
        assertEquals("short", file.readText())
        // The same file, not a new one renamed over it: Google Drive keeps its id.
        assertEquals(id, Files.getAttribute(file.toPath(), "unix:ino"))
        assertTrue(journal.listFiles().orEmpty().isEmpty())
        assertFalse(folder.listFiles().orEmpty().any { it.name.startsWith(".") })
    }

    @Test
    fun interruptedSaveIsFinished() {
        val file = File(folder, "Italian.pgn")
        file.writeText("half writ")
        // A crash after the journal and before the file was written.
        File(journal, "1-1.journal").writeBytes("${file.absolutePath}\n".toByteArray() + D4.toByteArray())
        File(journal, "2-1.tmp").writeText("incomplete")
        assertEquals(listOf(file), FileAccess.recoverJournal(journal))
        assertEquals(D4, file.readText())
        assertTrue(journal.listFiles().orEmpty().isEmpty())
    }

    @Test
    fun ownSavesAreNotRemoteChanges(): Unit = runBlocking {
        val (docs, watcher) = watched()
        val entry = docs.library.create("Italian", sidecar())
        watcher.check()
        val doc = assertNotNull(docs.open(entry))
        doc.addMove("e2e4", ROOT_NODE)
        docs.flushAll()
        val revision = doc.revision
        watcher.check()
        watcher.check()
        assertEquals(revision, doc.revision)
        assertTrue(doc.canUndo, "a remote change would have cleared the undo history")
        docs.closeAll()
        docs.flushAll()
    }

    @Test
    fun remoteChangeReachesOpenDocument(): Unit = runBlocking {
        val (docs, watcher) = watched()
        val entry = docs.library.create("Italian", sidecar())
        val doc = assertNotNull(docs.open(entry))
        watcher.check()
        remoteWrite("Italian.pgn", D4)
        watcher.check()
        assertNotNull(doc.tree.childByUci(ROOT_NODE, "d2d4"))
        docs.closeAll()
        docs.flushAll()
    }

    @Test
    fun newAndDeletedFilesReachTheLibrary(): Unit = runBlocking {
        val (docs, watcher) = watched()
        val entry = docs.library.create("Italian", sidecar())
        assertNotNull(docs.open(entry))
        watcher.check()
        File(folder, "London.pgn").writeText(D4)
        File(folder, "London.${RepertoireLibrary.SIDECAR_EXTENSION}").writeBytes(sidecar())
        File(folder, "Italian.pgn").delete()
        watcher.check()
        // The closed document's own rescan, started meanwhile, has the last word.
        withTimeout(5_000) {
            while (docs.library.entries.map { it.name } != listOf("London")) delay(20)
        }
        assertTrue(docs.documents.isEmpty(), "the deleted repertoire's document is closed")
        docs.flushAll()
        assertFalse(File(folder, "Italian.pgn").exists(), "nothing writes it again")
    }

    @Test
    fun conflictCopyOfClosedRepertoireIsMerged(): Unit = runBlocking {
        val (docs, watcher) = watched()
        docs.library.create("Italian", sidecar())
        remoteWrite("Italian.pgn", E4)
        watcher.check()
        File(folder, "Italian (Carl's conflicted copy 2026-10-30).pgn").writeText(D4)
        File(folder, "Italian.otrep (Carl's conflicted copy 2026-10-30).json").writeBytes(sidecar())
        watcher.check()
        val pgn = File(folder, "Italian.pgn").readText()
        assertTrue("e4" in pgn && "d4" in pgn, pgn)
        assertEquals(
            listOf("Italian.otrep.json", "Italian.pgn"),
            folder.listFiles().orEmpty().map { it.name }.sorted(),
        )
        assertEquals(listOf("Italian"), docs.library.entries.map { it.name })
        assertTrue(docs.documents.isEmpty())
        docs.flushAll()
    }

    @Test
    fun conflictCopyOfOpenRepertoireIsMerged(): Unit = runBlocking {
        val (docs, watcher) = watched()
        val entry = docs.library.create("Italian", sidecar())
        val doc = assertNotNull(docs.open(entry))
        doc.addMove("e2e4", ROOT_NODE)
        docs.flushAll()
        watcher.check()
        File(folder, "Italian (1).pgn").writeText(D4)
        watcher.check()
        assertNotNull(doc.tree.childByUci(ROOT_NODE, "e2e4"))
        assertNotNull(doc.tree.childByUci(ROOT_NODE, "d2d4"))
        assertFalse(File(folder, "Italian (1).pgn").exists())
        docs.flushAll()
        val pgn = File(folder, "Italian.pgn").readText()
        assertTrue("e4" in pgn && "d4" in pgn, pgn)
        docs.closeAll()
        docs.flushAll()
    }

    @Test
    fun conflictCopiesLeftFromBeforeAreMergedAtStart(): Unit = runBlocking {
        File(folder, "Italian.pgn").writeText(E4)
        File(folder, "Italian.${RepertoireLibrary.SIDECAR_EXTENSION}").writeBytes(sidecar())
        val log = "{\"id\":1}\n"
        File(folder, "Italian.${RepertoireLibrary.REVLOG_EXTENSION}").writeText(log)
        val copy = File(folder, "Italian.otlog (Carl's conflicted copy 2026-10-30).jsonl")
        copy.writeText(log)
        val (docs, watcher) = watched()
        assertEquals(listOf("Italian"), docs.library.entries.map { it.name })
        watcher.check()
        assertFalse(copy.exists())
        docs.flushAll()
    }
}
