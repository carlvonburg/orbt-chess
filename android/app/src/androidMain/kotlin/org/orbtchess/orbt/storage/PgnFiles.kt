package org.orbtchess.orbt.storage

import android.content.ContentResolver
import android.net.Uri
import android.provider.OpenableColumns
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.FileNotFoundException

// Import and export through the Storage Access Framework (Files on Apple): the UI gets a
// `Uri` from ACTION_OPEN_DOCUMENT or ACTION_CREATE_DOCUMENT.

/** A PGN picked with ACTION_OPEN_DOCUMENT: its bytes and a name for it. The setup flow then
 *  copies it into the library with `RepertoireLibrary.importPgn`. */
suspend fun readImport(resolver: ContentResolver, uri: Uri): RepertoireLibrary.ImportedFile =
    withContext(Dispatchers.IO) {
        val data = resolver.openInputStream(uri)?.use { it.readBytes() }
            ?: throw FileNotFoundException(uri.toString())
        val displayName = resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        } ?: uri.lastPathSegment ?: ""
        RepertoireLibrary.ImportedFile(data, RepertoireLibrary.importName(displayName))
    }

/** Writes a repertoire's PGN to a document made with ACTION_CREATE_DOCUMENT. */
suspend fun exportPgn(documents: Documents, entry: RepertoireEntry, resolver: ContentResolver, uri: Uri) {
    val data = documents.pgnForExport(entry)
    withContext(Dispatchers.IO) {
        resolver.openOutputStream(uri, "wt")?.use { it.write(data) } ?: throw FileNotFoundException(uri.toString())
    }
}
