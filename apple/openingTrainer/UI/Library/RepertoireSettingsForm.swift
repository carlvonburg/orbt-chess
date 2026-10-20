import OpeningCoreRust
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

    init(_ sidecar: RepertoireDocument.SidecarValues) {
        color = sidecar.color
        switch sidecar.database {
        case .masters:
            useMasters = true
        case let .lichess(ratings, speeds):
            self.speeds = Set(speeds)
            self.ratings = Set(ratings.map(Int.init))
        }
        targetGames = sidecar.targetGames
        minGames = sidecar.minGames
    }

    var database: ExplorerDatabase {
        if useMasters { return .masters }
        return .lichess(ratings: ratings.sorted().map(Int64.init), speeds: ExplorerSpeed.allCases.filter(speeds.contains))
    }

    var isValid: Bool { useMasters || (!speeds.isEmpty && !ratings.isEmpty) }

    /// The sidecar file of a new repertoire with these settings.
    func makeSidecar() -> Data {
        newSidecar(id: UUID().uuidString, color: color, database: database, targetGames: Int64(targetGames),
                   minGames: Int64(minGames), now: .of(.now))
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
                    .accessibilityAddTraits(option == mode ? .isSelected : [])
                }
            }
            .navigationTitle("Practice")
            .inlineNavigationTitle()
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
