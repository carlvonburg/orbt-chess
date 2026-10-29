package org.orbtchess.orbt.lichess

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import org.orbtchess.orbt.core.HttpRequest
import org.orbtchess.orbt.core.PlayedMove
import org.orbtchess.orbt.core.Side
import org.orbtchess.orbt.core.SignInException
import org.orbtchess.orbt.core.lichessAccountRequest
import org.orbtchess.orbt.core.lichessAnalysisUrl
import org.orbtchess.orbt.core.lichessAuthorizeUrl
import org.orbtchess.orbt.core.lichessParseAccount
import org.orbtchess.orbt.core.lichessParseCallback
import org.orbtchess.orbt.core.lichessParseToken
import org.orbtchess.orbt.core.lichessRandomString
import org.orbtchess.orbt.core.lichessRevokeRequest
import org.orbtchess.orbt.core.lichessTokenRequest
import org.orbtchess.orbt.platform.Http
import org.orbtchess.orbt.platform.SecretStore
import java.net.URLEncoder
import java.security.SecureRandom

/**
 * Shows Lichess's sign-in page and waits for its redirect: a Custom Tab and the app's custom
 * scheme on Android (`CustomTabAuthBrowser`), the default browser and a loopback server on
 * the desktop (`LoopbackAuthBrowser`). `ASWebAuthenticationSession` in the Swift app.
 */
fun interface AuthBrowser {
    /**
     * Opens `authorizeUrl(redirectUri)` for the redirect URI this browser receives, and returns
     * the URL Lichess redirected to, or null when the user cancelled.
     */
    suspend fun authenticate(authorizeUrl: (redirectUri: String) -> String): String?
}

/**
 * Lichess OAuth2 with PKCE. No client registration and no scopes are needed; the
 * explorer only requires a valid token. Tokens last about a year and have no refresh.
 * The requests, the PKCE challenge, the callback check and the answers are in the core;
 * this runs the browser, sends the requests and keeps the token in the `SecretStore`.
 * `apple/ORBT/Lichess/LichessAuth.swift`. Used from the main thread.
 */
class LichessAuth(private val secrets: SecretStore) {
    var token by mutableStateOf<String?>(null)
        private set
    var username by mutableStateOf<String?>(null)
        private set
    /** Unix seconds. */
    var expiresAt by mutableStateOf<Long?>(null)
        private set
    var lastError by mutableStateOf<String?>(null)

    val isSignedIn: Boolean get() = token != null

    init {
        secrets.get(TOKEN_KEY)?.let(StoredToken::decode)
            ?.takeIf { it.expiresAt > System.currentTimeMillis() / 1000 }
            ?.let { saved ->
                token = saved.token
                username = saved.username
                expiresAt = saved.expiresAt
            }
    }

    /** Runs the browser sign-in. Returns false when the user cancelled. */
    suspend fun signIn(browser: AuthBrowser): Boolean {
        lastError = null
        val verifier = lichessRandomString(randomBytes(64))
        val state = lichessRandomString(randomBytes(32))
        return try {
            var redirectUri = CORE_REDIRECT_URI
            val callback = browser.authenticate { uri ->
                redirectUri = uri
                authorizeUrl(verifier, state, uri)
            } ?: return false
            val code = lichessParseCallback(callback, state) ?: return false  // the user declined
            exchange(code, verifier, redirectUri)
            true
        } catch (error: SignInException) {
            lastError = (error as? SignInException.Failed)?.reason ?: error.message
            false
        }
    }

    suspend fun signOut() {
        token?.let { Http.send(lichessRevokeRequest(it)) }
        clear()
    }

    /** Called when Lichess answered 401: the token was revoked or expired. */
    fun tokenRejected() {
        clear()
        lastError = "Your Lichess session expired. Please sign in again."
    }

    private fun clear() {
        token = null
        username = null
        expiresAt = null
        secrets.remove(TOKEN_KEY)
    }

    private suspend fun exchange(code: String, verifier: String, redirectUri: String) {
        val response = Http.send(tokenRequest(code, verifier, redirectUri))
            ?: throw SignInException.Failed("Could not reach Lichess")
        val parsed = lichessParseToken(response, System.currentTimeMillis() / 1000)
        token = parsed.token
        expiresAt = parsed.expiresAt
        username = Http.send(lichessAccountRequest(parsed.token))?.let(::lichessParseAccount)
        persist()
    }

    private fun persist() {
        val token = token ?: return
        val expiresAt = expiresAt ?: return
        secrets.set(TOKEN_KEY, StoredToken(token, username, expiresAt).encode())
    }

    /** One line each: the token, its expiry (unix seconds), the username (may be empty). */
    private data class StoredToken(val token: String, val username: String?, val expiresAt: Long) {
        fun encode() = listOf(token, expiresAt.toString(), username.orEmpty()).joinToString("\n")

        companion object {
            fun decode(text: String): StoredToken? {
                val parts = text.split("\n")
                if (parts.size != 3) return null
                val expiresAt = parts[1].toLongOrNull() ?: return null
                return StoredToken(parts[0], parts[2].ifEmpty { null }, expiresAt)
            }
        }
    }

    private companion object {
        const val TOKEN_KEY = "lichess-token"
        val random = SecureRandom()

        fun randomBytes(count: Int) = ByteArray(count).also(random::nextBytes)
    }
}

/** The redirect the core's requests name: the app's custom scheme (Apple, Android). */
internal const val CORE_REDIRECT_URI = "org.orbtchess.orbt://oauth-callback"

// TODO(core): let `lichessAuthorizeUrl` and `lichessTokenRequest` take the redirect URI. Until
// then the desktop's loopback URI replaces the core's in the URL and the form body, both
// form-encoded by the core as `URLEncoder` does.
private fun encoded(uri: String) = URLEncoder.encode(uri, "UTF-8")

/** The core's authorize URL, redirecting to `redirectUri`. */
internal fun authorizeUrl(verifier: String, state: String, redirectUri: String): String {
    val url = lichessAuthorizeUrl(verifier, state)
    if (redirectUri == CORE_REDIRECT_URI) return url
    check(encoded(CORE_REDIRECT_URI) in url) { "The core's redirect URI changed" }
    return url.replace(encoded(CORE_REDIRECT_URI), encoded(redirectUri))
}

/** The core's token request, for a code sent to `redirectUri`. */
internal fun tokenRequest(code: String, verifier: String, redirectUri: String): HttpRequest {
    val request = lichessTokenRequest(code, verifier)
    if (redirectUri == CORE_REDIRECT_URI) return request
    val body = request.body.toString(Charsets.UTF_8)
    check(encoded(CORE_REDIRECT_URI) in body) { "The core's redirect URI changed" }
    return request.copy(body = body.replace(encoded(CORE_REDIRECT_URI), encoded(redirectUri)).toByteArray())
}

object LichessLinks {
    /** The line in the Lichess analysis board, keeping the move history. */
    fun analysis(moves: List<PlayedMove>, orientation: Side): String = lichessAnalysisUrl(moves, orientation)
}
