import Foundation
import OpeningCoreRust

/// The conflict copies Dropbox or Google Drive for desktop leave in a folder chosen on the Mac
/// (`Najdorf (Carl's conflicted copy 2026-10-30).pgn`, `Najdorf (1).otrep.json`): each is
/// merged into its original with the core's merges, as an iCloud conflict version is, then
/// deleted (`FileAccess.resolveConflicts`). Only there: in iCloud Drive such names are the
/// user's own files.
nonisolated enum ConflictCopies {
    /// Each copy and the original it stands for, among a folder's file names (originals that
    /// exist only). Which names are copies is the core's rule.
    nonisolated(unsafe) static var pairs: @Sendable ([String]) -> [(copy: String, original: String)] = { names in
        syncConflictCopies(names: names).map { ($0.copy, $0.original) }
    }

    /// The copies of `url` next to it, when it is in the chosen folder.
    static func copies(of url: URL) -> [URL] {
        guard FileAccessHooks.shared.isInChosenFolder(url) else { return [] }
        let folder = url.deletingLastPathComponent()
        let original = url.lastPathComponent
        return pairs(names(in: folder)).filter { $0.original == original }.map { folder.appending(path: $0.copy) }
    }

    /// Every copy in the chosen folder `folder`.
    static func all(in folder: URL) -> Set<String> {
        guard FileAccessHooks.shared.isInChosenFolder(folder.appending(path: "x")) else { return [] }
        return Set(pairs(names(in: folder)).map(\.copy))
    }

    private static func names(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }
}
