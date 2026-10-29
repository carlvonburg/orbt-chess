import OpeningCoreRust
import SwiftUI

/// Where a repertoire's opponent move frequencies come from: games of one time control in one
/// rating bin, from an offline table downloaded when chosen. Blitz and rapid are Lichess games
/// (Lichess ratings), classical are over-the-board games (FIDE ratings, Lumbra's Gigabase).
enum CoverageSource: Hashable, CaseIterable {
    case blitz, rapid, classical

    var title: String {
        switch self {
        case .blitz: "Blitz"
        case .rapid: "Rapid"
        case .classical: "Classical"
        }
    }

    /// Whose games they are.
    var detail: String {
        switch self {
        case .blitz, .rapid: "Lichess games, Lichess rating"
        case .classical: "Over-the-board games, FIDE rating"
        }
    }

    func database(rating: Int) -> ExplorerDatabase {
        switch self {
        case .blitz: .lichess(ratings: [Int64(rating)], speeds: [.blitz])
        case .rapid: .lichess(ratings: [Int64(rating)], speeds: [.rapid])
        case .classical: .otb(ratings: [Int64(rating)])
        }
    }

    /// Whether a table's database is one of this source's bins.
    func matches(_ database: ExplorerDatabase) -> Bool {
        database == self.database(rating: database.lowestRating)
    }
}

/// Editable repertoire settings: color, coverage database and coverage target.
struct RepertoireSettingsDraft: Equatable {
    var color: Side = .white
    var source = CoverageSource.blitz
    /// The rating bin (lower bound, one of `ExplorerDatabase.eloBins`).
    var rating = 1600
    var targetGames = CoverageDepth.bulletproof.games

    init() {}

    init(_ sidecar: RepertoireDocument.SidecarValues) {
        color = sidecar.color
        // Older repertoires chose several speeds and buckets, or the masters database: show the
        // closest single choice.
        switch sidecar.database {
        case .masters:
            source = .classical
            rating = 2200
        case let .otb(ratings):
            source = .classical
            rating = Int(ratings.min() ?? 2200)
        case let .lichess(ratings, speeds):
            source = speeds.contains(.blitz) || !speeds.contains(.rapid) ? .blitz : .rapid
            let low = Int(ratings.min() ?? 1600)
            rating = ExplorerDatabase.eloBins.last { $0 <= low } ?? 1600
        }
        targetGames = sidecar.targetGames
    }

    var database: ExplorerDatabase { source.database(rating: rating) }

    /// The defaults with the last new repertoire's games, rating and depth (not its side):
    /// a second repertoire usually prepares for the same opponents.
    static func lastUsed() -> Self {
        var draft = Self()
        let defaults = UserDefaults.standard
        if let source = defaults.string(forKey: Self.sourceKey),
           let saved = CoverageSource.allCases.first(where: { "\($0)" == source }) {
            draft.source = saved
        }
        if defaults.object(forKey: Self.ratingKey) != nil { draft.rating = defaults.integer(forKey: Self.ratingKey) }
        if defaults.object(forKey: Self.depthKey) != nil { draft.targetGames = defaults.integer(forKey: Self.depthKey) }
        return draft
    }

    func remember() {
        let defaults = UserDefaults.standard
        defaults.set("\(source)", forKey: Self.sourceKey)
        defaults.set(rating, forKey: Self.ratingKey)
        defaults.set(targetGames, forKey: Self.depthKey)
    }

    private static let sourceKey = "newRepertoireSource"
    private static let ratingKey = "newRepertoireRating"
    private static let depthKey = "newRepertoireDepth"

    var isValid: Bool { true }

    /// The sidecar file of a new repertoire with these settings.
    func makeSidecar() -> Data {
        newSidecar(id: UUID().uuidString, color: color, database: database, targetGames: Int64(targetGames),
                   now: .of(.now))
    }
}

/// Every repertoire setting on one page (Repertoire Settings); new repertoires take them one
/// step at a time (`RepertoireSetupFlow`).
struct RepertoireSettingsForm: View {
    @Binding var draft: RepertoireSettingsDraft

    var body: some View {
        Section("I play") {
            Picker("Color", selection: $draft.color) {
                Text("White").tag(Side.white)
                Text("Black").tag(Side.black)
            }
            .pickerStyle(.segmented)
        }
        CoverageSourceSection(draft: $draft, style: .segmented)
        DepthSection(targetGames: $draft.targetGames)
    }
}

/// Where opponent move frequencies come from: the time control, the rating bin and its table
/// (downloaded as soon as it is chosen).
struct CoverageSourceSection: View {
    enum Style { case segmented, list }

    @Environment(AppModel.self) private var model
    @Binding var draft: RepertoireSettingsDraft
    let style: Style

    private var coverage: CoverageTables { model.coverage }
    /// Every offline selection: on the server or on this device.
    private var tables: [ExplorerDatabase] { coverage.selections }

    var body: some View {
        switch style {
        case .segmented:
            Section {
                Picker("Database", selection: $draft.source) {
                    ForEach(CoverageSource.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                ratingPicker
            } header: {
                Text("Coverage database")
            } footer: {
                footer
            }
        case .list:
            Section {
                Picker("Games", selection: $draft.source) {
                    ForEach(CoverageSource.allCases, id: \.self) { source in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.title)
                            Text(source.detail).font(.footnote).foregroundStyle(.secondary)
                        }
                        .tag(source)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Their games")
            }
            Section {
                ratingPicker
            } footer: {
                footer
            }
        }
    }

    private var footer: Text {
        Text(draft.source == .classical
             ? "Opponent move frequencies come from over-the-board games since the year 2000 at this average FIDE rating (Lumbra's Gigabase, CC BY-NC 4.0), downloaded to this device. Only positions it doesn't hold come from the Lichess explorer (\(classicalBackup))."
             : "Opponent move frequencies come from Lichess \(draft.source.title.lowercased()) games at this average rating, downloaded to this device. Positions it doesn't hold come from the Lichess explorer.")
    }

    /// Which Lichess games answer the positions a Classical table lacks, for the footer.
    private var classicalBackup: String {
        let backup = draft.database.fetchedAs
        if case .masters = backup { return "masters games" }
        return "\(backup.summary), one rating bin up, as Lichess ratings run higher than FIDE"
    }

    /// The rating bins with a table for the chosen time control, the chosen one's download
    /// state, and the download itself, started as soon as a bin is chosen.
    @ViewBuilder private var ratingPicker: some View {
        let bins = tables.filter(draft.source.matches).map(\.lowestRating).sorted()
        Picker(style == .list ? "Their rating" : "Opponent rating", selection: $draft.rating) {
            ForEach(bins.contains(draft.rating) ? bins : bins + [draft.rating], id: \.self) { bin in
                Text(ExplorerDatabase.ratingLabel(bin)).tag(bin)
            }
        }
        .onChange(of: draft.source) {
            // Keep the rating when the new time control has it, else take the nearest bin.
            let bins = tables.filter(draft.source.matches).map(\.lowestRating)
            if !bins.isEmpty, !bins.contains(draft.rating) {
                draft.rating = bins.min { abs($0 - draft.rating) < abs($1 - draft.rating) } ?? draft.rating
            }
        }
        TableDownloadRow(coverage: coverage, database: draft.database)
            .task(id: "\(draft.database.cacheKey) \(coverage.available.count)") {
                // Not tied to this view: the download finishes after the sheet closes.
                coverage.ensure(draft.database)
            }
    }
}

/// How much to learn: the named coverage targets, or a custom one.
struct DepthSection: View {
    @Binding var targetGames: Int
    /// In the setup flow, whose step title asks the question and which can be changed later.
    var inSetup = false
    @State private var customTarget = false

    var body: some View {
        Section {
            let isPreset = CoverageDepth(games: targetGames) != nil
            ForEach(CoverageDepth.allCases) { depth in
                Button {
                    customTarget = false
                    targetGames = depth.games
                } label: {
                    DepthRow(name: depth.title, games: depth.games,
                             selected: !customTarget && targetGames == depth.games)
                }
                .tint(.primary)
                .formRowButton()
            }
            Button {
                customTarget = true
            } label: {
                DepthRow(name: "Custom", games: isPreset && !customTarget ? nil : targetGames,
                         selected: customTarget || !isPreset)
            }
            .tint(.primary)
            if customTarget || !isPreset {
                Stepper("1 in \(targetGames.formatted()) games", value: $targetGames, in: 20...20000, step: 50)
            }
        } header: {
            if !inSetup { Text("How much do you want to learn?") }
        } footer: {
            Text("Every opponent move you would meet at least once in this many games must have an answer in your repertoire. Deeper goals mean more lines to learn."
                 + (inSetup ? " You can change this later in the repertoire's settings." : ""))
        }
    }
}

/// Whether the chosen table is on this device, and a button to download it.
private struct TableDownloadRow: View {
    let coverage: CoverageTables
    let database: ExplorerDatabase

    var body: some View {
        let file = coverage.file(for: database)
        if coverage.isReady(database) {
            Label("On this device", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        } else if let file, let fraction = coverage.downloads[file.file] {
            ProgressView(value: fraction) {
                Text("Downloading \(ByteCountFormatter.string(fromByteCount: file.bytes, countStyle: .file))")
            }
        } else if file != nil {
            Button("Download Again", systemImage: "arrow.down.circle") {
                Task { await coverage.retry(database) }
            }
        } else {
            Label("Not available offline: coverage uses the Lichess explorer", systemImage: "icloud.slash")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if let file, !coverage.isReady(database), let error = coverage.failures[file.file] {
            Text(error).font(.footnote).foregroundStyle(.failure)
        }
    }
}

extension ExplorerDatabase {
    var lowestRating: Int {
        switch self {
        case let .lichess(ratings, _), let .otb(ratings): Int(ratings.min() ?? 0)
        case .masters: 0
        }
    }

    /// "2000–2199", "<600", "2500+" for a bin's lower bound.
    static func ratingLabel(_ low: Int) -> String {
        guard let next = eloBins.first(where: { $0 > low }) else { return "\(low)+" }
        return low == 0 ? "<\(next)" : "\(low)–\(next - 1)"
    }
}

/// Named coverage targets ("cover moves seen once in N games").
enum CoverageDepth: Int, CaseIterable, Identifiable {
    case standard = 150, advanced = 200, tournament = 300, bulletproof = 400, overkill = 600, extremeOverkill = 800

    var id: Int { rawValue }
    var games: Int { rawValue }
    init?(games: Int) { self.init(rawValue: games) }

    var title: String {
        switch self {
        case .standard: "Standard"
        case .advanced: "Advanced"
        case .tournament: "Tournament"
        case .bulletproof: "Bulletproof"
        case .overkill: "Overkill"
        case .extremeOverkill: "Extreme overkill"
        }
    }
}

/// One coverage goal: name, "1 in N games", and a bar for how much study it takes.
private struct DepthRow: View {
    let name: String
    let games: Int?
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(name)
                .fontWeight(selected ? .semibold : .regular)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(games.map { "1 in \($0.formatted()) games" } ?? "")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            // Study time grows roughly with the number of games covered.
            Capsule()
                .fill(.tint.opacity(selected ? 1 : 0.45))
                .frame(width: games.map { 6 + 40 * min(Double($0) / 800, 1.2) } ?? 0, height: 5)
                .frame(width: 54, alignment: .leading)
            Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(.tint)
                .opacity(selected ? 1 : 0)
        }
        .contentShape(Rectangle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Multi-select chips in a flowing grid.
struct ChipGrid<Item: Hashable>: View {
    let title: String
    let items: [Item]
    let label: (Item) -> String
    @Binding var selection: Set<Item>

    init(title: String, items: [Item], label: @escaping (Item) -> String, selection: Binding<Set<Item>>) {
        self.title = title
        self.items = items
        self.label = label
        self._selection = selection
    }

    init(title: String, items: [Item], label: KeyPath<Item, String>, selection: Binding<Set<Item>>) {
        self.init(title: title, items: items, label: { $0[keyPath: label] }, selection: selection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(items, id: \.self) { item in
                    let on = selection.contains(item)
                    Button {
                        if on { selection.remove(item) } else { selection.insert(item) }
                    } label: {
                        Text(label(item))
                            .font(.footnote.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(on ? .accentColor : .secondary)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// A repertoire's daily limits and practice mode: the defaults from Settings, or its own
/// (Anki's "This deck" limits). One-day changes are custom study, from the overview.
struct DailyPracticeDraft: Equatable {
    let presetNew = TrainingDefaults.newPerDay
    let presetReviews = TrainingDefaults.reviewsPerDay
    let presetPracticeMode = TrainingDefaults.practiceMode
    var limits = DeckLimits()
    /// This repertoire's practice mode; nil uses the default.
    var practiceMode: PracticeMode?

    init(sidecar: RepertoireDocument.SidecarValues) {
        limits = sidecar.limits ?? DeckLimits()
        // Limits for one day only are no longer offered; drop any left over.
        limits.newLimitToday = nil
        limits.reviewLimitToday = nil
        practiceMode = sidecar.practiceMode
    }

    /// Off: this repertoire's own limits, starting from the defaults.
    var useDefaultLimits: Bool {
        get { limits.newLimit == nil && limits.reviewLimit == nil }
        set {
            if newValue {
                limits = DeckLimits()
            } else {
                limits.newLimit = Int64(presetNew)
                limits.reviewLimit = Int64(presetReviews)
            }
        }
    }

    var newPerDay: Int {
        get { limits.newLimit.map(Int.init) ?? presetNew }
        set { limits.newLimit = Int64(newValue) }
    }

    var reviewsPerDay: Int {
        get { limits.reviewLimit.map(Int.init) ?? presetReviews }
        set { limits.reviewLimit = Int64(newValue) }
    }

    var mode: PracticeMode {
        get { practiceMode ?? presetPracticeMode }
        set { practiceMode = newValue }
    }
}

/// A repertoire's options: the default limits or its own, and its practice mode.
struct DailyPracticeSection: View {
    @Binding var draft: DailyPracticeDraft

    var body: some View {
        Section {
            Toggle("Use Default Limits", isOn: $draft.useDefaultLimits)
            Group {
                Stepper("New moves/day: \(draft.newPerDay)", value: $draft.newPerDay, in: 0...9999)
                Stepper("Maximum reviews/day: \(draft.reviewsPerDay)", value: $draft.reviewsPerDay, in: 0...9999, step: 10)
            }
            .disabled(draft.useDefaultLimits)
            .foregroundStyle(draft.useDefaultLimits ? .secondary : .primary)
        } header: {
            Text("Daily limits")
        } footer: {
            Text(draft.useDefaultLimits
                 ? "From Settings. Turn off to set limits for this repertoire."
                 : "Every day, for this repertoire only. To study more just today, use Study More Today in the overview.")
        }

        Section {
            PracticeModePicker(mode: $draft.mode)
            if draft.practiceMode != nil {
                Button("Use Default (\(draft.presetPracticeMode.title))") { draft.practiceMode = nil }
            }
        } footer: {
            Text(draft.practiceMode == nil ? "The default, set in Settings." : "Only for this repertoire.")
        }
    }
}

/// The three practice modes, each with what it does.
struct PracticeModePicker: View {
    @Binding var mode: PracticeMode

    var body: some View {
        NavigationLink {
            List {
                ForEach(PracticeMode.allCases) { option in
                    Button { mode = option } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title)
                                Text(option.detail).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if option == mode { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                    .tint(.primary)
                .formRowButton()
                    .accessibilityAddTraits(option == mode ? .isSelected : [])
                }
            }
            .navigationTitle("Practice")
        } label: {
            LabeledContent("Practice", value: mode.title)
        }
    }
}

extension PracticeMode {
    /// Who plays your moves on the way to the ones you're asked.
    var detail: String {
        switch self {
        case .individualMoves: "The app plays the moves leading up to the ones you're asked."
        case .completeLinesEveryTime: "You play all your moves on every line."
        case .completeLinesOncePerSession: "You play your moves the first time they come up; after that the app does."
        }
    }
}
