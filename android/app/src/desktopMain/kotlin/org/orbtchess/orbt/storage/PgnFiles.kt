package org.orbtchess.orbt.storage

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

// Import and export of PGN files picked in the desktop's file dialogs.

/** A picked PGN: its bytes and a name for it. The setup flow then copies it into the
 *  library with `RepertoireLibrary.importPgn`. */
suspend fun readImport(file: File): RepertoireLibrary.ImportedFile = withContext(Dispatchers.IO) {
    RepertoireLibrary.ImportedFile(FileAccess.read(file), RepertoireLibrary.importName(file.name))
}

/** Writes a repertoire's PGN to a file the user chose. */
suspend fun exportPgn(documents: Documents, entry: RepertoireEntry, destination: File) {
    val data = documents.pgnForExport(entry)
    withContext(Dispatchers.IO) { destination.writeBytes(data) }
}
