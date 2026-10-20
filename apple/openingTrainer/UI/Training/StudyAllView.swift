import OpeningCoreRust
import SwiftUI

/// Studies today's moves of every repertoire, one repertoire after another in name order (Anki's
/// deck order). Unlike studying an Anki parent deck, reviews are not mixed across
/// repertoires, so each line stays within one PGN. Pushed like Study Now, not presented.
struct StudyAllView: View {
    let entries: [RepertoireEntry]
    @State private var index = 0

    var body: some View {
        if index < entries.count {
            let entry = entries[index]
            OpenDocument(entry: entry) { doc in
                DrillView(document: doc, mode: .study, pushed: true, next: nextRepertoire)
                    .id(entry.id)
            } placeholder: {
                ProgressView("Opening \(entry.name)…")
            }
        }
    }

    private var nextRepertoire: (name: String, start: () -> Void)? {
        guard index + 1 < entries.count else { return nil }
        return (entries[index + 1].name, { index += 1 })
    }
}
