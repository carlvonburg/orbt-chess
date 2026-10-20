import Foundation
import OpeningCoreRust

/// Review logs of library entries, from the open document or read from disk.
enum StudyLog {
    static func revlog(for entry: RepertoireEntry, in app: AppModel) async -> [RevlogEntry] {
        if let doc = app.documents[entry.id] { return await doc.reviewLog() }
        return await read(RepertoireLibrary.revlogURL(for: entry.pgnURL))
    }

    nonisolated static func read(_ url: URL) async -> [RevlogEntry] {
        decodeRevlog(data: await readData(url))
    }

    /// The log file's bytes, read off the main actor; empty when there is none.
    nonisolated static func readData(_ url: URL) async -> Data {
        await Task.detached {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            return (try? FileAccess.read(url)) ?? Data()
        }.value
    }
}
