package org.orbtchess.orbt.platform

import com.github.javakeyring.Keyring
import org.orbtchess.orbt.lichess.LoopbackAuthBrowser
import org.orbtchess.orbt.storage.FileAccess
import org.orbtchess.orbt.sync.DesktopSyncAuth
import java.awt.Desktop
import java.io.File
import java.net.URI
import java.util.logging.Logger
import java.util.prefs.Preferences

/**
 * The desktop's folders: the repertoires in `~/ORBT Chess` (`FolderWatcher` follows changes made
 * outside the app; other devices through Settings › Sync), the app's data in the OS's per-user
 * application folder. Saves overwrite the files in place (`FileAccess.journal`).
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
    val authBrowser = LoopbackAuthBrowser(openUrl)
    return PlatformServices(
        folders = AppFolders(repertoires = File(home, "ORBT Chess"), support = support),
        settings = settings,
        secrets = KeyringSecrets.open(PrefsSecrets(prefs.node("secrets"))),
        openUrl = openUrl,
        authBrowser = authBrowser,
        syncAuth = DesktopSyncAuth(authBrowser),
    )
}

private val log = Logger.getLogger("org.orbtchess.orbt.platform")

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
