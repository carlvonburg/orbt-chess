package org.orbtchess.orbt.lichess

import kotlinx.coroutines.runBlocking
import org.orbtchess.orbt.core.lichessParseCallback
import org.orbtchess.orbt.platform.SecretStore
import java.net.HttpURLConnection
import java.net.URI
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class MemorySecrets : SecretStore {
    val values = mutableMapOf<String, String>()
    override fun get(key: String) = values[key]
    override fun set(key: String, value: String) { values[key] = value }
    override fun remove(key: String) { values.remove(key) }
}

class LichessAuthTest {
    @Test
    fun theLoopbackRedirectReplacesTheCoresInBothRequests() {
        val loopback = "http://127.0.0.1:5123/"
        val url = authorizeUrl("verifier", "state", loopback)
        assertTrue("redirect_uri=http%3A%2F%2F127.0.0.1%3A5123%2F" in url, url)
        assertFalse("oauth-callback" in url)
        val body = tokenRequest("code", "verifier", loopback).body.toString(Charsets.UTF_8)
        assertTrue("redirect_uri=http%3A%2F%2F127.0.0.1%3A5123%2F" in body, body)
        // The app's scheme is left as the core writes it.
        assertTrue("oauth-callback" in authorizeUrl("verifier", "state", CORE_REDIRECT_URI))
    }

    @Test
    fun theLoopbackServerReturnsTheRedirect() = runBlocking {
        var opened: String? = null
        val browser = LoopbackAuthBrowser(openUrl = { url ->
            opened = url
            // Lichess redirecting the browser to the loopback server.
            val redirect = Regex("redirect_uri=([^&]+)").find(url)!!.groupValues[1]
                .let { java.net.URLDecoder.decode(it, "UTF-8") }
            Thread {
                val connection = URI("${redirect}?code=abc&state=xyz").toURL().openConnection() as HttpURLConnection
                connection.inputStream.use { it.readBytes() }
            }.start()
        })
        val callback = browser.authenticate { uri -> authorizeUrl("verifier", "xyz", uri) }!!
        assertTrue(opened!!.startsWith("https://lichess.org/oauth?"))
        assertEquals("abc", lichessParseCallback(callback, "xyz"))
    }

    @Test
    fun aStoredTokenIsReadBackAndRejectionClearsIt() {
        val secrets = MemorySecrets()
        secrets.set("lichess-token", "tok\n${System.currentTimeMillis() / 1000 + 3600}\nmagnus")
        val auth = LichessAuth(secrets)
        assertEquals("tok", auth.token)
        assertEquals("magnus", auth.username)
        auth.tokenRejected()
        assertFalse(auth.isSignedIn)
        assertNull(secrets.get("lichess-token"))
        // An expired token is dropped.
        secrets.set("lichess-token", "tok\n1\n")
        assertFalse(LichessAuth(secrets).isSignedIn)
    }
}
