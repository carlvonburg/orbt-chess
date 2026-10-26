import OpeningCoreRust
import SwiftUI

/// Studies today's moves of every repertoire, one repertoire after another in name order (Anki's
/// deck order). Unlike studying an Anki parent deck, reviews are not mixed across
/// repertoires, so each line stays within one PGN. Pushed like Study Now, not presented; the
/// library makes the model (`LibraryScreens`).
struct StudyAllView: View {
    @Environment(AppModel.self) private var app
    let model: StudyAllModel

    var body: some View {
        if let drill = model.drill {
            DrillView(model: drill, next: nextRepertoire)
                .id(model.index)
        } else if model.index < model.entries.count {
            ProgressView("Opening \(model.entries[model.index].name)…")
        }
    }

    private var nextRepertoire: (name: String, start: () -> Void)? {
        guard let next = model.next else { return nil }
        return (next.name, { Task { await model.advance(app: app) } })
    }
}
