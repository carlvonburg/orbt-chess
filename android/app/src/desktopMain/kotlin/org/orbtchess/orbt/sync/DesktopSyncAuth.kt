package org.orbtchess.orbt.sync

import org.orbtchess.orbt.core.RepertoireSync
import org.orbtchess.orbt.core.SignInException
import org.orbtchess.orbt.core.driveAccountRequest
import org.orbtchess.orbt.core.driveAuthorizeUrl
import org.orbtchess.orbt.core.driveParseAccount
import org.orbtchess.orbt.core.driveParseToken
import org.orbtchess.orbt.core.driveTokenRequest
import org.orbtchess.orbt.core.dropboxAccountRequest
import org.orbtchess.orbt.core.dropboxAuthorizeUrl
import org.orbtchess.orbt.core.dropboxParseAccount
import org.orbtchess.orbt.core.dropboxParseToken
import org.orbtchess.orbt.core.dropboxTokenRequest
import org.orbtchess.orbt.core.oauthParseRedirect
import org.orbtchess.orbt.core.oauthRandomString
import org.orbtchess.orbt.lichess.LoopbackAuthBrowser
import org.orbtchess.orbt.platform.Http
import java.io.IOException
import java.security.SecureRandom

/**
 * The desktop's sign-ins for the sync (Windows, Linux; also macOS from Gradle): each provider's
 * page in the default browser and its redirect to a loopback server (`LoopbackAuthBrowser`),
 * PKCE and the requests from the core. Both give a refresh token, which the core uses from
 * then on.
 *
 * Dropbox matches redirect URIs exactly, port included: the app listens on the first free one
 * of [DROPBOX_PORTS], each registered with the Dropbox app as `http://127.0.0.1:<port>/`.
 * Google Drive takes any loopback port for a "Desktop app" client, whose secret ships in the app
 * (Google's desktop clients can't keep one) and goes in the code exchange and every refresh; the
 * core's Drive sync refreshes and revokes itself (`RepertoireSync.driveOauth`).
 *
 * The keys come from the build (`app/build.gradle.kts`: Gradle properties or local.properties,
 * never committed) as system properties; a provider without its key is not offered.
 */
class DesktopSyncAuth(
    private val browser: LoopbackAuthBrowser,
    override val dropboxAppKey: String = System.getProperty("orbt.dropboxAppKey").orEmpty(),
    private val driveClientId: String = System.getProperty("orbt.driveDesktopClientId").orEmpty(),
    private val driveClientSecret: String? = System.getProperty("orbt.driveDesktopClientSecret")?.ifEmpty { null },
) : SyncAuth {
    override val providers: List<SyncProvider> = buildList {
        if (dropboxAppKey.isNotEmpty()) add(SyncProvider.Dropbox)
        if (driveClientId.isNotEmpty()) add(SyncProvider.Drive)
    }

    override suspend fun signIn(provider: SyncProvider): SyncCredentials? = when (provider) {
        SyncProvider.Dropbox -> dropboxSignIn()
        SyncProvider.Drive -> driveSignIn()
    }

    override fun driveSync(savedState: ByteArray): RepertoireSync =
        RepertoireSync.driveOauth(driveClientId, driveClientSecret, savedState)

    /** The core refreshes both providers' tokens itself (Drive through `driveSync`). */
    override suspend fun token(provider: SyncProvider, rejected: String?): SyncCredentials? = null

    /** The core revoked the tokens on the server (`SyncService.signOut`); nothing is kept here. */
    override suspend fun signOut(provider: SyncProvider, credentials: SyncCredentials?) {}

    private suspend fun dropboxSignIn(): SyncCredentials? {
        val verifier = oauthRandomString(randomBytes(64))
        val state = oauthRandomString(randomBytes(32))
        var redirectUri = ""
        val callback = try {
            browser.onPorts(DROPBOX_PORTS).authenticate { uri ->
                redirectUri = uri
                dropboxAuthorizeUrl(dropboxAppKey, verifier, state, uri)
            }
        } catch (e: IOException) {
            throw SyncSignInException("Could not start the Dropbox sign-in: ${e.message}")
        } ?: return null
        try {
            val code = oauthParseRedirect(callback, state) ?: return null // the user declined
            val response = Http.send(dropboxTokenRequest(dropboxAppKey, code, verifier, redirectUri))
                ?: throw SyncSignInException("Could not reach Dropbox.")
            val signIn = dropboxParseToken(response, System.currentTimeMillis())
            val account = Http.send(dropboxAccountRequest(signIn.accessToken))?.let(::dropboxParseAccount)
            return SyncCredentials(
                accessToken = signIn.accessToken,
                expiresAt = signIn.expiresAt,
                refreshToken = signIn.refreshToken,
                account = account,
            )
        } catch (e: SignInException) {
            throw SyncSignInException((e as? SignInException.Failed)?.reason ?: e.message ?: "Dropbox sign-in failed.")
        }
    }

    private suspend fun driveSignIn(): SyncCredentials? {
        if (driveClientId.isEmpty()) throw SyncSignInException("This build has no Google Drive client.")
        val verifier = oauthRandomString(randomBytes(64))
        val state = oauthRandomString(randomBytes(32))
        var redirectUri = ""
        val callback = try {
            browser.authenticate { uri ->
                redirectUri = uri
                driveAuthorizeUrl(driveClientId, verifier, state, uri)
            }
        } catch (e: IOException) {
            throw SyncSignInException("Could not start the Google sign-in: ${e.message}")
        } ?: return null
        try {
            val code = oauthParseRedirect(callback, state) ?: return null // the user declined
            val response = Http.send(driveTokenRequest(driveClientId, driveClientSecret, code, verifier, redirectUri))
                ?: throw SyncSignInException("Could not reach Google.")
            val signIn = driveParseToken(response, System.currentTimeMillis())
            val account = Http.send(driveAccountRequest(signIn.accessToken))?.let(::driveParseAccount)
            return SyncCredentials(
                accessToken = signIn.accessToken,
                expiresAt = signIn.expiresAt,
                refreshToken = signIn.refreshToken,
                account = account,
            )
        } catch (e: SignInException) {
            throw SyncSignInException((e as? SignInException.Failed)?.reason ?: e.message ?: "Google sign-in failed.")
        }
    }

    companion object {
        /** Register each as `http://127.0.0.1:<port>/` in the Dropbox app's OAuth 2 redirect URIs. */
        val DROPBOX_PORTS = listOf(47613, 47614, 47615)

        private val random = SecureRandom()

        private fun randomBytes(count: Int) = ByteArray(count).also(random::nextBytes)
    }
}
