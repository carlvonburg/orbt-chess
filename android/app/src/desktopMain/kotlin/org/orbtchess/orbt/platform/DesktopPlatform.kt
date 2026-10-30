package org.orbtchess.orbt.platform

import com.github.javakeyring.Keyring
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.orbtchess.orbt.AppModel
import org.orbtchess.orbt.lichess.LoopbackAuthBrowser
import org.orbtchess.orbt.storage.FileAccess
import org.orbtchess.orbt.sync.DesktopSyncAuth
import java.awt.Desktop
import java.awt.FileDialog
import java.awt.Frame
import java.io.File
import java.net.URI
import java.util.logging.Logger
import java.util.prefs.Preferences
import javax.swing.JFileChooser
import javax.swing.UIManager

/**
 * The desktop's folders: the repertoires in `~/ORBT Chess`, or a folder the user chose in
 * Settings (inside Dropbox or Google Drive for desktop, whose client syncs it; `FolderWatcher`
 * follows its changes), the app's data in the OS's per-user application folder. Saves overwrite
 * the files in place (`FileAccess.journal`), so Google Drive keeps each file's id.
 */
fun desktopPlatform(): PlatformServices {
    val home = File(System.getProperty("user.home"))
    val os = System.getProperty("os.name").lowercase()
    val support = when {
        os.contains("win") -> File(System.getenv("APPDATA") ?: home.path, "ORBT Chess")
        os.contains("mac") -> File(home, "Library/Application Support/ORBT Chess")
        else -> File(System.getenv("XDG_DATA_HOME") ?: File(home, ".local/share").path, "orbt-chess")
    }
    val prefs = Preferences.userRoot().node("org/orbtchess/orbt")
    val settings = PrefsSettings(prefs.node("settings"))
    val openUrl = { url: String ->
        if (Desktop.isDesktopSupported()) Desktop.getDesktop().browse(URI(url))
    }
    // Before anything reads the files: saves a crash interrupted are finished.
    val journal = File(support, "Journal")
    FileAccess.recoverJournal(journal).forEach { log.info("finished saving ${it.path}") }
    FileAccess.journal = journal
    val chooser = DesktopFolderChooser(default = File(home, "ORBT Chess"), mac = os.contains("mac"), linux = !os.contains("win") && !os.contains("mac"))
    val authBrowser = LoopbackAuthBrowser(openUrl)
    val chosen = settings.getString(AppModel.REPERTOIRE_FOLDER_KEY)?.let(::File)
    return PlatformServices(
        folders = AppFolders(repertoires = chosen ?: chooser.default, support = support),
        settings = settings,
        secrets = KeyringSecrets.open(PrefsSecrets(prefs.node("secrets"))),
        openUrl = openUrl,
        authBrowser = authBrowser,
        syncAuth = DesktopSyncAuth(authBrowser),
        folderChooser = chooser,
    )
}

private val log = Logger.getLogger("org.orbtchess.orbt.platform")

/**
 * The system's folder chooser: the native one on macOS (`FileDialog` for folders); on Linux
 * the desktop's own (zenity on GNOME, kdialog on KDE) when installed; otherwise Swing's, in the
 * system's look (Windows: Java has no native folder chooser).
 */
private class DesktopFolderChooser(override val default: File, private val mac: Boolean, private val linux: Boolean) : FolderChooser {
    override suspend fun choose(current: File): File? {
        if (mac) return macDialog(current)
        if (linux) linuxDialog(current)?.let { return it.getOrNull() }
        return swingDialog(current)
    }

    private fun macDialog(current: File): File? {
        System.setProperty("apple.awt.fileDialogForDirectories", "true")
        try {
            val dialog = FileDialog(null as Frame?, "Repertoire Folder", FileDialog.LOAD).apply {
                directory = current.parentFile?.path
                file = current.name
                isVisible = true
            }
            return dialog.files.firstOrNull()
        } finally {
            System.setProperty("apple.awt.fileDialogForDirectories", "false")
        }
    }

    /** Null when neither tool runs; otherwise the result (a null folder: cancelled). */
    private suspend fun linuxDialog(current: File): Result<File?>? = withContext(Dispatchers.IO) {
        val commands = listOf(
            listOf("zenity", "--file-selection", "--directory", "--title=Repertoire Folder", "--filename=${current.path}/"),
            listOf("kdialog", "--getexistingdirectory", current.path, "--title", "Repertoire Folder"),
        )
        for (command in commands) {
            val process = runCatching { ProcessBuilder(command).redirectError(ProcessBuilder.Redirect.DISCARD).start() }.getOrNull() ?: continue
            val output = process.inputStream.bufferedReader().readText().trim()
            // 0: chosen; 1: cancelled.
            return@withContext when (process.waitFor()) {
                0 -> Result.success(output.takeIf { it.isNotEmpty() }?.let(::File))
                1 -> Result.success(null)
                else -> continue
            }
        }
        null
    }

    private fun swingDialog(current: File): File? {
        runCatching { UIManager.setLookAndFeel(UIManager.getSystemLookAndFeelClassName()) }
        val chooser = JFileChooser(current).apply {
            dialogTitle = "Repertoire Folder"
            fileSelectionMode = JFileChooser.DIRECTORIES_ONLY
            isAcceptAllFileFilterUsed = false
        }
        return if (chooser.showDialog(null, "Choose") == JFileChooser.APPROVE_OPTION) chooser.selectedFile else null
    }
}

private class PrefsSettings(private val prefs: Preferences) : Settings {
    private fun has(key: String) = prefs.get(key, null) != null
    override fun getInt(key: String) = if (has(key)) prefs.getInt(key, 0) else null
    override fun putInt(key: String, value: Int) = prefs.putInt(key, value)
    override fun getLong(key: String) = if (has(key)) prefs.getLong(key, 0) else null
    override fun putLong(key: String, value: Long) = prefs.putLong(key, value)
    override fun getBoolean(key: String) = if (has(key)) prefs.getBoolean(key, false) else null
    override fun putBoolean(key: String, value: Boolean) = prefs.putBoolean(key, value)
    override fun getString(key: String): String? = prefs.get(key, null)
    override fun putString(key: String, value: String) = prefs.put(key, value)
    override fun remove(key: String) = prefs.remove(key)
}

/** The user's private settings: where the OS has no credential store we can reach. */
private class PrefsSecrets(private val prefs: Preferences) : SecretStore {
    override fun get(key: String): String? = prefs.get(key, null)
    override fun set(key: String, value: String) = prefs.put(key, value)
    override fun remove(key: String) = prefs.remove(key)
}

/**
 * The OS's credential store (java-keyring): the Keychain on macOS, Windows' Credential Manager,
 * the Secret Service on Linux (GNOME Keyring, KWallet). Secrets kept in the settings by earlier
 * versions move into it when first read. Falls back to the settings when the store fails (a
 * Linux without a Secret Service, a locked keyring the user did not open).
 */
private class KeyringSecrets(private val keyring: Keyring, private val fallback: PrefsSecrets) : SecretStore {
    override fun get(key: String): String? {
        val stored = runCatching { keyring.getPassword(SERVICE, key) }.getOrNull()
        if (stored != null) return stored
        val old = fallback.get(key) ?: return null
        if (runCatching { keyring.setPassword(SERVICE, key, old) }.isSuccess) fallback.remove(key)
        return old
    }

    override fun set(key: String, value: String) {
        runCatching { keyring.setPassword(SERVICE, key, value) }
            .onSuccess { fallback.remove(key) }
            .onFailure {
                log.warning("credential store: ${it.message}; kept in the settings")
                fallback.set(key, value)
            }
    }

    override fun remove(key: String) {
        // Deleting what is not there throws on some stores.
        runCatching { keyring.deletePassword(SERVICE, key) }
        fallback.remove(key)
    }

    companion object {
        private const val SERVICE = "ORBT Chess"

        fun open(fallback: PrefsSecrets): SecretStore =
            runCatching { KeyringSecrets(Keyring.create(), fallback) }
                .onFailure { log.warning("no credential store: ${it.message}") }
                .getOrDefault(fallback)
    }
}
