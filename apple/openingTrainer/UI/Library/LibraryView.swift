import OpeningCoreRust
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
    /// Today's moves of every repertoire that has some, one after another.
    case studyAll([String])
    /// Browse from a position: from Study, or a weakest move in the statistics.
    case browse(String, NodeID)
    /// Study one branch: Study Branch in Browse.
    case branch(String, NodeID)
}

extension LibraryRoute {
    /// The repertoire the screen shows; nil for Study All.
    var entryID: String? {
        switch self {
        case .overview(let id), .builder(let id), .study(let id), .learnMore(let id), .gaps(let id),
             .practice(let id), .browse(let id, _), .branch(let id, _): id
        case .studyAll: nil
        }
    }
}

extension EnvironmentValues {
    /// Opens Browse or Study from another screen (set by the library). Only the screen it is
    /// opened from stays under it, so switching back and forth doesn't pile up screens.
    @Entry var openScreen: ((LibraryRoute) -> Void)?
}

/// Anki's deck list: today's totals, then one row per repertoire. A row opens the overview.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The split view's sidebar selection; the phone has none (its path starts at the overview).
    @State private var selection: SidebarItem? = .today
    /// The screens pushed: on a phone onto the library, in the split view onto the selection
    /// (the middle column).
    @State private var path: [LibraryRoute] = []
    /// The models of the Browse and Study screens on the path.
    @State private var screens = LibraryScreens()
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var showNew = false
    @State private var showImport = false
    @State private var setupEntry: RepertoireEntry?
    @State private var deleteEntry: RepertoireEntry?
    @State private var sheet: EntrySheet?
    @State private var errorMessage: String?
    /// iPhone and iPad: Settings is a sheet from the library's bar. The Mac has it in the
    /// app menu (the `Settings` scene).
    @State private var showSettings = false
    @State private var today = LibraryTodayModel()

    var body: some View {
        Group {
            if usesSplit { split } else { stack }
        }
        // An iPad window resized across the size classes keeps what it shows.
        .onChange(of: usesSplit) { _, split in
            if split {
                if case .overview(let id) = path.first {
                    selection = .repertoire(id)
                    path.removeFirst()
                } else {
                    selection = .today
                }
            } else if case .repertoire(let id) = selection {
                path.insert(.overview(id), at: 0)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().presentationSizing(.form)
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
            .presentationSizing(.form)
        }
        .sheet(isPresented: $showNew) {
            NewRepertoireSheet { entry in show(entry.id, then: [.builder(entry.id)]) }
                .presentationSizing(.form)
        }
        .sheet(item: $setupEntry) { entry in
            SetupSheet(title: "Set up \(entry.name)") { sidecar in
                try model.library.saveSidecar(sidecar, for: entry)
                show(entry.id, then: [])
            }
            .presentationSizing(.form)
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
                    Task {
                        do { try await model.delete(entry) } catch { errorMessage = error.localizedDescription }
                    }
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

    /// The library, then each screen pushed on top: the whole app on a phone.
    private var stack: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Repertoires")
                .toolbar { libraryToolbar }
                .navigationDestination(for: LibraryRoute.self, destination: route)
        }
        .environment(\.openScreen, openScreen)
    }

    /// Shows `newPath` once the models of its Browse and Study screens are made, so the screen
    /// and the split view's board column show the same model from the start. Screens no
    /// longer on the path (popped) are forgotten first: opening one again starts afresh.
    private func go(to newPath: [LibraryRoute]) {
        screens.keep(path)
        Task {
            if await screens.prepare(newPath, app: model) {
                path = newPath
            } else {
                errorMessage = "The repertoire could not be opened."
            }
        }
    }

    /// A regular-width window (iPad, Mac) with repertoires to show.
    private var usesSplit: Bool {
        isRegularWidth(sizeClass) && !model.library.entries.isEmpty
    }

    /// iPad and Mac, like Mail: the repertoires in the sidebar, selected rather than pushed
    /// (macOS 26 lays a scroll view pushed onto a stack in a sidebar out under an inset as tall
    /// as the column, so it shows nothing). In the middle the selection: Today, or the
    /// repertoire's overview with Browse's and Study's panels pushed on it; on the right the
    /// board of the screen on top, else the statistics (of every repertoire for Today).
    private var split: some View {
        NavigationSplitView(columnVisibility: $columns) {
            content
                .navigationTitle("Repertoires")
                .toolbar { libraryToolbar }
                // Starting widths only (the board takes the rest); people can drag the dividers.
                .navigationSplitViewColumnWidth(ideal: 260)
        } content: {
            NavigationStack(path: $path) {
                middleRoot
                    .navigationDestination(for: LibraryRoute.self, destination: route)
            }
            .navigationSplitViewColumnWidth(ideal: 380)
        } detail: {
            NavigationStack {
                BoardColumnView(board: board, statisticsScope: statisticsScope)
            }
        }
        .environment(\.inSplitView, true)
        .environment(\.openScreen, openScreen)
    }

    /// The sidebar's selection as the list sets it: choosing another item starts its column
    /// afresh. (The list sets it again when it redraws, so only a change does.)
    private var sidebarSelection: Binding<SidebarItem?> {
        Binding(get: {
            if case .repertoire(let id) = selection { .repertoire(model.currentID(id)) } else { selection }
        }, set: { item in
            guard let item, item != selection else { return }
            select(item, then: [])
        })
    }

    /// The middle column's root: Today, or the selected repertoire's overview.
    @ViewBuilder
    private var middleRoot: some View {
        if case .repertoire(let id) = selection {
            route(.overview(id))
                .id(model.currentID(id))
        } else {
            todayColumn
        }
    }

    /// Today in the middle column: the card with Study All, then each repertoire's due moves.
    private var todayColumn: some View {
        let stats = entryStats
        return List {
            Section { todayRows(stats) }
        }
        .navigationTitle("Today")
    }

    /// Today's progress ring, then what is left to do: in the library's Today section on a
    /// phone, in the Today column in the split view.
    @ViewBuilder
    private func todayRows(_ stats: [String: EntryStats]) -> some View {
        TodayProgress(studied: Int(today.today?.cardCount ?? 0),
                      due: Int(stats.values.reduce(0) { $0 + $1.counts.total }))
        todayCard(stats)
    }

    /// What the sidebar selects: today across every repertoire, or one repertoire.
    private enum SidebarItem: Hashable {
        case today
        case repertoire(String)
    }

    /// Today across every repertoire, with Study All: atop the library on a phone, in the
    /// middle column when Today is selected in the split view.
    private func todayCard(_ stats: [String: EntryStats]) -> some View {
        TodayCard(entries: model.library.entries.filter { !$0.needsSetup }.map { ($0, stats[$0.id]!) },
                  today: today.today, streak: today.streak,
                  studyAll: { open(.studyAll(studyAllEntries)) }, open: open)
    }

    /// Opens a screen from Today: pushed on a phone; in the split view the repertoire is
    /// selected and the screen pushed on its overview (Study All on Today).
    private func open(_ route: LibraryRoute) {
        guard usesSplit else { return go(to: path + [route]) }
        if let id = route.entryID { return show(id, then: [route]) }
        select(.today, then: [route])
    }

    /// Selects `item` in the split view, then pushes `routes` on it. Another item's screens go
    /// at once, so they never show over the new selection.
    private func select(_ item: SidebarItem, then routes: [LibraryRoute]) {
        if item != selection {
            selection = item
            path = []
        }
        go(to: routes)
    }

    /// The board of the screen on top: Browse's or Study's, none over an overview.
    private var board: LibraryScreens.Board? {
        path.last.flatMap { screens.screen(for: $0)?.board }
    }

    /// Opens a screen from Browse or Study: the overview stays (on a phone the path's first
    /// screen, in the split view the middle column's root), then only the screen it is opened
    /// from.
    private func openScreen(_ route: LibraryRoute) {
        let overview = path.prefix { if case .overview = $0 { true } else { false } }
        go(to: Array(overview) + Array(path.dropFirst(overview.count).suffix(1)) + [route])
    }

    /// The statistics beside Today (every repertoire) or the selected repertoire.
    private var statisticsScope: StatisticsModel.Scope {
        if case .repertoire(let id) = selection { .repertoire(model.currentID(id)) } else { .all }
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: .leadingBar) {
            Button("Settings", systemImage: "gearshape") { showSettings = true }
        }
        #endif
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("New Repertoire", systemImage: "plus") { showNew = true }
                Button("Import PGN…", systemImage: "square.and.arrow.down") { showImport = true }
            } label: {
                Label("Add", systemImage: "plus")
            }
        }
    }

    /// A pushed screen. The navigation action is set on it: set on the stack, it does not
    /// reach the screens the stack pushes (in the split view's column).
    private func route(_ route: LibraryRoute) -> some View {
        screen(route).environment(\.openScreen, openScreen)
    }

    @ViewBuilder
    private func screen(_ route: LibraryRoute) -> some View {
        switch route {
        case .overview(let id):
            destination(id) { doc in
                RepertoireOverviewView(document: doc,
                                       editLines: { go(to: path + [.builder(doc.entryID)]) },
                                       study: { go(to: path + [.study(doc.entryID)]) },
                                       practice: { go(to: path + [.practice(doc.entryID)]) })
            }
            // The title switches to another repertoire without going back to the library.
            .toolbarTitleMenu { repertoireSwitcher(id) }
        default:
            // Made before the route was pushed (`go(to:)`).
            switch screens.screen(for: route) {
            case .builder(let model, let presentation):
                BuilderView(model: model, presentation: presentation)
            case .drill(let model):
                DrillView(model: model)
            case .studyAll(let all):
                StudyAllView(model: all)
            case nil:
                ContentUnavailableView("Repertoire unavailable", systemImage: "exclamationmark.triangle")
            }
        }
    }

    /// A repertoire's overview, then the given screens on top of it: in the split view the
    /// repertoire selected.
    private func show(_ id: String, then routes: [LibraryRoute]) {
        if usesSplit {
            select(.repertoire(id), then: routes)
        } else {
            go(to: [.overview(id)] + routes)
        }
    }

    /// The repertoires, by side, checked on the one shown; choosing one shows its overview.
    private func repertoireSwitcher(_ id: String) -> some View {
        Picker("Repertoire", selection: Binding(get: { model.currentID(id) }, set: { show($0, then: []) })) {
            ForEach(LibraryGroup.allCases) { group in
                let entries = model.library.entries.filter { group.contains($0) && !$0.needsSetup }
                if !entries.isEmpty {
                    Section(group.title) {
                        ForEach(entries) { Text($0.name).tag($0.id) }
                    }
                }
            }
        }
    }

    private var entryStats: [String: EntryStats] {
        Dictionary(uniqueKeysWithValues: model.library.entries.map {
            ($0.id, EntryStats(entry: $0, document: model.documents[$0.id]))
        })
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
            let stats = entryStats
            Group {
                if usesSplit {
                    List(selection: sidebarSelection) { rows(stats) }
                } else {
                    List { rows(stats) }
                }
            }
            .refreshable { await library.refresh() }
            .task(id: TodayKey(entries: library.entries.count, answered: stats.values.reduce(0) { $0 + $1.counts.total })) {
                await today.load(model)
            }
        }
    }

    @ViewBuilder
    private func rows(_ stats: [String: EntryStats]) -> some View {
        if !model.auth.isSignedIn {
            SignInBanner()
        }
        if usesSplit {
            // Today's card is in the middle column when this row is selected.
            Label("Today", systemImage: "calendar")
                .badge(Int(stats.values.reduce(0) { $0 + $1.counts.total }))
                .tag(SidebarItem.today)
        } else {
            Section("Today") { todayRows(stats) }
        }
        // Grouped by side, as Chessbook does; by name within each group.
        ForEach(LibraryGroup.allCases) { group in
            let entries = model.library.entries.filter { group.contains($0) }
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

    /// Repertoires with moves due today, in list order.
    private var studyAllEntries: [String] {
        model.library.entries.filter {
            !$0.needsSetup && EntryStats(entry: $0, document: model.documents[$0.id]).counts.total > 0
        }.map(\.id)
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

    @ViewBuilder
    private func row(_ entry: RepertoireEntry, _ stats: EntryStats) -> some View {
        if entry.needsSetup {
            Button { setupEntry = entry } label: {
                LibraryRow(entry: entry, stats: stats, status: entry.isDownloading ? "Downloading from iCloud…" : "New PGN. Tap to set it up.")
            }
            .tint(.primary)
        } else if usesSplit {
            LibraryRow(entry: entry, stats: stats).tag(SidebarItem.repertoire(entry.id))
        } else {
            NavigationLink(value: LibraryRoute.overview(entry.id)) {
                LibraryRow(entry: entry, stats: stats)
            }
        }
    }
}

/// The split view's right column: Browse's or Study's board, else the overview's statistics.
/// One bar whose buttons follow the board, so they never go stale or flicker.
private struct BoardColumnView: View {
    let board: LibraryScreens.Board?
    let statisticsScope: StatisticsModel.Scope
    /// Study's analysis board (Browse's is presented by its panel).
    @State private var analysis: AnalysisModel?
    @State private var columnWidth: CGFloat = 0

    /// The move history's width in the bottom bar: the column less the bar's margins, and
    /// Browse's back and forward.
    private func historyWidth(buttons: Bool) -> CGFloat {
        max(120, columnWidth - (buttons ? 180 : 60))
    }

    private var title: String {
        switch board {
        case .builder: "Browse"
        case .drill(let model): model.mode.title
        case nil: "Statistics"
        }
    }

    var body: some View {
        Group {
            switch board {
            case .builder(let model, _):
                BuilderBoardColumn(model: model)
            case .drill(let model):
                DrillBoardColumn(model: model)
            case nil:
                ScrollView {
                    InlineStatistics(scope: statisticsScope)
                        .id(statisticsScope)
                        .scenePadding()
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { columnWidth = $0 }
        // The left column names the repertoire; this column what it shows.
        .navigationTitle(title)
        .toolbar {
            if case .builder(let model, let presentation) = board {
                // Move navigation under the board (the top bar's leading side is the title's), as
                // on a phone; Analysis and the menu, which act on the board, end the top bar.
                ToolbarItemGroup(placement: .bottomActions) { BuilderNavigationButtons(model: model) }
                // A fixed width from the column: moving never resizes the bar; the moves
                // scroll inside it.
                ToolbarItem(placement: .bottomActions) {
                    MovePathStrip(model: model)
                        .frame(width: historyWidth(buttons: true))
                }
                ToolbarItem(placement: .trailingBar) {
                    Button("Analysis", systemImage: "cpu") { presentation.analyze(model) }
                }
                ToolbarSpacer(.fixed, placement: .trailingBar)
                ToolbarItem(placement: .trailingBar) { BuilderMoreMenu(model: model, presentation: presentation) }
            }
            if case .drill(let model) = board, !model.finished {
                // The moves played, in the bottom bar as Browse's are.
                ToolbarItem(placement: .bottomActions) {
                    LineHistory(tree: model.document.tree, nodes: model.playedNodes)
                        .frame(width: historyWidth(buttons: false))
                }
                // Looking the move up counts as Again, as Browse in the panel does.
                ToolbarItem(placement: .trailingBar) {
                    Button("Analysis", systemImage: "cpu") {
                        analysis = AnalysisModel(document: model.document, moves: model.analysisMoves(),
                                                 orientation: model.color, origin: .study)
                    }
                }
            }
        }
        .analysisBoard($analysis)
    }
}

private struct EntrySheet: Identifiable {
    enum Kind { case settings, options }
    let entry: RepertoireEntry
    let kind: Kind
    var id: String { "\(entry.id)-\(kind)" }
}

/// Today's progress in the split view's Today column: the moves studied today against those
/// still due, as a ring.
private struct TodayProgress: View {
    let studied: Int
    let due: Int

    var body: some View {
        HStack(spacing: 16) {
            Gauge(value: Double(studied), in: 0...Double(max(studied + due, 1))) {
                Text("Today")
            } currentValueLabel: {
                Text(studied.formatted())
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(due == 0 ? .green : .blue)
            VStack(alignment: .leading) {
                Text("\(studied.formatted()) of \((studied + due).formatted()) moves").font(.headline)
                Text(due == 0 ? "Done for today" : "\(due.formatted()) still due")
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Today across all repertoires: Anki's due totals and "Studied N cards in M minutes today".
/// With nothing due it says why (done for now, caught up, nothing studied yet) and offers
/// what can still be done: Anki's custom study (more new moves, practice) or filling gaps.
private struct TodayCard: View {
    typealias Item = (entry: RepertoireEntry, stats: EntryStats)

    let entries: [Item]
    let today: Today?
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

    private var counts: Counts {
        entries.reduce(into: Counts()) {
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

    /// List rows: what today looks like, then its actions (a menu when several repertoires
    /// could take one), the same buttons, the most likely one prominent.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch phase {
            case .due:
                // What was studied is the ring above (and Statistics): here what is left.
                HStack(alignment: .firstTextBaseline) {
                    if streak.current > 0 { streakLabel }
                    Spacer()
                    dueCounts
                }
            case .empty:
                Text("Nothing to study yet").font(.headline)
                Text("Enter the moves from a book or video, then study them here.")
                    .font(.footnote).foregroundStyle(.secondary)
            case .doneForNow(let count, let at):
                doneHeader("Done for Now", "checkmark.circle.fill")
                Label("\(count) learning \(count == 1 ? "move" : "moves") due at \(at.formatted(date: .omitted, time: .shortened))",
                      systemImage: "clock")
                    .font(.footnote).foregroundStyle(.secondary)
            case .nothingDue:
                header { Text("Nothing Due Today") } trailing: { streakBadge }
                if streak.current > 0 {
                    Text("Learn a few new moves to keep your \(streak.current)-day streak.")
                        .font(.footnote).foregroundStyle(.orange)
                }
                nextLine
            case .caughtUp:
                doneHeader("All Caught Up", "checkmark.seal.fill")
                if unlearned.isEmpty && withGaps.isEmpty {
                    Text("Every move you've saved is learned.").font(.footnote).foregroundStyle(.secondary)
                }
                nextLine
            }
        }
        switch phase {
        case .due:
            Button("Study All", action: studyAll).actionButton(prominent: true)
        case .empty:
            action("Add Moves", entries, main: true, detail: { _ in nil }) { .builder($0) }
        case .nothingDue:
            learnAction(main: true)
            if !withGaps.isEmpty { gapsAction }
        case .doneForNow, .caughtUp:
            moreActions
        }
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
        if unlearned.isEmpty && withGaps.isEmpty {
            action("Practice", withMoves.filter { $0.stats.progress.studied > 0 },
                   detail: { "\($0.progress.studied) moves" }) { .practice($0) }
            action("Add Lines", withMoves.sorted { $0.stats.completion < $1.stats.completion },
                   detail: { "\(Format.percent($0.completion)) built" }) { .builder($0) }
        } else {
            if !unlearned.isEmpty { learnAction(main: false) }
            if !withGaps.isEmpty { gapsAction }
        }
    }

    private func learnAction(main: Bool) -> some View {
        action("Learn \(TrainingDefaults.learnMoreCount) New Moves", unlearned, main: main,
               detail: { "\($0.progress.notStudied) not studied" }) { .learnMore($0) }
    }

    private var gapsAction: some View {
        action(gapCount == 1 ? "Fill 1 Gap" : "Fill \(gapCount) Gaps", withGaps,
               detail: { $0.gaps == 1 ? "1 gap" : "\($0.gaps) gaps" }) { .gaps($0) }
    }

    /// A button for one repertoire, or a menu to pick one of several.
    private func action(_ title: String, _ items: [Item], main: Bool = false,
                        detail: @escaping (EntryStats) -> String?, route: @escaping (String) -> LibraryRoute) -> some View {
        Group {
            if items.count == 1, let item = items.first {
                Button(title) { open(route(item.entry.id)) }
            } else {
                Menu(title) { menuItems(items, detail: detail, route: route) }
            }
        }
        .actionButton(prominent: main)
    }

    private func menuItems(_ items: [Item], detail: @escaping (EntryStats) -> String?,
                           route: @escaping (String) -> LibraryRoute) -> some View {
        ForEach(items, id: \.entry.id) { item in
            Button { open(route(item.entry.id)) } label: {
                Text(item.entry.name)
                if let text = detail(item.stats) { Text(text) }
            }
        }
    }

    private var streakText: String {
        let days = "\(streak.current)-day streak"
        let longest = streak.longest > streak.current ? " · longest \(streak.longest)" : ""
        return streak.studiedToday ? days + longest : "Study today to keep your \(days)"
    }

    private func count(_ value: Int64, _ color: Color) -> some View {
        Text(value.formatted()).foregroundStyle(value > 0 ? color : Color.secondary.opacity(0.6))
    }
}

/// Today's answers and the study streak across all repertoires, read from their review logs.
@Observable
final class LibraryTodayModel {
    private(set) var today: Today?
    private(set) var streak = Streak(current: 0, longest: 0, studiedToday: false)

    func load(_ app: AppModel) async {
        var revlog: [RevlogEntry] = []
        for entry in app.library.entries where !entry.needsSetup {
            revlog += await StudyLog.revlog(for: entry, in: app)
        }
        let graphs = Graphs(cards: [], newCount: 0, suspendedNewCount: 0, revlog: revlog, timing: SchedTiming(),
                            localOffsetSecs: Int64(TimeZone.current.secondsFromGMT()))
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
                bar("Built") { ProgressView(value: stats.completion).tint(.green) }
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
        case .white: entry.sidecar?.color() == .white
        case .black: entry.sidecar?.color() == .black
        case .setup: entry.sidecar == nil
        }
    }
}

/// Progress of one repertoire: live from the open document, else from the sidecar.
struct EntryStats {
    var completion = 0.0
    var gaps = 0
    var savedMoves = 0
    var progress = Progress()
    var counts = Counts()
    /// Learning moves waiting for a later step today, soonest first.
    var laterLearning: [Date] = []
    var dueTomorrow = 0
    var nextDue: Date?
    /// Learning and review cards waiting today.
    var due: Int { Int(counts.learning + counts.review) }

    init(document: RepertoireDocument) {
        _ = document.revision
        let root = document.coverage.root
        completion = root?.completion ?? 0
        gaps = Int(root?.gapCount ?? 0)
        savedMoves = document.savedMoveCount
        progress = document.learningProgress()
        counts = document.studyCounts()
        let timing = SchedTiming()
        laterLearning = document.sidecar.laterLearningDues(timing: timing)
        dueTomorrow = document.sidecar.dueTomorrow(timing: timing)
        nextDue = document.sidecar.nextDue(timing: timing)
    }

    init(entry: RepertoireEntry, document: RepertoireDocument?) {
        if let document {
            self.init(document: document)
        } else {
            self.init(sidecar: entry.sidecar)
        }
    }

    private init(sidecar: LibrarySidecar?) {
        guard let sidecar else { return }
        let timing = SchedTiming()
        counts = sidecar.estimatedStudyCounts(newPerDay: Int64(TrainingDefaults.newPerDay),
                                              reviewsPerDay: Int64(TrainingDefaults.reviewsPerDay), timing: timing)
        progress = sidecar.estimatedProgress()
        laterLearning = sidecar.laterLearningDues(timing: timing).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        dueTomorrow = Int(sidecar.dueTomorrow(timing: timing))
        nextDue = sidecar.nextDue(timing: timing).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        guard let s = sidecar.summary() else { return }
        completion = s.completion
        gaps = Int(s.gapCount)
        // Older summaries have no move count: anything with your moves has saved moves.
        savedMoves = Int(s.savedMoveCount ?? s.cardCount)
    }
}

/// Signing in to Lichess as a list section, as Settings offers signing in: the action as a row,
/// why in the footer.
struct SignInBanner: View {
    var body: some View {
        Section {
            SignInButton()
        } footer: {
            Text("Coverage needs opponent statistics from the Lichess opening explorer, which needs a free Lichess account. Training works without it.")
        }
    }
}

/// Signs in to Lichess (a list row), with the last sign-in error under it.
struct SignInButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuth

    var body: some View {
        Button("Sign in with Lichess", systemImage: "person.crop.circle.badge.plus") {
            Task {
                if await model.auth.signIn(using: webAuth) { model.queue.resume() }
            }
        }
        if let error = model.auth.lastError {
            Text(error).font(.footnote).foregroundStyle(.red)
        }
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
                        .wordsAutocapitalization()
                        .onChange(of: name) { name = name.safeRepertoireName }
                }
                RepertoireSettingsForm(draft: $draft)
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle("New Repertoire")
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
    let onSave: (Data) throws -> Void
    @State private var draft = RepertoireSettingsDraft()
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                RepertoireSettingsForm(draft: $draft)
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(title)
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
                        .wordsAutocapitalization()
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") {
                        Task {
                            let newName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                            if newName != document.name {
                                do {
                                    try await model.rename(document, to: newName)
                                } catch {
                                    self.error = (error as? CocoaError)?.code == .fileWriteFileExists
                                        ? "A repertoire with this name already exists." : error.localizedDescription
                                    return
                                }
                            }
                            document.updateSettings(color: draft.color, database: draft.database,
                                                    targetGames: draft.targetGames)
                            dismiss()
                        }
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
