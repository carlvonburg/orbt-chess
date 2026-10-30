package org.orbtchess.orbt.sync

import org.orbtchess.orbt.core.Header
import org.orbtchess.orbt.core.HttpMethod
import org.orbtchess.orbt.core.HttpRequest
import java.net.URLEncoder
import java.security.MessageDigest
import java.util.Base64

// TODO(core): Dropbox's sign-in requests, as the core has Lichess's (`lichess::authorize_url`,
// `token_request`): OAuth plumbing only, kept here until the Apple app needs them too. Once
// signed in, every request (the refresh included) is the core's (`sync::dropbox`).

/** Dropbox's redirect to the app (registered in Dropbox's app console). */
const val DROPBOX_REDIRECT_URI = "org.orbtchess.orbt://dropbox-callback"

private fun encoded(value: String) = URLEncoder.encode(value, "UTF-8")

private fun form(fields: List<Pair<String, String>>) = fields.joinToString("&") { (k, v) -> "$k=${encoded(v)}" }

/** The S256 PKCE challenge: base64url (no padding) of SHA-256 of the verifier. */
internal fun pkceChallenge(verifier: String): String =
    Base64.getUrlEncoder().withoutPadding().encodeToString(MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray()))

/** The page that asks the user to allow access to the App folder, for a refresh token. */
fun dropboxAuthorizeUrl(appKey: String, verifier: String, state: String, redirectUri: String = DROPBOX_REDIRECT_URI): String =
    "https://www.dropbox.com/oauth2/authorize?" + form(
        listOf(
            "client_id" to appKey,
            "response_type" to "code",
            "token_access_type" to "offline",
            "code_challenge" to pkceChallenge(verifier),
            "code_challenge_method" to "S256",
            "redirect_uri" to redirectUri,
            "state" to state,
        ),
    )

/** Exchanges the code from the redirect for a refresh token (and a first access token). */
fun dropboxTokenRequest(appKey: String, code: String, verifier: String, redirectUri: String = DROPBOX_REDIRECT_URI) = HttpRequest(
    method = HttpMethod.POST,
    url = "https://api.dropboxapi.com/oauth2/token",
    headers = listOf(Header("Content-Type", "application/x-www-form-urlencoded")),
    body = form(
        listOf(
            "grant_type" to "authorization_code",
            "code" to code,
            "code_verifier" to verifier,
            "client_id" to appKey,
            "redirect_uri" to redirectUri,
        ),
    ).toByteArray(),
    timeoutSecs = 60u,
)

/** The signed-in account (its email, for Settings). */
fun dropboxAccountRequest(accessToken: String) = HttpRequest(
    method = HttpMethod.POST,
    url = "https://api.dropboxapi.com/2/users/get_current_account",
    headers = listOf(Header("Authorization", "Bearer $accessToken")),
    body = ByteArray(0),
    timeoutSecs = 60u,
)
