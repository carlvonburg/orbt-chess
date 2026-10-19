import OpeningCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Declared in Info.plist (UTImportedTypeDeclarations); the identifier matches macOS Chess.app.
    static let pgn = UTType(importedAs: "com.apple.chess.pgn", conformingTo: .plainText)
}

enum LibraryRoute: Hashable {
    case overview(String)
    case builder(String)
    case study(String)
    /// Study with today's new limit raised (Anki's custom study).
    case learnMore(String)
    case gaps(String)
    /// Every studied move, as a branch session over the whole repertoire.
    case practice(String)
}

/// Anki's deck list: today's totals, then one row per repertoire. A row opens the overview.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [LibraryRoute] = []
    @State private var showNew = false
    @State private var showImport = false
    @State private var setupEntry: RepertoireEntry?
    @State private var deleteEntry: RepertoireEntry?
    @State private var sheet: EntrySheet?
    @State private var errorMessage: String?
    @State private var showSettings = false
    @State private var studyAll = false
    @State private var today = LibraryTodayModel()
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
                .navigationDestination(for: LibraryRoute.self) { route in
                    switch route {
                    case .overview(let id):
                        destination(id) { doc in
                            RepertoireOverviewView(document: doc,
                                                   editLines: { path.append(.builder(doc.entryID)) },
                                                   study: { path.append(.study(doc.entryID)) },
                                                   practice: { path.append(.practice(doc.entryID)) })
                        }
                    case .builder(let id):
                        destination(id) { BuilderView(document: $0) }
                    case .study(let id):
                        destination(id) { DrillView(document: $0, mode: .study, pushed: true) }
                    case .learnMore(let id):
                        destination(id) { DrillView(document: $0, mode: .study, pushed: true, learnMore: TrainingDefaults.learnMoreCount) }
                    case .gaps(let id):
                        destination(id) { BuilderView(document: $0, showGaps: true) }
                    case .practice(let id):
                        destination(id) { DrillView(document: $0, mode: .branch(RepertoireTree.rootID), pushed: true) }
                    }
                }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(item: $sheet) { sheet in
            OpenDocument(entry: sheet.entry) { doc in
                switch sheet.kind {
                case .settings: RepertoireSettingsSheet(document: doc)
                case .options: StudyOptionsSheet(document: doc)
                }
            } placeholder: {
                ProgressView("Opening \(sheet.entry.name)…")
            }
        }
        .fullScreenCover(isPresented: $studyAll) {
            StudyAllView(entries: model.library.entries.filter {
                !$0.needsSetup && EntryStats(entry: $0, document: model.documents[$0.id]).counts.total > 0
            })
        }
        .sheet(isPresented: $showNew) {
            NewRepertoireSheet { entry in path = [.overview(entry.id), .builder(entry.id)] }
        }
        .sheet(item: $setupEntry) { entry in
            SetupSheet(title: "Set up \(entry.name)") { sidecar in
                try model.library.saveSidecar(sidecar, for: entry)
                path = [.overview(entry.id)]
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
    private func destination<V: View>(_ id: String, @ViewBuilder _ view: @escaping (RepertoireDocument) -> V) -> some View {
        if let entry = model.library.entry(id: model.currentID(id)) {
            OpenDocument(entry: entry, content: view) {
                ProgressView("Opening \(entry.name)…")
            }
        } else {
            ContentUnavailableView("Repertoire unavailable", systemImage: "exclamationmark.triangle",
                                   description: Text("The file is no longer in the folder."))
        }
    }

    @ViewBuilder
    private var content: some View {
        let library = model.library
        if !library.isLoaded {
            ProgressView()
        } else if library.entries.isEmpty {
            WelcomeView(usesICloud: library.usesICloud, newRepertoire: { showNew = true }, importPGN: { showImport = true })
        } else {
            let stats = Dictionary(uniqueKeysWithValues: library.entries.map {
                ($0.id, EntryStats(entry: $0, document: model.documents[$0.id]))
            })
            List {
                if !model.auth.isSignedIn {
                    SignInBanner()
                }
                Section {
                    TodayCard(entries: library.entries.filter { !$0.needsSetup }.map { ($0, stats[$0.id]!) },
                              today: today.today, streak: today.streak,
                              studyAll: { studyAll = true }, open: { path.append($0) })
                }
                let shown = visibleEntries(stats)
                if shown.isEmpty {
                    ContentUnavailableView {
                        Label("No matching repertoires", systemImage: "line.3.horizontal.decrease.circle")
                    } actions: {
                        Button("Clear Filters") { clearFilters() }
                            .buttonStyle(.glass)
                    }
                }
                // Grouped by side, as Chessbook does; the sort applies within each group.
                ForEach(LibraryGroup.allCases) { group in
                    let entries = shown.filter { group.contains($0) }
                    if !entries.isEmpty {
                        Section(group.title) {
                            ForEach(entries) { entry in
                                row(entry, stats[entry.id]!)
                                    .swipeActions {
                                        Button("Delete", systemImage: "trash", role: .destructive) { deleteEntry = entry }
                                    }
                                    .contextMenu { if !entry.needsSetup { menu(entry) } }
                            }
                        }
                    }
                }
            }
            .refreshable { library.refresh() }
            .task(id: TodayKey(entries: library.entries.count, answered: stats.values.reduce(0) { $0 + $1.counts.total })) {
                await today.load(model)
            }
        }
    }

    private struct TodayKey: Hashable {
        let entries: Int
        let answered: Int
    }

    /// Anki's deck gear menu.
    @ViewBuilder
    private func menu(_ entry: RepertoireEntry) -> some View {
        Button("Rename", systemImage: "pencil") { sheet = EntrySheet(entry: entry, kind: .settings) }
        Button("Options", systemImage: "slider.horizontal.3") { sheet = EntrySheet(entry: entry, kind: .options) }
        ShareLink(item: entry.pgnURL) { Label("Export", systemImage: "square.and.arrow.up") }
        Button("Delete", systemImage: "trash", role: .destructive) { deleteEntry = entry }
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

    private func visibleEntries(_ stats: [String: EntryStats]) -> [RepertoireEntry] {
        let all = model.library.entries
        let filtered = all.filter { entry in
            if !filtersActive { return true }
            guard let s = stats[entry.id] else { return false }
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
    private func row(_ entry: RepertoireEntry, _ stats: EntryStats) -> some View {
        if entry.needsSetup {
            Button { setupEntry = entry } label: {
                LibraryRow(entry: entry, stats: stats, status: entry.isDownloading ? "Downloading from iCloud…" : "New PGN. Tap to set it up.")
            }
            .tint(.primary)
        } else {
            NavigationLink(value: LibraryRoute.overview(entry.id)) {
                LibraryRow(entry: entry, stats: stats)
            }
        }
    }
}

private struct EntrySheet: Identifiable {
    enum Kind { case settings, options }
    let entry: RepertoireEntry
    let kind: Kind
    var id: String { "\(entry.id)-\(kind)" }
}

/// Today across all repertoires: Anki's due totals and "Studied N cards in M minutes today".
/// With nothing due it says why (done for now, caught up, nothing studied yet) and offers
/// what can still be done: Anki's custom study (more new moves, practice) or filling gaps.
private struct TodayCard: View {
    typealias Item = (entry: RepertoireEntry, stats: EntryStats)

    let entries: [Item]
    let today: GraphsContext.Today?
    let streak: Streak
    let studyAll: () -> Void
    let open: (LibraryRoute) -> Void

    private enum Phase {
        case due
        /// No moves saved yet in any repertoire.
        case empty
        /// Learning moves come back later today.
        case doneForNow(count: Int, at: Date)
        /// Nothing due and nothing studied today.
        case nothingDue
        case caughtUp
    }

    private var counts: CardQueues.Counts {
        entries.reduce(into: CardQueues.Counts()) {
            $0.new += $1.stats.counts.new
            $0.learning += $1.stats.counts.learning
            $0.review += $1.stats.counts.review
        }
    }

    private var studiedToday: Bool { (today?.answerCount ?? 0) > 0 }
    private var withMoves: [Item] { entries.filter { $0.stats.progress.cards > 0 } }
    private var unlearned: [Item] {
        entries.filter { $0.stats.progress.notStudied > 0 }.sorted { $0.stats.progress.notStudied > $1.stats.progress.notStudied }
    }
    private var withGaps: [Item] { entries.filter { $0.stats.gaps > 0 }.sorted { $0.stats.gaps > $1.stats.gaps } }
    private var gapCount: Int { entries.reduce(0) { $0 + $1.stats.gaps } }

    private var phase: Phase {
        if counts.total > 0 { return .due }
        if withMoves.isEmpty { return .empty }
        let learning = entries.flatMap(\.stats.laterLearning).filter { Calendar.current.isDateInToday($0) }
        if let first = learning.min() { return .doneForNow(count: learning.count, at: first) }
        if !studiedToday && !unlearned.isEmpty { return .nothingDue }
        return .caughtUp
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch phase {
            case .due:
                header { Text("Today") } trailing: { dueCounts }
                Text(studiedText).font(.footnote).foregroundStyle(.secondary)
                if streak.current > 0 { streakLabel }
                Button(action: studyAll) {
                    Text("Study All").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
            case .empty:
                Text("Nothing to study yet").font(.headline)
                Text("Enter the moves from a book or video, then study them here.")
                    .font(.footnote).foregroundStyle(.secondary)
                action("Add Moves", "plus", entries, prominent: true, detail: { _ in nil }) { .builder($0) }
            case .doneForNow(let count, let at):
                doneHeader("Done for Now", "checkmark.circle.fill")
                if studiedToday { studiedLine }
                Label("\(count) learning \(count == 1 ? "move" : "moves") due at \(at.formatted(date: .omitted, time: .shortened))",
                      systemImage: "clock")
                    .font(.footnote).foregroundStyle(.secondary)
                moreActions
            case .nothingDue:
                header { Text("Nothing Due Today") } trailing: { streakBadge }
                if streak.current > 0 {
                    Text("Learn a few new moves to keep your \(streak.current)-day streak.")
                        .font(.footnote).foregroundStyle(.orange)
                }
                nextLine
                action("Learn \(TrainingDefaults.learnMoreCount) New Moves", "sparkles", unlearned, prominent: true,
                       detail: { "\($0.progress.notStudied) not studied" }) { .learnMore($0) }
                if !withGaps.isEmpty { gapsAction }
            case .caughtUp:
                doneHeader("All Caught Up", "checkmark.seal.fill")
                if studiedToday { studiedLine }
                if unlearned.isEmpty && withGaps.isEmpty {
                    Text("Every move you've saved is learned.").font(.footnote).foregroundStyle(.secondary)
                }
                nextLine
                moreActions
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Parts

    private func header(@ViewBuilder _ title: () -> some View, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline) {
            title().font(.headline)
            Spacer()
            trailing()
        }
    }

    private func doneHeader(_ title: String, _ icon: String) -> some View {
        header { Label(title, systemImage: icon).foregroundStyle(.green) } trailing: { streakBadge }
    }

    private var dueCounts: some View {
        HStack(spacing: 10) {
            count(counts.new, StudyColors.new)
            count(counts.learning, StudyColors.learning)
            count(counts.review, StudyColors.review)
        }
        .font(.headline.monospacedDigit())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(counts.new) new, \(counts.learning) learning, \(counts.review) to review")
    }

    @ViewBuilder
    private var streakBadge: some View {
        if streak.current > 0 {
            Label("\(streak.current) \(streak.current == 1 ? "day" : "days")", systemImage: "flame.fill")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(streak.studiedToday ? .orange : .secondary)
                .accessibilityLabel(streakText)
        }
    }

    private var streakLabel: some View {
        Label(streakText, systemImage: "flame.fill")
            .font(.footnote)
            .foregroundStyle(streak.studiedToday ? .orange : .secondary)
    }

    private var studiedLine: some View {
        Text(studiedText).font(.footnote)
    }

    /// Tomorrow's reviews, or when the next one is due.
    @ViewBuilder
    private var nextLine: some View {
        let tomorrow = entries.reduce(0) { $0 + $1.stats.dueTomorrow }
        if tomorrow > 0 {
            Label("\(tomorrow) \(tomorrow == 1 ? "review" : "reviews") tomorrow", systemImage: "calendar")
                .font(.footnote).foregroundStyle(.secondary)
        } else if let next = entries.compactMap(\.stats.nextDue).min() {
            Label("Next review \(next.formatted(.relative(presentation: .named)))", systemImage: "calendar")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// What can still be done today: new moves and gaps, or else practice and adding lines.
    @ViewBuilder
    private var moreActions: some View {
        HStack(spacing: 8) {
            if unlearned.isEmpty && withGaps.isEmpty {
                action("Practice", "arrow.trianglehead.2.clockwise", withMoves.filter { $0.stats.progress.studied > 0 },
                       detail: { "\($0.progress.studied) moves" }) { .practice($0) }
                action("Add Lines", "plus", withMoves.sorted { $0.stats.completion < $1.stats.completion },
                       detail: { "\(Format.percent($0.completion)) built" }) { .builder($0) }
            } else {
                if !unlearned.isEmpty {
                    action("Learn \(TrainingDefaults.learnMoreCount) New", "sparkles", unlearned,
                           detail: { "\($0.progress.notStudied) not studied" }) { .learnMore($0) }
                }
                if !withGaps.isEmpty { gapsAction }
            }
        }
    }

    private var gapsAction: some View {
        action(gapCount == 1 ? "Fill 1 Gap" : "Fill \(gapCount) Gaps", "puzzlepiece", withGaps, tint: .orange,
               detail: { $0.gaps == 1 ? "1 gap" : "\($0.gaps) gaps" }) { .gaps($0) }
    }

    /// A button for one repertoire, or a menu to pick one of several.
    @ViewBuilder
    private func action(_ title: String, _ icon: String, _ items: [Item], prominent: Bool = false, tint: Color? = nil,
                        detail: @escaping (EntryStats) -> String?, route: @escaping (String) -> LibraryRoute) -> some View {
        let label = Label(title, systemImage: icon)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(tint ?? (prominent ? .white : .accentColor))
            .frame(maxWidth: .infinity)
        Group {
            if items.count == 1, let item = items.first {
                Button { open(route(item.entry.id)) } label: { label }
            } else {
                Menu {
                    ForEach(items, id: \.entry.id) { item in
                        Button { open(route(item.entry.id)) } label: {
                            Text(item.entry.name)
                            if let text = detail(item.stats) { Text(text) }
                        }
                    }
                } label: { label }
            }
        }
        .modifier(GlassButton(prominent: prominent))
    }

    private struct GlassButton: ViewModifier {
        let prominent: Bool
        func body(content: Content) -> some View {
            if prominent { content.buttonStyle(.glassProminent) } else { content.buttonStyle(.glass) }
        }
    }

    private var studiedText: String {
        guard let today, today.answerCount > 0 else { return "No moves studied today." }
        let minutes = Int((Double(today.answerMillis) / 60_000).rounded())
        let correct = Format.percent(Double(today.correctCount) / Double(today.answerCount))
        return "Studied \(today.answerCount) \(today.answerCount == 1 ? "move" : "moves") in \(minutes) \(minutes == 1 ? "minute" : "minutes") · \(correct) correct"
    }

    private var streakText: String {
        let days = "\(streak.current)-day streak"
        let longest = streak.longest > streak.current ? " · longest \(streak.longest)" : ""
        return streak.studiedToday ? days + longest : "Study today to keep your \(days)"
    }

    private func count(_ value: Int, _ color: Color) -> some View {
        Text(value.formatted()).foregroundStyle(value > 0 ? color : Color.secondary.opacity(0.6))
    }
}

/// Today's answers and the study streak across all repertoires, read from their review logs.
@Observable
final class LibraryTodayModel {
    private(set) var today: GraphsContext.Today?
    private(set) var streak = Streak()

    func load(_ app: AppModel) async {
        var revlog: [RevlogEntry] = []
        for entry in app.library.entries where !entry.needsSetup {
            revlog += await StudyLog.revlog(for: entry, in: app)
        }
        let graphs = GraphsContext(cards: [], newCount: 0, revlog: revlog, timing: SchedTiming())
        today = graphs.today()
        streak = graphs.streak()
    }
}

struct LibraryRow: View {
    let entry: RepertoireEntry
    let stats: EntryStats
    var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.name).font(.headline).lineLimit(1)
                    Spacer(minLength: 0)
                    if status == nil {
                        dueStatus.layoutPriority(1)
                    }
                }
                if let status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                } else if stats.progress.cards == 0 && stats.savedMoves == 0 {
                    Text("Empty · add moves to start").font(.caption).foregroundStyle(.secondary)
                } else {
                    progress
                }
        }
        .padding(.vertical, 4)
    }

    /// Today's counts; with nothing due after studying, when this repertoire is studied next.
    /// Never "done": building progress and gaps are shown below.
    @ViewBuilder
    private var dueStatus: some View {
        if stats.counts.total == 0 && stats.progress.studied > 0 {
            if let next = stats.nextDue {
                let text = Self.nextStudyText(next)
                Label(text, systemImage: Calendar.current.isDateInToday(next) ? "clock" : "calendar")
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    .accessibilityLabel("Next study \(text)")
            }
        } else {
            DueCounts(counts: stats.counts, progress: stats.progress)
        }
    }

    /// A time today, "Tomorrow", or "In N days".
    static func nextStudyText(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        return days <= 1 ? "Tomorrow" : "In \(days) days"
    }

    @ViewBuilder
    private var progress: some View {
        VStack(alignment: .leading, spacing: 4) {
            // A grid, so the label column is as wide as its longest label at any text size.
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                bar("Built") { CompletionBar(value: stats.completion, tint: .green) }
                if stats.progress.studied > 0 {
                    bar("Studied") { StudiedBar(progress: stats.progress) }
                }
            }
            let notStudied = stats.progress.studied == 0 && stats.progress.cards > 0
            if notStudied || stats.gaps > 0 {
                HStack(spacing: 0) {
                    if notStudied { Text("Not studied yet").foregroundStyle(.secondary) }
                    if notStudied && stats.gaps > 0 { Text(" · ").foregroundStyle(.secondary) }
                    if stats.gaps > 0 { Text(stats.gaps == 1 ? "1 gap" : "\(stats.gaps) gaps").foregroundStyle(.orange) }
                }
                .font(.caption)
            }
        }
    }

    private func bar(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        GridRow(alignment: .center) {
            Text(title).font(.caption2).foregroundStyle(.secondary).fixedSize()
            content()
        }
    }
}

/// Sections of the repertoire list.
private enum LibraryGroup: String, CaseIterable, Identifiable {
    case white, black, setup
    var id: Self { self }
    var title: String {
        switch self {
        case .white: "White"
        case .black: "Black"
        case .setup: "Not Set Up"
        }
    }

    func contains(_ entry: RepertoireEntry) -> Bool {
        switch self {
        case .white: entry.sidecar?.color == .white
        case .black: entry.sidecar?.color == .black
        case .setup: entry.sidecar == nil
        }
    }
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

/// Progress of one repertoire: live from the open document, else from the sidecar.
struct EntryStats {
    var completion = 0.0
    var gaps = 0
    var savedMoves = 0
    var progress = Trainer.Progress()
    var counts = CardQueues.Counts()
    /// Learning moves waiting for a later step today, soonest first.
    var laterLearning: [Date] = []
    var dueTomorrow = 0
    var nextDue: Date?
    /// Learning and review cards waiting today.
    var due: Int { counts.learning + counts.review }

    init(document: RepertoireDocument) {
        _ = document.revision
        let root = document.coverage.root
        completion = root?.completion ?? 0
        gaps = root?.gapCount ?? 0
        savedMoves = document.savedMoveCount
        progress = document.learningProgress()
        counts = document.studyCounts()
        setDue(document.sidecar)
    }

    init(entry: RepertoireEntry, document: RepertoireDocument?) {
        if let document {
            self.init(document: document)
        } else {
            self.init(sidecar: entry.sidecar)
        }
    }

    private init(sidecar: Sidecar?) {
        guard let sidecar else { return }
        counts = sidecar.estimatedStudyCounts(config: TrainingDefaults.config, timing: SchedTiming())
        progress = sidecar.estimatedProgress
        setDue(sidecar)
        guard let s = sidecar.summary else { return }
        completion = s.completion
        gaps = s.gapCount
        // Older summaries have no move count: anything with your moves has saved moves.
        savedMoves = s.savedMoveCount ?? s.cardCount
    }

    private mutating func setDue(_ sidecar: Sidecar) {
        let timing = SchedTiming()
        laterLearning = sidecar.laterLearningDues(timing: timing)
        dueTomorrow = sidecar.dueTomorrow(timing: timing)
        nextDue = sidecar.nextDue(timing: timing)
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

/// Name, side and coverage settings of an open repertoire.
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

/// Anki's deck options: this repertoire's daily limits (or the defaults) and practice mode.
struct StudyOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let document: RepertoireDocument
    @State private var practice: DailyPracticeDraft

    init(document: RepertoireDocument) {
        self.document = document
        _practice = State(initialValue: DailyPracticeDraft(sidecar: document.sidecar))
    }

    var body: some View {
        NavigationStack {
            Form {
                DailyPracticeSection(draft: $practice)
            }
            .navigationTitle("\(document.name) Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") {
                        document.updateStudySettings(limits: practice.limits, practiceMode: practice.practiceMode)
                        dismiss()
                    }
                }
            }
        }
    }
}
