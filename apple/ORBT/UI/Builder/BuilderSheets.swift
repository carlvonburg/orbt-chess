import OpeningCoreRust
import SwiftUI

/// The repertoire as a collapsible tree. Chains without branching are shown as one row.
struct OutlineSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: BuilderModel
    let onTrain: (NodeID) -> Void
    @State private var search = ""

    struct Item: Identifiable {
        let id: NodeID  // last node of the chain
        let first: NodeID
        let text: String
        var children: [Item]?
    }

    var body: some View {
        NavigationStack {
            List {
                if search.isEmpty {
                    OutlineGroup(items(under: RepertoireTree.rootID), children: \.children) { item in
                        row(item)
                    }
                } else {
                    ForEach(matches, id: \.self) { id in
                        Button { open(id) } label: {
                            Text(model.tree.lineText(to: id)).font(.callout).lineLimit(2)
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Find a move, e.g. Nf3")
            .navigationTitle("Outline")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
    }

    private func row(_ item: Item) -> some View {
        let document = model.document
        let completion = document.coverage[item.id]?.completion ?? 0
        let gaps = document.coverage[item.id]?.gapCount ?? 0
        return Button { open(item.id) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.text)
                    .font(.callout.monospacedDigit())
                    .fontWeight(item.id == model.current ? .bold : .regular)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    CoverageBar(value: completion).frame(width: 60)
                    if gaps > 0 { Text("\(gaps) gaps").font(.caption2).foregroundStyle(.todo) }
                }
            }
        }
        .tint(.primary)
        .contextMenu {
            Button("Train This Branch", systemImage: "graduationcap") {
                dismiss()
                onTrain(item.first)
            }
            if item.first != RepertoireTree.rootID {
                Button("Make Main Line", systemImage: "arrow.up.to.line") { document.promote(item.first) }
                Button("Delete From Here", systemImage: "trash", role: .destructive) { model.delete(item.first) }
            }
        }
    }

    private func open(_ id: NodeID) {
        model.go(to: id)
        dismiss()
    }

    private func items(under id: NodeID) -> [Item] {
        model.document.core.outlineChildren(id: id).map { item in
            Item(id: item.id, first: item.first, text: item.text, children: item.hasChildren ? items(under: item.id) : nil)
        }
    }

    private var matches: [NodeID] {
        model.document.core.search(query: search, limit: 100)
    }
}

struct GapsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: BuilderModel

    var body: some View {
        let document = model.document
        let gaps = document.coverage.gaps()
        NavigationStack {
            List {
                if gaps.isEmpty {
                    ContentUnavailableView(document.coverage.root?.pendingCount ?? 0 > 0 ? "Still loading statistics" : "No gaps",
                                           systemImage: "checkmark.seal",
                                           description: Text("Every opponent move seen at least once in \(document.sidecar.targetGames.formatted()) games has an answer."))
                }
                ForEach(gaps.prefix(200), id: \.self) { gap in
                    Button {
                        model.go(to: gap)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(text(for: gap)).font(.callout).lineLimit(2)
                            Text(Format.seenGames(gap.mass))
                                .font(.caption).foregroundStyle(.todo)
                        }
                    }
                    .tint(.primary)
                    .swipeActions(edge: .trailing) {
                        if case let .missingReply(uci, _) = gap.kind {
                            Button("Exclude", systemImage: "nosign") {
                                document.setExcluded(uci, at: gap.node, true)
                            }
                            .tint(.gray)
                        }
                    }
                }
            }
            .navigationTitle("\(gaps.count) Gaps")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
    }

    private func text(for gap: CoverageGap) -> String {
        model.document.core.gapText(gap: gap)
    }
}

struct NoteSheet: View {
    @Environment(\.dismiss) private var dismiss
    let document: RepertoireDocument
    let node: NodeID
    @State private var text = ""

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .padding(.horizontal)
                .navigationTitle(document.tree.lineText(to: node).split(separator: " ").suffix(2).joined(separator: " "))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", systemImage: "xmark") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save", systemImage: "checkmark") {
                            document.setNote(text, for: node)
                            dismiss()
                        }
                    }
                }
                .onAppear { text = document.tree[node]?.note ?? "" }
        }
    }
}
