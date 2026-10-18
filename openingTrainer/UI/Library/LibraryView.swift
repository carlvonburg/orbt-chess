import OpeningCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Declared in Info.plist (UTImportedTypeDeclarations); the identifier matches macOS Chess.app.
    static let pgn = UTType(importedAs: "com.apple.chess.pgn", conformingTo: .plainText)
}

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [String] = []
    @State private var showNew = false
    @State private var showImport = false
    @State private var setupEntry: RepertoireEntry?
    @State private var deleteEntry: RepertoireEntry?
    @State private var errorMessage: String?
    @State private var showSettings = false
    @State private var drill: LibraryDrill?
    @AppStorage("library.sort") private var sort = LibrarySort.name
    @AppStorage("library.side") private var sideFilter = LibrarySideFilter.all
    @AppStorage("library.onlyGaps") private var onlyGaps = false
    @AppStorage("library.onlyDue") private var onlyDue = false

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Repertoires")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Settings", systemImage: "gearshape") { showSettings = true }
                    }
                    if !model.library.entries.isEmpty {
                        ToolbarItem(placement: .topBarTrailing) { filterMenu }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("New Repertoire", systemImage: "plus") { showNew = true }
                            Button("Import PGN…", systemImage: "square.and.arrow.down") { showImport = true }
                        } label: {
                            Label("Add", systemImage: "plus")
                        }
                    }
                }
                .navigationDestination(for: String.self) { id in
                    if let entry = model.library.entry(id: model.currentID(id)) {
                        OpenDocument(entry: entry) { doc in
                            BuilderView(document: doc)
                        } placeholder: {
                            ProgressView("Opening \(entry.name)…")
                        }
                    } else {
                        ContentUnavailableView("Repertoire unavailable", systemImage: "exclamationmark.triangle",
                                               description: Text("The file is no longer in the folder."))
                    }
                }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .fullScreenCover(item: $drill) { drill in
            OpenDocument(entry: drill.entry) { doc in
                DrillView(document: doc, mode: drill.mode)
            } placeholder: {
                ProgressView("Opening \(drill.entry.name)…")
            }
        }
        .sheet(isPresented: $showNew) {
            NewRepertoireSheet { entry in path = [entry.id] }
        }
        .sheet(item: $setupEntry) { entry in
            SetupSheet(title: "Set up \(entry.name)") { sidecar in
                try model.library.saveSidecar(sidecar, for: entry)
                path = [entry.id]
            }
        }
        .fileImporter(isPresented: $showImport, allowedContentTypes: [.pgn, .plainText]) { result in
            do {
                setupEntry = try model.library.importPGN(from: result.get())
            } catch {
                errorMessage = error.localizedDescription
            }
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
            Text(model.library.usesICloud
                 ? "Deletes the PGN and its training progress from iCloud Drive on all devices."
                 : "Deletes the PGN and its training progress from this device.")
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
                Text("Create a new repertoire, or import a PGN you already have. It's copied into the app's folder and every edit is saved to it.")
            } actions: {
                Button("New Repertoire") { showNew = true }
                    .buttonStyle(.glassProminent)
                Button("Import PGN…") { showImport = true }
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
                let shown = visibleEntries
                if shown.isEmpty {
                    ContentUnavailableView {
                        Label("No matching repertoires", systemImage: "line.3.horizontal.decrease.circle")
                    } actions: {
                        Button("Clear Filters") { clearFilters() }
                            .buttonStyle(.glass)
                    }
                }
                ForEach(shown) { entry in
                    Section {
                        row(entry)
                            .swipeActions {
                                Button("Delete", systemImage: "trash", role: .destructive) { deleteEntry = entry }
                            }
                        if !entry.needsSetup {
                            TrainActions(entry: entry, document: model.documents[entry.id]) { mode in
                                drill = LibraryDrill(entry: entry, mode: mode)
                            }
                        }
                    }
                }
            }
            .refreshable { library.refresh() }
        }
    }

    // MARK: Filter and sort

    private var filtersActive: Bool { sideFilter != .all || onlyGaps || onlyDue }

    private func clearFilters() {
        sideFilter = .all
        onlyGaps = false
        onlyDue = false
    }

    private var filterMenu: some View {
        Menu {
            Picker("Sort By", selection: $sort) {
                ForEach(LibrarySort.allCases) { Label($0.title, systemImage: $0.icon).tag($0) }
            }
            Section("Show") {
                Picker("Side", selection: $sideFilter) {
                    ForEach(LibrarySideFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Has Gaps", systemImage: "exclamationmark.circle", isOn: $onlyGaps)
                Toggle("Due for Review", systemImage: "clock", isOn: $onlyDue)
            }
            if filtersActive {
                Button("Clear Filters", systemImage: "xmark.circle") { clearFilters() }
            }
        } label: {
            Label("Filter and Sort", systemImage: filtersActive
                  ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
    }

    private var visibleEntries: [RepertoireEntry] {
        let all = model.library.entries
        guard filtersActive || sort != .name else { return all }
        let stats = Dictionary(uniqueKeysWithValues: all.map { ($0.id, EntryStats(entry: $0, document: model.documents[$0.id])) })
        let filtered = all.filter { entry in
            guard let s = stats[entry.id] else { return false }
            if !filtersActive { return true }
            // A PGN that is not set up yet has no side or progress to filter by.
            guard let side = entry.sidecar?.color else { return false }
            if let wanted = sideFilter.side, side != wanted { return false }
            if onlyGaps && s.gaps == 0 { return false }
            if onlyDue && s.due == 0 { return false }
            return true
        }
        // library.entries is already sorted by name, and Swift's sort is stable.
        switch sort {
        case .name: return filtered
        case .gaps: return filtered.sorted { stats[$0.id]!.gaps > stats[$1.id]!.gaps }
        case .due: return filtered.sorted { stats[$0.id]!.due > stats[$1.id]!.due }
        case .built: return filtered.sorted { stats[$0.id]!.completion < stats[$1.id]!.completion }
        }
    }

    @ViewBuilder
    private func row(_ entry: RepertoireEntry) -> some View {
        if entry.needsSetup {
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

private struct LibraryDrill: Identifiable {
    let entry: RepertoireEntry
    let mode: DrillMode
    var id: String { "\(entry.id)-\(mode)" }
}

/// Review due cards or learn new ones. Opens the PGN only when started.
private struct TrainActions: View {
    let entry: RepertoireEntry
    var document: RepertoireDocument?
    let start: (DrillMode) -> Void

    var body: some View {
        let counts = self.counts
        GlassEffectContainer {
            HStack {
                Button { start(.due) } label: {
                    Label("Review \(counts.due)", systemImage: "clock.arrow.circlepath").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .disabled(counts.due == 0)
                Button { start(.learnNew) } label: {
                    Label("Learn \(min(counts.unseen, DrillModel.newPerSession))", systemImage: "sparkles").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .disabled(counts.unseen == 0)
            }
        }
        .font(.subheadline)
    }

    private var counts: EntryStats { EntryStats(entry: entry, document: document) }
}

struct LibraryRow: View {
    let entry: RepertoireEntry
    var document: RepertoireDocument?
    var status: String?

    var body: some View {
        HStack(spacing: 12) {
            SideIcon(side: entry.sidecar?.color ?? .white)
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.name).font(.headline)
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
                Text(entry.sidecar?.database.summary ?? "").foregroundStyle(.secondary).lineLimit(1)
            }
            .font(.caption2)
        }
    }

    private var summaryValues: EntryStats { EntryStats(entry: entry, document: document) }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case name, gaps, due, built
    var id: Self { self }
    var title: String {
        switch self {
        case .name: "Name"
        case .gaps: "Most Gaps"
        case .due: "Most Due"
        case .built: "Least Built"
        }
    }
    var icon: String {
        switch self {
        case .name: "textformat"
        case .gaps: "exclamationmark.circle"
        case .due: "clock"
        case .built: "chart.bar"
        }
    }
}

enum LibrarySideFilter: String, CaseIterable, Identifiable {
    case all, white, black
    var id: Self { self }
    var title: String { self == .all ? "All" : rawValue.capitalized }
    var side: Side? { self == .all ? nil : Side(rawValue: rawValue) }
}

/// Progress of one repertoire: live from the open document, else from the sidecar summary.
struct EntryStats {
    var completion = 0.0
    var learned = 0.0
    var gaps = 0
    var due = 0
    var unseen = 0

    init(entry: RepertoireEntry, document: RepertoireDocument?) {
        if let document {
            _ = document.revision
            let root = document.coverage.root
            let progress = document.learningProgress()
            completion = root?.completion ?? 0
            learned = progress.matureFraction
            gaps = root?.gapCount ?? 0
            due = progress.due
            unseen = progress.cards - progress.seen
            return
        }
        guard let sidecar = entry.sidecar else { return }
        let seen = sidecar.cards
        due = seen.values.filter { $0.isDue(at: .now) }.count
        guard let s = sidecar.summary else { return }
        completion = s.completion
        learned = s.cardCount > 0 ? Double(s.matureCount) / Double(s.cardCount) : 0
        gaps = s.gapCount
        unseen = max(s.cardCount - seen.count, 0)
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
                        .onChange(of: name) { name = name.safeRepertoireName }
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

/// Settings for a PGN that has no sidecar yet (imported or dropped into the folder).
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
    @Environment(AppModel.self) private var model
    let document: RepertoireDocument
    @State private var draft: RepertoireSettingsDraft
    @State private var name: String
    @State private var error: String?

    init(document: RepertoireDocument) {
        self.document = document
        _draft = State(initialValue: RepertoireSettingsDraft(document.sidecar))
        _name = State(initialValue: document.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                        .onChange(of: name) { name = name.safeRepertoireName }
                }
                RepertoireSettingsForm(draft: $draft)
                if let error { Text(error).foregroundStyle(.red) }
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
                        let newName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if newName != document.name {
                            do {
                                try model.rename(document, to: newName)
                            } catch {
                                self.error = (error as? CocoaError)?.code == .fileWriteFileExists
                                    ? "A repertoire with this name already exists." : error.localizedDescription
                                return
                            }
                        }
                        document.updateSettings(color: draft.color, database: draft.database,
                                                targetGames: draft.targetGames, minGames: draft.minGames)
                        dismiss()
                    }
                    .disabled(!draft.isValid || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
