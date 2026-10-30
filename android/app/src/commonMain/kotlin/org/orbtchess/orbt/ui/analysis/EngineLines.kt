package org.orbtchess.orbt.ui.analysis

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.core.EvalSource
import org.orbtchess.orbt.core.PvLine
import org.orbtchess.orbt.core.Score
import org.orbtchess.orbt.engine.EngineService
import org.orbtchess.orbt.ui.components.tabularDigits
import org.orbtchess.orbt.ui.theme.OrbtTheme

/** The engine's lines for the position on the board, if they are for it. */
internal fun EngineService.shownLines(model: AnalysisModel): List<PvLine> {
    if (!model.engineOn || analysed != model.state.engineKey) return emptyList()
    return lines.lines
}

/**
 * Where the lines come from (Analysis's subtitle, as on iPhone): a Lichess cloud eval, or
 * Stockfish at some depth. Empty while the engine is off.
 */
internal fun EngineService.status(model: AnalysisModel): String {
    if (!model.engineOn) return ""
    val source = lines.source
    if (source != null && shownLines(model).isNotEmpty()) {
        return "${if (source == EvalSource.CLOUD) "Cloud" else name ?: "Stockfish"} · depth ${lines.depth}"
    }
    // Until lines come in (the placeholders show that), which engine will run.
    return error ?: name ?: ""
}

/** The engine's lines above the board while the engine is on. */
@Composable
internal fun AnalysisEngineLines(app: AppModel, model: AnalysisModel, modifier: Modifier = Modifier) {
    if (model.engineOn) {
        EngineLinesView(app.engine.shownLines(model), app.engineDefaults.lines, modifier) { model.play(it) }
    }
}

/**
 * The engine's lines: the evaluation and the moves, tap one to play its first move. Rows not in
 * yet are placeholders, so the board stays put.
 */
@Composable
internal fun EngineLinesView(lines: List<PvLine>, count: Int, modifier: Modifier = Modifier, play: (String) -> Unit) {
    Column(modifier.fillMaxWidth().padding(vertical = 6.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        lines.forEach { line ->
            Row(
                Modifier.fillMaxWidth().clip(RoundedCornerShape(6.dp))
                    .clickable { line.moves.firstOrNull()?.let { play(it.uci) } },
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                EvalChip(line.eval, line.score)
                Text(
                    line.text,
                    style = MaterialTheme.typography.bodyMedium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        repeat(maxOf(0, count - lines.size)) { PlaceholderLine() }
    }
}

/** A line not in yet: the chip and the moves as blank shapes. */
@Composable
private fun PlaceholderLine() {
    val fill = MaterialTheme.colorScheme.surfaceContainerHighest
    Row(
        Modifier.fillMaxWidth().clearAndSetSemantics {},
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // Text kept for its height, hidden under the shape.
        Box(Modifier.widthIn(min = 46.dp).clip(RoundedCornerShape(5.dp)).background(fill)) {
            Text(" ", style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(vertical = 2.dp))
        }
        Box(Modifier.fillMaxWidth(0.8f).height(14.dp).clip(RoundedCornerShape(4.dp)).background(fill))
    }
}

/** An evaluation, light when White is better and dark when Black is, as Lichess shows it. */
@Composable
internal fun EvalChip(text: String, score: Score) {
    val whiteBetter = when (score) {
        is Score.Cp -> score.v1 >= 0
        is Score.Mate -> score.v1 > 0
    }
    val board = OrbtTheme.board
    val fill = if (whiteBetter) board.whiteResult else board.blackResult
    Text(
        text,
        style = tabularDigits(MaterialTheme.typography.bodyMedium),
        fontWeight = FontWeight.SemiBold,
        color = board.resultText(fill),
        textAlign = TextAlign.Center,
        modifier = Modifier.widthIn(min = 46.dp).clip(RoundedCornerShape(5.dp)).background(fill)
            .padding(horizontal = 4.dp, vertical = 2.dp),
    )
}
