package org.orbtchess.orbt.explorer

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.orbtchess.orbt.core.CoverageFile
import org.orbtchess.orbt.core.CoverageTableFile
import org.orbtchess.orbt.core.CoverageTableInfo
import org.orbtchess.orbt.core.ExplorerDatabase
import org.orbtchess.orbt.core.HttpMethod
import org.orbtchess.orbt.core.HttpRequest
import org.orbtchess.orbt.core.coverageFileFor
import org.orbtchess.orbt.core.coverageFileVerify
import org.orbtchess.orbt.core.coverageManifestFiles
import org.orbtchess.orbt.core.coverageSelections
import org.orbtchess.orbt.platform.Http
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.logging.Logger

/**
 * Offline coverage tables: loads them into the core, lists the ones on the server
 * (`manifest.json`) and downloads them. Which file a repertoire needs and whether a download
 * is intact are decided by the core.
 *
 * Downloads live in the support folder's Coverage (local, not synced: they can be downloaded
 * again). Tables put by hand in the repertoire folder's "Coverage" subfolder are loaded too.
 * Called on the main thread (`scope`); files are read and tables parsed off it.
 */
class CoverageTables(
    private val explorer: ExplorerService,
    support: File,
    private val server: String = SERVER,
    private val scope: CoroutineScope = MainScope(),
) {
    /** The tables in the core. */
    var loaded: List<CoverageTableInfo> by mutableStateOf(emptyList())
        private set
    /** What the server offers (the last manifest read, kept for offline use). */
    var available: List<CoverageFile> by mutableStateOf(emptyList())
        private set
    private val downloadsState = mutableStateMapOf<String, Double>()
    private val failuresState = mutableStateMapOf<String, String>()
    /** Downloads in progress: file name → fraction done. */
    val downloads: Map<String, Double> get() = downloadsState
    /** Why the last download of a file failed, by file name. */
    val failures: Map<String, String> get() = failuresState

    private val loadedFiles = mutableSetOf<String>()
    /** Databases of open repertoires, downloaded once the manifest is known. */
    private val wanted = mutableSetOf<ExplorerDatabase>()
    /** Downloaded files the server has a different version of (rebuilt tables keep their names). */
    private var stale = setOf<String>()

    val directory = File(support, "Coverage")
    private val savedManifest get() = File(directory, "manifest.json")

    /** The loaded table for a database, if any. */
    fun table(database: ExplorerDatabase): CoverageTableInfo? = loaded.firstOrNull { it.database == database }

    /** The file to download for `database` (the deepest), if the server has one. */
    fun file(database: ExplorerDatabase): CoverageFile? = coverageFileFor(available, database)

    /** Whether the database's table is loaded (and is the deepest the server has). */
    fun isReady(database: ExplorerDatabase): Boolean {
        val table = table(database) ?: return false
        val file = file(database) ?: return true
        return table.targetGames >= file.targetGames && file.file !in stale
    }

    /** Downloads the table of an opened repertoire's database, now or once the manifest is read. */
    fun want(database: ExplorerDatabase) {
        if (database == ExplorerDatabase.Masters) return
        wanted.add(database)
        ensure(database)
    }

    /** Starts downloading the database's table unless it is here or already downloading. */
    fun ensure(database: ExplorerDatabase) {
        if (isReady(database)) return
        val file = file(database) ?: return
        if (file.file in downloadsState) return
        scope.launch { download(file) }
    }

    /** Every selection there is: downloadable or already on the device. */
    val selections: List<ExplorerDatabase>
        get() {
            val result = coverageSelections(available).map { it.database }.toMutableList()
            for (table in loaded) if (table.database !in result) result.add(table.database)
            return result
        }

    /**
     * Removes the partial downloads a killed process left, loads local tables, then reads the
     * server's list.
     */
    suspend fun setUp(appFolder: File?) {
        val manifest = withContext(Dispatchers.IO) {
            directory.mkdirs()
            // Nothing is downloading yet: every partial file is left over.
            directory.listFiles { file -> file.name.startsWith(".") && file.name.endsWith(".part") }
                ?.forEach { it.delete() }
            runCatching { savedManifest.readBytes() }.getOrNull()
        }
        if (manifest != null) available = coverageManifestFiles(manifest) ?: emptyList()
        load(directory)
        if (appFolder != null) load(File(appFolder, "Coverage"))
        refreshManifest()
    }

    suspend fun refreshManifest() {
        val request = HttpRequest(HttpMethod.GET, "${server}manifest.json", emptyList(), ByteArray(0), null)
        val response = Http.send(request)
        if (response == null) {
            log.severe("coverage manifest: no answer")
            return
        }
        val files = if (response.status.toInt() == 200) coverageManifestFiles(response.body) else null
        if (files == null) {
            log.severe("coverage manifest: unexpected response")
            return
        }
        available = files
        val directory = directory
        stale = withContext(Dispatchers.IO) {
            runCatching { writeAtomically(File(directory, "manifest.json"), response.body) }
            files.filter { file ->
                val bytes = runCatching { File(directory, file.file).readBytes() }.getOrNull() ?: return@filter false
                !coverageFileVerify(file, bytes)
            }.map { it.file }.toSet()
        }
        for (database in wanted.toList()) ensure(database)
    }

    /**
     * Reads the server's list again, then downloads the database's table (the button after a
     * failed download: the list may have changed since).
     */
    suspend fun retry(database: ExplorerDatabase) {
        refreshManifest()
        val file = file(database)
        if (file != null && !isReady(database)) download(file)
    }

    /** Downloads a table, checks it, replaces any other file for the same selection and loads it. */
    suspend fun download(file: CoverageFile) {
        if (file.file in downloadsState) return
        downloadsState[file.file] = 0.0
        failuresState.remove(file.file)
        // No Lichess requests for this database meanwhile: the table answers most of them.
        explorer.core.expectCoverageTable(file.database)
        try {
            val temporary = fetch("$server${file.file}", file.bytes) { fraction ->
                // A late report must not bring back a finished download.
                scope.launch { if (file.file in downloadsState) downloadsState[file.file] = fraction }
            }
            val destination = File(directory, file.file)
            val intact = withContext(Dispatchers.IO) {
                val data = runCatching { temporary.readBytes() }.getOrNull()
                data != null && coverageFileVerify(file, data)
            }
            if (!intact) {
                temporary.delete()
                failuresState[file.file] = "The download does not match the server's list of tables. Try again later."
                return
            }
            withContext(Dispatchers.IO) {
                for (other in available) {
                    if (other.database == file.database && other.file != file.file) File(directory, other.file).delete()
                }
                Files.move(temporary.toPath(), destination.toPath(), StandardCopyOption.REPLACE_EXISTING)
            }
            stale = stale - file.file
            loadedFiles.remove(directory.canonicalPath + File.separator + file.file)
            load(directory)
        } catch (e: IOException) {
            failuresState[file.file] = "Could not download the table: ${e.message ?: e}"
        } finally {
            downloadsState.remove(file.file)
            explorer.core.coverageTableDownloadEnded(file.database)
        }
    }

    /** Reads the tables (`*.otcb`, `*.otcb.zst`) in `directory` that are not loaded yet. */
    suspend fun load(directory: File) {
        val path = withContext(Dispatchers.IO) { directory.canonicalPath }
        val names = withContext(Dispatchers.IO) { directory.list()?.sorted() ?: emptyList() }
        for (name in names) {
            if (!(name.endsWith(".otcb") || name.endsWith(".otcb.zst"))) continue
            val key = path + File.separator + name
            if (key in loadedFiles) continue
            loadedFiles.add(key)
            val started = System.nanoTime()
            val result = withContext(Dispatchers.IO) {
                runCatching { CoverageTableFile(File(directory, name).readBytes()) }
            }
            result.onSuccess { table ->
                table.use {
                    val info = it.info()
                    explorer.core.addCoverageTable(it)
                    loaded = loaded.filter { other -> other.database != info.database } + info
                    log.info("coverage table $name: ${info.positions} positions in ${(System.nanoTime() - started) / 1_000_000} ms")
                }
            }.onFailure { error ->
                log.severe("coverage table $name: $error")
            }
        }
    }

    /**
     * Downloads to a temporary file next to the tables, reporting progress (from the IO thread).
     * `expectedBytes` stands in when the server sends no length.
     */
    private suspend fun fetch(url: String, expectedBytes: Long, progress: (Double) -> Unit): File =
        withContext(Dispatchers.IO) {
            directory.mkdirs()
            val temporary = File.createTempFile(".download", ".part", directory)
            try {
                client.newCall(Request.Builder().url(url).build()).execute().use { response ->
                    if (response.code != 200) throw IOException("The server answered ${response.code}.")
                    val body = response.body ?: throw IOException("The server sent nothing.")
                    val total = body.contentLength().takeIf { it > 0 } ?: expectedBytes
                    var done = 0L
                    var reported = 0.0
                    body.byteStream().use { input ->
                        temporary.outputStream().use { output ->
                            val buffer = ByteArray(64 * 1024)
                            while (true) {
                                ensureActive()
                                val count = input.read(buffer)
                                if (count < 0) break
                                output.write(buffer, 0, count)
                                done += count
                                val fraction = if (total > 0) (done.toDouble() / total).coerceAtMost(1.0) else 0.0
                                if (fraction - reported >= 0.01) {
                                    reported = fraction
                                    progress(fraction)
                                }
                            }
                        }
                    }
                }
                temporary
            } catch (e: Throwable) {
                temporary.delete()
                throw e
            }
        }

    private fun writeAtomically(file: File, bytes: ByteArray) {
        val temporary = File.createTempFile(".manifest", ".part", file.parentFile)
        temporary.writeBytes(bytes)
        Files.move(temporary.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
    }

    companion object {
        const val SERVER = "https://pub-7bc2c6c30e4d4311a454d55fb34e57ba.r2.dev/coverage_bins/"
        private val client = OkHttpClient()
        private val log = Logger.getLogger("org.orbtchess.orbt.coverage")
    }
}
