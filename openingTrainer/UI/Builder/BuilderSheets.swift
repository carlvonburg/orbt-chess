import OpeningCore
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
            .navigationBarTitleDisplayMode(.inline)
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
                    CompletionBar(value: completion, tint: .green, height: 4).frame(width: 60)
                    if gaps > 0 { Text("\(gaps) gaps").font(.caption2).foregroundStyle(.orange) }
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
        guard let node = model.tree[id] else { return [] }
        return node.children.map { chain(from: $0) }
    }

    /// Follows single-child chains and returns one item for them.
    private func chain(from start: NodeID) -> Item {
        let tree = model.tree
        var cursor = start
        var parts: [String] = []
        var first = true
        while let node = tree[cursor], let move = node.move {
            let ply = node.ply - 1
            if ply % 2 == 0 { parts.append("\(ply / 2 + 1).") } else if first { parts.append("\(ply / 2 + 1)...") }
            parts.append(move.san)
            first = false
            guard node.children.count == 1 else { break }
            cursor = node.children[0]
        }
        let children = tree[cursor]?.children.isEmpty == false ? items(under: cursor) : nil
        return Item(id: cursor, first: start, text: parts.joined(separator: " "), children: children)
    }

    private var matches: [NodeID] {
        let query = SAN.loose(search.trimmingCharacters(in: .whitespaces)).lowercased()
        guard !query.isEmpty else { return [] }
        return model.tree.nodes.values
            .filter { SAN.loose($0.move?.san ?? "").lowercased() == query || $0.note.lowercased().contains(query) }
            .sorted { $0.ply < $1.ply }
            .prefix(100)
            .map(\.id)
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
                            Text("Seen \(Format.seenEvery(gap.mass)) games")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .tint(.primary)
                }
            }
            .navigationTitle("\(gaps.count) Gaps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
    }

    private func text(for gap: CoverageGap) -> String {
        let line = model.tree.lineText(to: gap.node)
        switch gap.kind {
        case .missingMove:
            return (line.isEmpty ? "Start" : line) + " — your move?"
        case let .missingReply(_, san):
            let ply = model.tree[gap.node]?.ply ?? 0
            let number = ply % 2 == 0 ? "\(ply / 2 + 1). " : (line.isEmpty ? "\(ply / 2 + 1)... " : "")
            return [line, number + san].filter { !$0.isEmpty }.joined(separator: " ")
        }
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
                .navigationBarTitleDisplayMode(.inline)
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

struct PastePGNSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: BuilderModel
    @State private var text = ""
    @State private var result: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .font(.callout.monospaced())
                        .frame(minHeight: 200)
                } footer: {
                    Text("Paste moves with variations and comments, e.g. from a book or a Lichess study. Lines from the starting position are merged at the start; others are added after the current move.")
                }
                if let result {
                    Text(result)
                }
            }
            .navigationTitle("Paste PGN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Merge", systemImage: "checkmark") {
                        let added = model.document.mergePGN(text, at: model.current)
                        if added > 0 {
                            dismiss()
                        } else {
                            result = "No new moves found. Check that the moves are legal from the start or the current position."
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if let clip = UIPasteboard.general.string, clip.contains(".") { text = clip }
            }
        }
    }
}
