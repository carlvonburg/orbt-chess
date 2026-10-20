import Foundation
import OpeningCoreRust

/// Review logs of library entries, from the open document or read from disk.
enum StudyLog {
    static func revlog(for entry: RepertoireEntry, in app: AppModel) async -> [RevlogEntry] {
        if let doc = app.documents[entry.id] { return doc.reviewLog() }
        return await read(RepertoireLibrary.revlogURL(for: entry.pgnURL))
    }

    nonisolated static func read(_ url: URL) async -> [RevlogEntry] {
        let data = await Task.detached {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            return try? FileAccess.read(url)
        }.value
        return data.map { decodeRevlog(data: $0) } ?? []
    }
}
