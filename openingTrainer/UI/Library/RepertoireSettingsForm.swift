import OpeningCore
import SwiftUI

/// Editable repertoire settings: color, coverage database and coverage target.
struct RepertoireSettingsDraft: Equatable {
    var color: Side = .white
    var useMasters = false
    var speeds: Set<ExplorerSpeed> = [.blitz, .rapid, .classical]
    var ratings: Set<Int> = [1600, 1800, 2000]
    var targetGames = CoverageDepth.bulletproof.games
    var minGames = 25

    init() {}

    init(_ sidecar: Sidecar) {
        color = sidecar.color
        switch sidecar.database {
        case .masters:
            useMasters = true
        case let .lichess(speeds, ratings):
            self.speeds = Set(speeds)
            self.ratings = Set(ratings)
        }
        targetGames = sidecar.targetGames
        minGames = sidecar.minGames
    }

    var database: ExplorerDatabase {
        if useMasters { return .masters }
        return .lichess(speeds: ExplorerSpeed.allCases.filter(speeds.contains), ratings: ratings.sorted())
    }

    var isValid: Bool { useMasters || (!speeds.isEmpty && !ratings.isEmpty) }

    func makeSidecar() -> Sidecar {
        Sidecar(color: color, database: database, targetGames: targetGames, minGames: minGames)
    }
}

struct RepertoireSettingsForm: View {
    @Binding var draft: RepertoireSettingsDraft
    @State private var customTarget = false

    var body: some View {
        Section("I play") {
            Picker("Color", selection: $draft.color) {
                Text("White").tag(Side.white)
                Text("Black").tag(Side.black)
            }
            .pickerStyle(.segmented)
        }

        Section {
            Picker("Database", selection: $draft.useMasters) {
                Text("Lichess players").tag(false)
                Text("Masters").tag(true)
            }
            .pickerStyle(.segmented)
            if !draft.useMasters {
                ChipGrid(title: "Speeds", items: ExplorerSpeed.allCases, label: \.title, selection: $draft.speeds)
                ChipGrid(title: "Opponent rating", items: ExplorerDatabase.ratingBuckets,
                         label: { $0 == 0 ? "<1000" : $0 == 2500 ? "2500+" : "\($0)" }, selection: $draft.ratings)
            }
        } header: {
            Text("Coverage database")
        } footer: {
            Text("Opponent move frequencies come from this Lichess explorer database.")
        }

        Section {
            let isPreset = CoverageDepth(games: draft.targetGames) != nil
            ForEach(CoverageDepth.allCases) { depth in
                Button {
                    customTarget = false
                    draft.targetGames = depth.games
                } label: {
                    DepthRow(name: depth.title, games: depth.games,
                             selected: !customTarget && draft.targetGames == depth.games)
                }
                .tint(.primary)
            }
            Button {
                customTarget = true
            } label: {
                DepthRow(name: "Custom", games: isPreset && !customTarget ? nil : draft.targetGames,
                         selected: customTarget || !isPreset)
            }
            .tint(.primary)
            if customTarget || !isPreset {
                Stepper("1 in \(draft.targetGames.formatted()) games", value: $draft.targetGames, in: 20...20000, step: 50)
            }
            Stepper("Ignore positions under \(draft.minGames) games", value: $draft.minGames, in: 1...500, step: 5)
        } header: {
            Text("How much do you want to learn?")
        } footer: {
            Text("Every opponent move you would meet at least once in this many games must have an answer in your repertoire. Deeper goals mean more lines to learn.")
        }
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
                .fill(Color.accentColor.opacity(selected ? 1 : 0.45))
                .frame(width: games.map { 6 + 40 * min(Double($0) / 800, 1.2) } ?? 0, height: 5)
                .frame(width: 54, alignment: .leading)
            Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.accentColor)
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

/// Daily limits and practice mode, as Anki's deck options: the preset (all repertoires), this
/// repertoire, or today only.
struct DailyPracticeDraft: Equatable {
    enum Scope: String, CaseIterable, Identifiable {
        case preset, deck, today
        var id: Self { self }
        var title: String {
            switch self {
            case .preset: "Default"
            case .deck: "This Repertoire"
            case .today: "Today Only"
            }
        }
    }

    var presetNew = TrainingDefaults.newPerDay
    var presetReviews = TrainingDefaults.reviewsPerDay
    var presetPracticeMode = TrainingDefaults.practiceMode
    var limits = DeckLimits()
    var practiceMode: PracticeMode?
    var scope = Scope.preset
    let today: Int

    init(sidecar: Sidecar, today: Int) {
        self.today = today
        limits = sidecar.limits ?? DeckLimits()
        practiceMode = sidecar.practiceMode
        if limits.newLimitToday?.today == today || limits.reviewLimitToday?.today == today {
            scope = .today
        } else if limits.newLimit != nil || limits.reviewLimit != nil {
            scope = .deck
        }
    }

    /// The value shown for the selected scope; editing it sets that scope.
    var newPerDay: Int {
        get {
            switch scope {
            case .preset: presetNew
            case .deck: limits.newLimit ?? presetNew
            case .today: limits.newLimitToday.flatMap { $0.today == today ? $0.limit : nil } ?? limits.newLimit ?? presetNew
            }
        }
        set {
            switch scope {
            case .preset: presetNew = newValue
            case .deck: limits.newLimit = newValue
            case .today: limits.newLimitToday = DayLimit(limit: newValue, today: today)
            }
        }
    }

    var reviewsPerDay: Int {
        get {
            switch scope {
            case .preset: presetReviews
            case .deck: limits.reviewLimit ?? presetReviews
            case .today: limits.reviewLimitToday.flatMap { $0.today == today ? $0.limit : nil } ?? limits.reviewLimit ?? presetReviews
            }
        }
        set {
            switch scope {
            case .preset: presetReviews = newValue
            case .deck: limits.reviewLimit = newValue
            case .today: limits.reviewLimitToday = DayLimit(limit: newValue, today: today)
            }
        }
    }

    /// Choosing a narrower scope clears the narrower overrides when going back to a wider one.
    mutating func select(_ newScope: Scope) {
        switch newScope {
        case .preset:
            limits = DeckLimits()
        case .deck:
            limits.newLimitToday = nil
            limits.reviewLimitToday = nil
        case .today:
            break
        }
        scope = newScope
    }

    func savePreset() {
        UserDefaults.standard.set(presetNew, forKey: TrainingDefaults.newPerDayKey)
        UserDefaults.standard.set(presetReviews, forKey: TrainingDefaults.reviewsPerDayKey)
        UserDefaults.standard.set(presetPracticeMode.rawValue, forKey: TrainingDefaults.practiceModeKey)
    }
}

struct DailyPracticeSection: View {
    @Binding var draft: DailyPracticeDraft

    var body: some View {
        Section {
            Picker("Limits apply to", selection: Binding(get: { draft.scope }, set: { draft.select($0) })) {
                ForEach(DailyPracticeDraft.Scope.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Stepper("New moves/day: \(draft.newPerDay)", value: $draft.newPerDay, in: 0...9999)
            Stepper("Maximum reviews/day: \(draft.reviewsPerDay)", value: $draft.reviewsPerDay, in: 0...9999, step: 10)
        } header: {
            Text("Daily limits")
        } footer: {
            Text(footer)
        }

        Section {
            Picker("This repertoire", selection: $draft.practiceMode) {
                Text("Default (\(draft.presetPracticeMode.title))").tag(PracticeMode?.none)
                ForEach(PracticeMode.allCases) { Text($0.title).tag(PracticeMode?.some($0)) }
            }
            Picker("Default", selection: $draft.presetPracticeMode) {
                ForEach(PracticeMode.allCases) { Text($0.title).tag($0) }
            }
        } header: {
            Text("Practice")
        } footer: {
            Text("Every line starts from the first move. Individual moves: the app plays the moves leading up to the ones you are asked. Complete lines: you play all your moves, every time or once per session. The default applies to all repertoires.")
        }

        let config = DeckConfig()
        Section {
            LabeledContent("Learning steps", value: steps(config.learnSteps))
            LabeledContent("Relearning steps", value: steps(config.relearnSteps))
            LabeledContent("Desired retention", value: Format.percent(config.desiredRetention))
            LabeledContent("Next day starts at", value: "\(SchedTiming.rolloverHour) AM")
        } header: {
            Text("Scheduling")
        } footer: {
            Text("Anki's defaults with FSRS.")
        }
    }

    private func steps(_ minutes: [Double]) -> String {
        minutes.map { $0 < 60 ? "\(Int($0))m" : "\(Int($0 / 60))h" }.joined(separator: " ")
    }

    private var footer: String {
        switch draft.scope {
        case .preset: "The default for all repertoires. A line of new moves that has started is always finished."
        case .deck: "Only for this repertoire."
        case .today: "Only for this repertoire, today."
        }
    }
}
