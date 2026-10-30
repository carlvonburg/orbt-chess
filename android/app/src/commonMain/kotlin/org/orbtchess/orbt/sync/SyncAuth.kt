package org.orbtchess.orbt.sync

/** Where the repertoire folder syncs to (`FUTURE.md`, Connectors). None: this device only. */
enum class SyncProvider(val key: String, val title: String) {
    Dropbox("dropbox", "Dropbox"),
    Drive("drive", "Google Drive");

    companion object {
        fun of(key: String?): SyncProvider? = entries.firstOrNull { it.key == key }
    }
}

/**
 * What a sign-in gives the core (`RepertoireSync.setCredentials`). Dropbox: the refresh token
 * (the core gets access tokens with it); Drive: an access token from the system, no refresh
 * and no expiry (the core asks for a new one when Google refuses it).
 */
class SyncCredentials(
    val accessToken: String? = null,
    /** Unix ms; null when unknown. */
    val expiresAt: Long? = null,
    val refreshToken: String? = null,
    /** The account's email or name, for Settings. */
    val account: String? = null,
)

class SyncSignInException(message: String) : Exception(message)

/**
 * The platform's sign-ins (Android: Dropbox in a Custom Tab, Drive through Play services);
 * the desktop has none (it syncs through a folder, `FUTURE.md`). The requests to the providers
 * once signed in are the core's.
 */
interface SyncAuth {
    /** The providers this platform can sign in to; empty: no Sync section. */
    val providers: List<SyncProvider>

    /** Dropbox's app key (the OAuth client id), from the build; empty when none is set. */
    val dropboxAppKey: String

    /** Asks the user to sign in. Null when they cancelled; throws [SyncSignInException]. */
    suspend fun signIn(provider: SyncProvider): SyncCredentials?

    /** A new access token without asking the user (Drive), or null when only [signIn] can
     *  get one. `rejected`: the token the provider just refused, so it is not handed back. */
    suspend fun token(provider: SyncProvider, rejected: String?): SyncCredentials?

    /** Forgets the platform's own sign-in (Drive: the system's token); the core revokes
     *  Dropbox's on the server. */
    suspend fun signOut(provider: SyncProvider, credentials: SyncCredentials?)
}

/** No providers (the desktop). */
object NoSyncAuth : SyncAuth {
    override val providers: List<SyncProvider> = emptyList()
    override val dropboxAppKey: String = ""
    override suspend fun signIn(provider: SyncProvider): SyncCredentials? = null
    override suspend fun token(provider: SyncProvider, rejected: String?): SyncCredentials? = null
    override suspend fun signOut(provider: SyncProvider, credentials: SyncCredentials?) {}
}
