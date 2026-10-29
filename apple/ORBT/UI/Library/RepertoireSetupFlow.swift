import OpeningCoreRust
import SwiftUI

/// A new or imported repertoire, set up one step at a time: its name and side, the opponents'
/// games, how much to learn. Each setting decides which replies are gaps, so each has a page;
/// Repertoire Settings edits them later on one page (`RepertoireSettingsForm`).
struct RepertoireSetupFlow: View {
    enum Mode {
        /// A new repertoire, its side already chosen when started from the empty library.
        case new(side: Side?)
        /// A PGN picked from Files: nothing is written until it is added.
        case importing(data: Data, name: String)
        /// A PGN dropped into the folder without settings; its name is its file's.
        case setup(RepertoireEntry)
    }

    private enum Step: Hashable { case opponents, depth }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    let onDone: (RepertoireEntry) -> Void
    @State private var name: String
    @State private var draft: RepertoireSettingsDraft
    @State private var path: [Step] = []
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    init(mode: Mode, onDone: @escaping (RepertoireEntry) -> Void) {
        self.mode = mode
        self.onDone = onDone
        var draft = RepertoireSettingsDraft.lastUsed()
        switch mode {
        case .new(let side):
            _name = State(initialValue: "")
            if let side { draft.color = side }
        case .importing(_, let name):
            _name = State(initialValue: name)
        case .setup(let entry):
            _name = State(initialValue: entry.name)
        }
        _draft = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack(path: $path) {
            opening
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .opponents: opponents
                    case .depth: depth
                    }
                }
        }
    }

    // MARK: Steps

    private var opening: some View {
        Form {
            Section("Name") {
                if case .setup = mode {
                    Text(name)
                } else {
                    TextField("Name", text: $name, prompt: Text("Najdorf"))
                        .labelsHidden()
                        .wordsAutocapitalization()
                        .focused($nameFocused)
                        .submitLabel(.next)
                        .onSubmit { if canContinue { path = [.opponents] } }
                        .onChange(of: name) { name = name.safeRepertoireName }
                }
            }
            Section {
                SidePicker(side: $draft.color)
            } header: {
                Text("I play")
            } footer: {
                Text("You learn this side's moves and prepare for the other side's replies.")
            }
            if let error {
                Text(error).foregroundStyle(.failure)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(title)
        .navigationSubtitle("Step 1 of 3")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", systemImage: "xmark") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Next") { path = [.opponents] }
                    .disabled(!canContinue)
            }
        }
        .onAppear {
            if case .new = mode { nameFocused = true }
        }
    }

    private var opponents: some View {
        Form {
            Section {
            } footer: {
                Text("Gaps are the replies your opponents play often that you haven't answered yet. They come from games at your opponents' level.")
            }
            CoverageSourceSection(draft: $draft, style: .list)
        }
        .formStyle(.grouped)
        .navigationTitle("Your Opponents")
        .navigationSubtitle("Step 2 of 3")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Next") { path.append(.depth) }
            }
        }
    }

    private var depth: some View {
        Form {
            DepthSection(targetGames: $draft.targetGames, inSetup: true)
        }
        .formStyle(.grouped)
        .navigationTitle("How Much to Learn")
        .navigationSubtitle("Step 3 of 3")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(finishTitle, systemImage: "checkmark", action: finish)
                    .buttonStyle(.glassProminent)
            }
        }
    }

    // MARK: Actions

    private var title: String {
        switch mode {
        case .new: "New Repertoire"
        case .importing: "Import PGN"
        case .setup(let entry): "Set Up \(entry.name)"
        }
    }

    private var finishTitle: String {
        switch mode {
        case .new: "Create"
        case .importing: "Add"
        case .setup: "Save"
        }
    }

    private var canContinue: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && draft.isValid
    }

    private func finish() {
        do {
            let entry: RepertoireEntry
            switch mode {
            case .new:
                entry = try model.library.create(name: name, sidecar: draft.makeSidecar())
            case .importing(let data, _):
                entry = try model.library.importPGN(data: data, name: name, sidecar: draft.makeSidecar())
            case .setup(let setup):
                try model.library.saveSidecar(draft.makeSidecar(), for: setup)
                entry = setup
            }
            draft.remember()
            dismiss()
            onDone(entry)
        } catch {
            // The name is on the first step.
            self.error = (error as? CocoaError)?.code == .fileWriteFileExists
                ? "A repertoire with this name already exists." : error.localizedDescription
            path = []
        }
    }
}

/// White or Black as two cards, each with its king as the board draws it.
struct SidePicker: View {
    @Binding var side: Side

    var body: some View {
        HStack(spacing: 12) {
            SideCard(side: .white, title: "White", selected: side == .white) { side = .white }
            SideCard(side: .black, title: "Black", selected: side == .black) { side = .black }
        }
        .padding(.vertical, 4)
    }
}

/// A side as a card: its king and its name; outlined when selected.
struct SideCard: View {
    let side: Side
    let title: String
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                SideTile(side: side, size: 52)
                Text(title).font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(.fill.quaternary, in: .rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14).strokeBorder(.tint, lineWidth: selected ? 2 : 0)
            }
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A side's king on a square of its own color, as the board draws them: a white king on a
/// light square, a black king on a dark one, in light and dark mode alike.
struct SideTile: View {
    @Environment(\.theme) private var theme
    let side: Side
    var size: CGFloat = 44

    var body: some View {
        Image(PieceLayout.assetName(side: side, kind: .king))
            .resizable()
            .padding(size * 0.08)
            .frame(width: size, height: size)
            .background(side == .white ? theme.board.light : theme.board.dark, in: .rect(cornerRadius: size * 0.18))
            .accessibilityHidden(true)
    }
}
