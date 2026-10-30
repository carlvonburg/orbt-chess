package org.orbtchess.orbt.storage

import org.orbtchess.orbt.core.syncConflictCopies
import org.orbtchess.orbt.core.syncConflictOriginal
import java.io.File

/**
 * The name of the file a provider's conflict copy would stand for, or null when `name` doesn't
 * read as one (the core's rule, `orbt_core::sync`): Dropbox's `Name (Carl's conflicted copy
 * 2026-10-30).pgn`, Google Drive for desktop's `Name (1).pgn`, before the whole extension or its
 * last part (`Name.otrep (1).json`). A name alone can't tell a copy from a repertoire named
 * "Najdorf (2)": [conflictCopies] pairs them with an original that is there.
 */
fun conflictCopyOriginal(name: String): String? = if (name.startsWith(".")) null else syncConflictOriginal(name)

/** The conflict copies among a folder's file names, by copy, each with its original (only
 *  copies whose original is among `names`). */
fun conflictCopies(names: Collection<String>): Map<String, String> =
    syncConflictCopies(names.filter { !it.startsWith(".") }).associate { it.copy to it.original }

/** Whether `name` in `folder` is a conflict copy of a file that is there. */
fun isConflictCopy(folder: File, name: String): Boolean =
    conflictCopyOriginal(name)?.let { File(folder, it).exists() } == true
