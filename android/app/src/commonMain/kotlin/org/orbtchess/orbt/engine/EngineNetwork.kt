package org.orbtchess.orbt.engine

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.orbtchess.orbt.core.engineNetworkIsValid
import org.orbtchess.orbt.platform.AppFolders
import java.io.File
import java.io.IOException

/**
 * Stockfish 19's full network (94 MB), downloaded on request into the app's support folder.
 * The app ships with the 1 MB light network built in; with this one the engine is stronger.
 * Checked against the SHA-256 in its name before use: Stockfish ends the process when a
 * network fails to load. `apple/ORBT/Engine/EngineNetwork.swift`. Used from the main thread.
 */
class EngineNetwork(folders: AppFolders, private val scope: CoroutineScope = MainScope()) {
    sealed interface State {
        data object Absent : State
        data class Downloading(val fraction: Double) : State
        data object Ready : State
        data class Failed(val message: String) : State
    }

    companion object {
        const val FILE_NAME = "nn-1a298aa575a0.nnue"
        const val BYTE_COUNT = 98_511_183L
        /** Where Stockfish's own builds download it. */
        const val SOURCE = "https://tests.stockfishchess.org/api/nn/$FILE_NAME"

        private val client by lazy { OkHttpClient() }
    }

    private val folder = File(folders.support, "Engine")
    val file = File(folder, FILE_NAME)
    /** The download, named after its hash for the check, before it is moved into place. */
    private val partial = File(File(folders.support, "Engine Download"), FILE_NAME)

    var state by mutableStateOf<State>(if (file.exists()) State.Ready else State.Absent)
        private set
    private var download: Job? = null

    /** The network's path while it is downloaded. */
    val path: String? get() = if (state == State.Ready) file.path else null

    fun start() {
        if (download != null) return
        state = State.Downloading(0.0)
        download = scope.launch {
            val result = fetch { fraction ->
                scope.launch { if (state is State.Downloading) state = State.Downloading(fraction) }
            }
            download = null
            state = result
        }
    }

    fun cancel() {
        download?.cancel()
        download = null
        state = State.Absent
    }

    fun remove() {
        file.delete()
        state = State.Absent
    }

    private suspend fun fetch(progress: (Double) -> Unit): State = withContext(Dispatchers.IO) {
        try {
            downloadFile(progress)
            // The check reads the whole file: named after its hash, so a partial or wrong file
            // never reaches the engine.
            if (!engineNetworkIsValid(partial.path)) {
                partial.delete()
                return@withContext State.Failed("The downloaded network is damaged.")
            }
            folder.mkdirs()
            file.delete()
            if (!partial.renameTo(file)) throw IOException("Could not move the network into place.")
            State.Ready
        } catch (cancelled: CancellationException) {
            partial.delete()
            throw cancelled
        } catch (error: IOException) {
            partial.delete()
            ensureActive()
            State.Failed(error.message ?: "The download failed.")
        }
    }

    /**
     * Downloads the network to `partial`, reporting progress against its size (the server
     * compresses it, so the response's length is not the file's).
     */
    private suspend fun downloadFile(progress: (Double) -> Unit) {
        val call = client.newCall(Request.Builder().url(SOURCE).build())
        val cancelling = currentCoroutineContext().job.invokeOnCompletion { if (it != null) call.cancel() }
        try {
            call.execute().use { response ->
                if (response.code != 200) throw IOException("The server did not send the network.")
                val body = response.body ?: throw IOException("The server did not send the network.")
                partial.parentFile.mkdirs()
                partial.outputStream().use { out ->
                    val input = body.byteStream()
                    val buffer = ByteArray(64 * 1024)
                    var written = 0L
                    var reported = 0.0
                    while (true) {
                        currentCoroutineContext().ensureActive()
                        val read = input.read(buffer)
                        if (read < 0) break
                        out.write(buffer, 0, read)
                        written += read
                        val fraction = minOf(1.0, written.toDouble() / BYTE_COUNT)
                        // Every half percent: enough for the progress bar.
                        if (fraction - reported >= 0.005) {
                            reported = fraction
                            progress(fraction)
                        }
                    }
                }
            }
        } finally {
            cancelling.dispose()
        }
    }
}
