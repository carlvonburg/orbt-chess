package org.orbtchess.orbt.ui.statistics

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.core.Card
import org.orbtchess.orbt.core.Epd
import org.orbtchess.orbt.core.GraphParts
import org.orbtchess.orbt.core.GraphRange
import org.orbtchess.orbt.core.Graphs
import org.orbtchess.orbt.core.RetentionPeriod
import org.orbtchess.orbt.core.TrueRetention
import org.orbtchess.orbt.core.WeakMove
import org.orbtchess.orbt.core.count
import org.orbtchess.orbt.core.expectedRecall
import org.orbtchess.orbt.core.retentionTable
import org.orbtchess.orbt.core.schedTiming
import org.orbtchess.orbt.core.weakestMoves
import org.orbtchess.orbt.storage.NodeId
import org.orbtchess.orbt.storage.RepertoireDocument
import org.orbtchess.orbt.storage.RepertoireLibrary
import org.orbtchess.orbt.storage.StudyLog
import org.orbtchess.orbt.ui.StatisticsScope
import java.time.Instant
import java.time.ZoneId

/**
 * Loads cards and review logs for Statistics: all repertoires (Anki's whole collection) or one
 * repertoire (`StatisticsModel.swift`). The core decides what each scope counts.
 */
@Stable
class StatisticsModel {
    var range by mutableStateOf(GraphRange.MONTH)

    var graphs by mutableStateOf<Graphs?>(null)
        private set
    var cards by mutableStateOf<Map<Epd, Card>>(emptyMap())
        private set
    /** The open repertoire, for reach, opening branches and move names. */
    var document by mutableStateOf<RepertoireDocument?>(null)
        private set
    /** True retention, all time, of each repertoire (all repertoires only). */
    var repertoireRetention by mutableStateOf<List<Pair<String, TrueRetention>>>(emptyList())
        private set
    var isLoading by mutableStateOf(false)
        private set

    suspend fun load(app: AppModel, scope: StatisticsScope) {
        isLoading = true
        try {
            val timing = schedTiming()
            val offset = ZoneId.systemDefault().rules.getOffset(Instant.now()).totalSeconds.toLong()
            when (scope) {
                StatisticsScope.All -> {
                    val parts = mutableListOf<Pair<String, GraphParts>>()
                    for (entry in app.library.entries) {
                        if (entry.needsSetup) continue
                        val doc = app.documents.documents[entry.id]
                        val part = when {
                            doc != null -> doc.graphParts(wholeCollection = true)
                            entry.sidecar != null -> {
                                val revlog = StudyLog.readData(RepertoireLibrary.revlogFile(entry.pgnFile))
                                withContext(Dispatchers.Default) { entry.sidecar.graphParts(revlog) }
                            }
                            else -> continue
                        }
                        parts += entry.name to part
                    }
                    val (all, retention) = withContext(Dispatchers.Default) {
                        val retention = parts.mapNotNull { (name, part) ->
                            val r = Graphs.fromParts(listOf(part), timing, offset)
                                .retentionTable()[RetentionPeriod.ALL_TIME]
                            if (r != null && r.count > 0) name to r else null
                        }
                        Graphs.fromParts(parts.map { it.second }, timing, offset) to retention
                    }
                    document = null
                    cards = emptyMap()
                    repertoireRetention = retention
                    graphs = all
                }
                is StatisticsScope.Repertoire -> {
                    val entry = app.library.entry(scope.entryId)
                    val doc = entry?.let { app.documents.open(it) }
                    if (doc == null) {
                        graphs = null
                        return
                    }
                    val part = doc.graphParts(wholeCollection = false)
                    document = doc
                    repertoireRetention = emptyList()
                    cards = doc.core.repertoireCards()
                    graphs = withContext(Dispatchers.Default) { Graphs.fromParts(listOf(part), timing, offset) }
                }
            }
        } finally {
            isLoading = false
        }
    }

    // MARK: Chess statistics

    /** Expected recall in your games: weighted by how often each move comes up (one repertoire). */
    val expectedRecall: Double?
        get() {
            val document = document ?: return null
            return expectedRecall(cards, document.core.cardReach(), nowSecs())
        }

    fun weakestMoves(limit: Int): List<WeakMove> = weakestMoves(cards, nowSecs(), limit.toUInt())

    /** The first node with a position, for naming and opening it. */
    fun node(epd: Epd): NodeId? = document?.tree?.nodesAt(epd)?.firstOrNull()

    fun lineText(epd: Epd): String {
        val document = document ?: return ""
        val id = node(epd) ?: return ""
        return document.tree.lineText(id).ifEmpty { "Starting position" }
    }

    /** True retention for each opening branch, all time. */
    fun retentionByBranch(): List<Pair<String, TrueRetention>> {
        val document = document ?: return emptyList()
        val graphs = graphs ?: return emptyList()
        return document.openingBranches().mapNotNull { id ->
            val r = graphs.retentionTable(document.cardEpds(id).toList())[RetentionPeriod.ALL_TIME]
            if (r != null && r.count > 0) document.tree.lineText(id) to r else null
        }
    }

    private fun nowSecs() = System.currentTimeMillis() / 1000.0
}
