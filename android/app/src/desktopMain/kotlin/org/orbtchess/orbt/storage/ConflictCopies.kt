package org.orbtchess.orbt.storage

/**
 * The name of the file a provider's conflict copy stands for, or null when `name` is not one.
 * Dropbox's client keeps both versions when two devices change a file at once, the other one as
 * `Name (Carl's conflicted copy 2026-10-30).pgn` (before the last extension, so a sidecar's is
 * `Name.otrep (… conflicted copy …).json`); Google Drive for desktop as `Name_conf(1).pgn`.
 *
 * TODO: the core's rule once core-sync adds it to `orbt_core::sync` (exposed through orbt-ffi);
 * this is the only place to change.
 */
fun conflictCopyOriginal(name: String): String? {
    if (name.startsWith(".")) return null
    val original = name.replace(DROPBOX, "").replace(DRIVE, "")
    return original.takeIf { it != name && it.isNotEmpty() }
}

private val DROPBOX = Regex(""" \([^()]*conflicted copy[^()]*(?:\(\d+\)[^()]*)?\)""")
private val DRIVE = Regex("""_conf\(\d+\)(?=\.[^.]+$)""")
