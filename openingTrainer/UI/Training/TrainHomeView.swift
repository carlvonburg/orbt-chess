import OpeningCore
import SwiftUI

/// Training tab: due reviews and new moves per repertoire. Works offline.
struct TrainHomeView: View {
    @Environment(AppModel.self) private var model
    @State private var drill: (doc: RepertoireDocument, mode: DrillMode)?

    var body: some View {
        NavigationStack {
            List {
                let entries = model.library.entries.filter { !$0.needsSetup }
                if entries.isEmpty {
                    ContentUnavailableView("Nothing to train yet", systemImage: "graduationcap",
                                           description: Text("Create a repertoire and add some moves first."))
                }
                ForEach(entries) { entry in
                    if let doc = model.document(for: entry) {
                        TrainRow(name: entry.name, document: doc) { mode in drill = (doc, mode) }
                    }
                }
            }
            .navigationTitle("Train")
        }
        .fullScreenCover(isPresented: Binding(get: { drill != nil }, set: { if !$0 { drill = nil } })) {
            if let drill {
                DrillView(document: drill.doc, mode: drill.mode)
            }
        }
    }
}

private struct TrainRow: View {
    let name: String
    let document: RepertoireDocument
    let start: (DrillMode) -> Void

    var body: some View {
        let _ = document.revision
        let progress = document.learningProgress()
        let unseen = progress.cards - progress.seen
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SideIcon(side: document.color)
                    VStack(alignment: .leading) {
                        Text(name).font(.headline)
                        Text("\(progress.cards) positions · \(progress.mature) mastered")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    Text("Seen").font(.caption2).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
                    CompletionBar(value: progress.seenFraction, tint: .teal)
                    Text(Format.percent(progress.seenFraction)).font(.caption2.monospacedDigit())
                }
                HStack(spacing: 6) {
                    Text("Mastered").font(.caption2).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
                    CompletionBar(value: progress.matureFraction, tint: .blue)
                    Text(Format.percent(progress.matureFraction)).font(.caption2.monospacedDigit())
                }
                GlassEffectContainer {
                    HStack {
                        Button { start(.due) } label: {
                            Label("Review \(progress.due)", systemImage: "clock.arrow.circlepath").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(progress.due == 0)
                        Button { start(.learnNew) } label: {
                            Label("Learn \(min(unseen, DrillModel.newPerSession))", systemImage: "sparkles").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .disabled(unseen == 0)
                    }
                }
                Button { start(.branch(RepertoireTree.rootID)) } label: {
                    Label("Play all lines", systemImage: "list.bullet").font(.footnote)
                }
                .buttonStyle(.borderless)
                .disabled(progress.cards == 0)
            }
            .padding(.vertical, 6)
        }
    }
}
