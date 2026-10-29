package org.orbtchess.orbt.ui.training

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.orbtchess.orbt.core.DrillMode
import org.orbtchess.orbt.core.Explorer
import org.orbtchess.orbt.core.Feedback
import org.orbtchess.orbt.core.Phase
import org.orbtchess.orbt.core.Side
import org.orbtchess.orbt.core.StatsStore
import org.orbtchess.orbt.core.StoredStats
import org.orbtchess.orbt.core.boardSquare
import org.orbtchess.orbt.core.from
import org.orbtchess.orbt.core.to
import org.orbtchess.orbt.core.databaseDefaultLichess
import org.orbtchess.orbt.core.defaultStudyDefaults
import org.orbtchess.orbt.core.newSidecar
import org.orbtchess.orbt.core.nowTimestamp
import org.orbtchess.orbt.storage.Documents
import org.orbtchess.orbt.storage.RepertoireDocument
import org.orbtchess.orbt.storage.RepertoireLibrary
import org.orbtchess.orbt.ui.board.BoardBadge
import java.io.File
import java.nio.file.Files
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/** Study's clock over a real document: the model runs on the main (Swing) dispatcher, as in the app. */
class DrillModelTest {
    private lateinit var folder: File

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

    private class MemoryStore : StatsStore {
        override fun load(databaseKey: String): List<StoredStats> = emptyList()
        override fun save(databaseKey: String, epd: String, json: ByteArray) {}
    }

    @BeforeTest
    fun setUp() {
        folder = Files.createTempDirectory("orbt-drill").toFile()
    }

    @AfterTest
    fun tearDown() {
        folder.deleteRecursively()
    }

    /** A White repertoire 1. e4 e5 2. Nf3 Nc6 3. Bb5: three moves of yours. */
    private suspend fun document(): RepertoireDocument {
        val docs = Documents(
            RepertoireLibrary(folder, kotlinx.coroutines.MainScope()),
            Explorer(MemoryStore(), null, null),
            { defaultStudyDefaults() },
            kotlinx.coroutines.MainScope(),
        )
        docs.library.setUp()
        val sidecar = newSidecar("Ruy", Side.WHITE, databaseDefaultLichess(), 100, nowTimestamp())
        val entry = docs.library.create("Ruy", sidecar)
        File(folder, "Ruy.pgn").writeText("1. e4 e5 2. Nf3 Nc6 3. Bb5 *\n")
        docs.library.refresh()
        return assertNotNull(docs.open(docs.library.entry(entry.id)!!))
    }

    private suspend fun DrillModel.awaitPhase(vararg phases: Phase) {
        withTimeout(10_000) { while (phase !in phases) delay(20) }
    }

    @Test
    fun playsLinesToTheEnd(): Unit = runBlocking {
        withContext(Dispatchers.Main) { withTimeout(60_000) {
            val doc = document()
            assertEquals(3, doc.learningProgress().cards.toInt())
            val model = DrillModel(doc, DrillMode.Study)
            model.start()
            var wrongTried = false
            while (true) {
                model.awaitPhase(Phase.USER_TURN, Phase.FINISHED)
                if (model.finished) break
                // The move to play: your saved move after the moves on the board.
                val at = model.playedNodes.lastOrNull() ?: doc.tree.root.id
                val move = assertNotNull(doc.tree[doc.tree[at]!!.children.first()]?.mv)
                if (!wrongTried && model.feedback !is Feedback.NewMove) {
                    wrongTried = true
                    model.userMoved(boardSquare(0, 1), boardSquare(0, 2), null) // a3
                    assertIs<Feedback.Wrong>(model.feedback)
                    assertEquals(BoardBadge.Kind.Wrong, model.badge?.kind)
                    assertTrue(!model.canMove)
                    withTimeout(5_000) { while (!model.canMove) delay(20) }
                    continue
                }
                model.userMoved(move.from, move.to, null)
            }
            // Three new moves, the wrong answer, and the learning steps Anki shows again (learn-ahead).
            assertTrue(model.answeredCount >= 4, "answered ${model.answeredCount}")
            assertTrue(model.correctCount < model.answeredCount)
            assertEquals(0L, model.counts.new)
            model.close()
        } }
    }
}
