import OpeningCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let pgn = UTType(filenameExtension: "pgn", conformingTo: .plainText) ?? .plainText
}

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [String] = []
    @State private var showNew = false
    @State private var showConnect = false
    @State private var setupEntry: RepertoireEntry?
    @State private var connectURL: URL?
    @State private var reconnectEntry: RepertoireEntry?
    @State private var deleteEntry: RepertoireEntry?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Repertoires")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("New Repertoire", systemImage: "plus") { showNew = true }
                            Button("Connect PGN…", systemImage: "link") { showConnect = true }
                        } label: {
                            Label("Add", systemImage: "plus")
                        }
                    }
                }
                .navigationDestination(for: String.self) { id in
                    if let entry = model.library.entry(id: id), let doc = model.document(for: entry) {
                        BuilderView(document: doc)
                    } else {
                        ContentUnavailableView("Repertoire unavailable", systemImage: "exclamationmark.triangle",
                                               description: Text(model.openError ?? "The file could not be opened."))
                    }
                }
        }
        .sheet(isPresented: $showNew) {
            NewRepertoireSheet { entry in path = [entry.id] }
        }
        .sheet(item: $setupEntry) { entry in
            SetupSheet(title: "Set up \(entry.name)") { sidecar in
                try model.library.saveSidecar(sidecar, for: entry)
            }
        }
        .sheet(item: Binding(get: { connectURL.map(IdentifiedURL.init) }, set: { connectURL = $0?.url })) { item in
            SetupSheet(title: "Connect \(item.url.deletingPathExtension().lastPathComponent)") { sidecar in
                let entry = try model.library.connect(item.url, sidecar: sidecar)
                path = [entry.id]
            }
        }
        .fileImporter(isPresented: $showConnect, allowedContentTypes: [.pgn, .plainText]) { result in
            switch result {
            case .success(let url): connectURL = url
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .fileImporter(isPresented: Binding(get: { reconnectEntry != nil }, set: { if !$0 { reconnectEntry = nil } }),
                      allowedContentTypes: [.pgn, .plainText]) { result in
            if case .success(let url) = result, let entry = reconnectEntry {
                do { try model.library.reconnect(entry, to: url) } catch { errorMessage = error.localizedDescription }
            }
            reconnectEntry = nil
        }
        .confirmationDialog("Delete \(deleteEntry?.name ?? "")?", isPresented: Binding(
            get: { deleteEntry != nil }, set: { if !$0 { deleteEntry = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let entry = deleteEntry {
                    model.close(entry.id)
                    do { try model.library.delete(entry) } catch { errorMessage = error.localizedDescription }
                }
            }
        } message: {
            if deleteEntry?.isConnected == true {
                Text("Removes the link and training progress. The PGN file itself is kept.")
            } else {
                Text("Deletes the PGN and its training progress from iCloud Drive on all devices.")
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        let library = model.library
        if !library.isLoaded {
            ProgressView()
        } else if library.entries.isEmpty {
            ContentUnavailableView {
                Label("No repertoires yet", systemImage: "book.closed")
            } description: {
                Text("Create a repertoire to start a PGN in iCloud Drive, or connect a PGN you already have.")
            } actions: {
                Button("New Repertoire") { showNew = true }
                    .buttonStyle(.glassProminent)
                Button("Connect PGN…") { showConnect = true }
                    .buttonStyle(.glass)
            }
        } else {
            List {
                if !model.auth.isSignedIn {
                    SignInBanner()
                }
                if !library.usesICloud {
                    Label("iCloud Drive is off. Repertoires are stored on this device only.", systemImage: "icloud.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(library.entries) { entry in
                    row(entry)
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) { deleteEntry = entry }
                        }
                }
            }
            .refreshable { library.refresh() }
        }
    }

    @ViewBuilder
    private func row(_ entry: RepertoireEntry) -> some View {
        if entry.needsReconnect {
            Button { reconnectEntry = entry } label: {
                LibraryRow(entry: entry, status: "Not available on this device. Tap to reconnect the file.")
            }
            .tint(.primary)
        } else if entry.needsSetup {
            Button { setupEntry = entry } label: {
                LibraryRow(entry: entry, status: entry.isDownloading ? "Downloading from iCloud…" : "New PGN. Tap to set it up.")
            }
            .tint(.primary)
        } else {
            NavigationLink(value: entry.id) {
                LibraryRow(entry: entry, document: model.documents[entry.id])
            }
        }
    }
}

private struct IdentifiedURL: Identifiable {
    let url: URL
    var id: URL { url }
}

struct LibraryRow: View {
    let entry: RepertoireEntry
    var document: RepertoireDocument?
    var status: String?

    var body: some View {
        HStack(spacing: 12) {
            SideIcon(side: entry.sidecar?.color ?? .white)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(entry.name).font(.headline)
                    if entry.isConnected {
                        Image(systemName: "link").font(.caption).foregroundStyle(.secondary)
                            .accessibilityLabel("Connected file")
                    }
                }
                if let status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                } else {
                    progress
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var progress: some View {
        let summary = summaryValues
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Built").font(.caption2).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                CompletionBar(value: summary.completion, tint: .green)
                Text(Format.percent(summary.completion)).font(.caption2.monospacedDigit()).frame(width: 36, alignment: .trailing)
            }
            HStack {
                Text("Learned").font(.caption2).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                CompletionBar(value: summary.learned, tint: .blue)
                Text(Format.percent(summary.learned)).font(.caption2.monospacedDigit()).frame(width: 36, alignment: .trailing)
            }
            HStack(spacing: 10) {
                if summary.gaps > 0 { Label(summary.gaps == 1 ? "1 gap" : "\(summary.gaps) gaps", systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
                if summary.due > 0 { Label("\(summary.due) due", systemImage: "clock").foregroundStyle(.blue) }
                Text(entry.sidecar?.database.summary ?? "").foregroundStyle(.secondary).lineLimit(1)
            }
            .font(.caption2)
        }
    }

    private var summaryValues: (completion: Double, learned: Double, gaps: Int, due: Int) {
        if let document {
            _ = document.revision
            let root = document.coverage.root
            let progress = document.learningProgress()
            return (root?.completion ?? 0, progress.matureFraction, root?.gapCount ?? 0, progress.due)
        }
        guard let s = entry.sidecar?.summary else { return (0, 0, 0, 0) }
        let learned = s.cardCount > 0 ? Double(s.matureCount) / Double(s.cardCount) : 0
        let due = entry.sidecar?.cards.values.filter { $0.isDue(at: .now) }.count ?? s.dueCount
        return (s.completion, learned, s.gapCount, due)
    }
}

struct SignInBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuth

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Sign in with Lichess to see coverage", systemImage: "chart.bar.xaxis")
                .font(.subheadline.weight(.semibold))
            Text("Opponent statistics come from the Lichess opening explorer, which needs a free Lichess account. Training works without it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Sign in with Lichess") {
                Task {
                    if await model.auth.signIn(using: webAuth) { model.queue.resume() }
                }
            }
            .buttonStyle(.glassProminent)
            if let error = model.auth.lastError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 6)
    }
}

struct NewRepertoireSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var draft = RepertoireSettingsDraft()
    @State private var error: String?
    let onCreated: (RepertoireEntry) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Najdorf", text: $name)
                        .textInputAutocapitalization(.words)
                }
                RepertoireSettingsForm(draft: $draft)
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle("New Repertoire")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", systemImage: "checkmark") {
                        do {
                            let entry = try model.library.create(name: name, sidecar: draft.makeSidecar())
                            dismiss()
                            onCreated(entry)
                        } catch {
                            self.error = (error as? CocoaError)?.code == .fileWriteFileExists
                                ? "A repertoire with this name already exists." : error.localizedDescription
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || !draft.isValid)
                }
            }
        }
    }
}

/// Settings for a PGN that has no sidecar yet (connected or dropped into the folder).
struct SetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let onSave: (Sidecar) throws -> Void
    @State private var draft = RepertoireSettingsDraft()
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                RepertoireSettingsForm(draft: $draft)
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") {
                        do {
                            try onSave(draft.makeSidecar())
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                    .disabled(!draft.isValid)
                }
            }
        }
    }
}

/// Edit settings of an open repertoire.
struct RepertoireSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let document: RepertoireDocument
    @State private var draft: RepertoireSettingsDraft

    init(document: RepertoireDocument) {
        self.document = document
        _draft = State(initialValue: RepertoireSettingsDraft(document.sidecar))
    }

    var body: some View {
        NavigationStack {
            Form {
                RepertoireSettingsForm(draft: $draft)
                Section("File") {
                    LabeledContent("PGN", value: document.pgnURL.lastPathComponent)
                    if !document.loadWarnings.isEmpty {
                        DisclosureGroup("\(document.loadWarnings.count) moves could not be read") {
                            ForEach(document.loadWarnings, id: \.self) { Text($0).font(.footnote) }
                        }
                    }
                }
            }
            .navigationTitle("Repertoire Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") {
                        document.updateSettings(color: draft.color, database: draft.database,
                                                targetGames: draft.targetGames, minGames: draft.minGames)
                        dismiss()
                    }
                    .disabled(!draft.isValid)
                }
            }
        }
    }
}
