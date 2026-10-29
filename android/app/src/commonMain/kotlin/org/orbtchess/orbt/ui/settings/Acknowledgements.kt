package org.orbtchess.orbt.ui.settings

/** The app's pages on the web (`AppLinks` in Swift). */
internal object AppLinks {
    const val WEBSITE = "https://orbtchess.org"
    const val PRIVACY = "https://orbtchess.org/privacy"
    const val SUPPORT = "https://orbtchess.org/support"
    const val SOURCE = "https://github.com/carlvonburg/orbt-chess"
}

/** What the app ships besides the crates and libraries (those are in Acknowledgements.json). */
internal class Component(
    val name: String,
    /** The license's text: a key of Acknowledgements.json's `licenses`. */
    val text: String,
    /** Shown above the license text, where the license asks for attribution. */
    val attribution: String? = null,
) {
    companion object {
        val all = listOf(
            Component("Stockfish", "GPL-3.0"),
            Component("multistockfish", "GPL-3.0"),
            Component("Anki", "AGPL-3.0"),
            // CC BY-NC 4.0 §3(a): the creator, a link to the work, and that it was changed.
            Component(
                "Lumbra's Gigabase", "CC-BY-NC-4.0",
                attribution = "Lumbra's Gigabase by Lumbra (lumbrasgigabase.com), licensed under CC BY-NC 4.0. ORBT Chess " +
                    "reduces its over-the-board games since 2000 to the move counts of the Classical coverage tables.",
            ),
        )
    }
}

/**
 * `files/Acknowledgements.json`, which `core/scripts/acknowledgements.py --android` writes: the
 * license texts the app bundles, every crate linked into it and the Kotlin and Java libraries it
 * ships (`libraries`, the same fields).
 */
internal class Acknowledgements(val licenses: Map<String, String>, val crates: List<Crate>, val libraries: List<Crate> = emptyList()) {
    class Crate(
        val name: String,
        val version: String,
        val license: String,
        val repository: String,
        val text: String?,
        val shared: String?,
    )

    fun text(crate: Crate): String = crate.text ?: crate.shared?.let { licenses[it] } ?: ""

    companion object {
        val empty = Acknowledgements(emptyMap(), emptyList())

        @Suppress("UNCHECKED_CAST")
        private fun crates(list: Any?): List<Crate> = (list as? List<Map<String, Any?>>).orEmpty().map {
            Crate(
                name = it["name"] as String,
                version = it["version"] as? String ?: "",
                license = it["license"] as? String ?: "",
                repository = it["repository"] as? String ?: "",
                text = it["text"] as? String,
                shared = it["shared"] as? String,
            )
        }

        @Suppress("UNCHECKED_CAST")
        fun decode(bytes: ByteArray): Acknowledgements = runCatching {
            val root = Json(bytes.toString(Charsets.UTF_8)).value() as Map<String, Any?>
            val licenses = (root["licenses"] as Map<String, Any?>).mapValues { it.value as String }
            Acknowledgements(licenses, crates(root["crates"]), crates(root["libraries"]))
        }.getOrDefault(empty)
    }
}

/** A small JSON reader for the bundled file (the app has no JSON library). */
private class Json(private val s: String) {
    private var i = 0

    fun value(): Any? {
        skip()
        return when (s[i]) {
            '{' -> obj()
            '[' -> array()
            '"' -> string()
            't' -> literal("true", true)
            'f' -> literal("false", false)
            'n' -> literal("null", null)
            else -> number()
        }
    }

    private fun skip() {
        while (i < s.length && s[i].isWhitespace()) i++
    }

    private fun expect(c: Char) {
        skip()
        require(s[i] == c) { "Expected $c at $i" }
        i++
    }

    private fun obj(): Map<String, Any?> {
        expect('{')
        val result = LinkedHashMap<String, Any?>()
        skip()
        if (s[i] == '}') return result.also { i++ }
        while (true) {
            skip()
            val key = string()
            expect(':')
            result[key] = value()
            skip()
            if (s[i++] == '}') return result
        }
    }

    private fun array(): List<Any?> {
        expect('[')
        val result = mutableListOf<Any?>()
        skip()
        if (s[i] == ']') return result.also { i++ }
        while (true) {
            result += value()
            skip()
            if (s[i++] == ']') return result
        }
    }

    private fun string(): String {
        expect('"')
        val out = StringBuilder()
        while (true) {
            when (val c = s[i++]) {
                '"' -> return out.toString()
                '\\' -> when (val e = s[i++]) {
                    'n' -> out.append('\n')
                    't' -> out.append('\t')
                    'r' -> out.append('\r')
                    'b' -> out.append('\b')
                    'f' -> out.append('\u000C')
                    'u' -> out.append(s.substring(i, i + 4).toInt(16).toChar()).also { i += 4 }
                    else -> out.append(e)
                }
                else -> out.append(c)
            }
        }
    }

    private fun literal(word: String, value: Any?): Any? {
        require(s.startsWith(word, i))
        i += word.length
        return value
    }

    private fun number(): Double {
        val start = i
        while (i < s.length && (s[i].isDigit() || s[i] in "+-.eE")) i++
        return s.substring(start, i).toDouble()
    }
}

/**
 * License files wrap at 80 columns; on a phone a paragraph's lines read better joined, so only
 * blank lines and list items ("1.", "a.", "(i)", "-") start a new line.
 */
internal fun reflowed(text: String): String {
    val item = Regex("^([0-9]+\\.|[a-z]\\.|\\([a-z0-9]+\\)|[-*•])\\s")
    val result = StringBuilder()
    var previousEmpty = true
    for (line in text.split("\n")) {
        val trimmed = line.trimStart()
        if (result.isNotEmpty()) {
            result.append(if (previousEmpty || trimmed.isEmpty() || item.containsMatchIn(trimmed)) "\n" else " ")
        }
        result.append(trimmed)
        previousEmpty = trimmed.isEmpty()
    }
    return result.toString()
}
