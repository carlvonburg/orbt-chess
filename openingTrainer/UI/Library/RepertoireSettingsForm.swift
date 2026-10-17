import OpeningCore
import SwiftUI

/// Editable repertoire settings: color, coverage database and coverage target.
struct RepertoireSettingsDraft: Equatable {
    var color: Side = .white
    var useMasters = false
    var speeds: Set<ExplorerSpeed> = [.blitz, .rapid, .classical]
    var ratings: Set<Int> = [1600, 1800, 2000]
    var targetGames = 500
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

    static let presets = [100, 250, 500, 1000, 2000]

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
            Picker("Cover moves seen", selection: Binding(
                get: { customTarget || !Self.presets.contains(draft.targetGames) ? 0 : draft.targetGames },
                set: { value in
                    if value == 0 { customTarget = true } else { customTarget = false; draft.targetGames = value }
                })) {
                ForEach(Self.presets, id: \.self) { Text("once in \($0.formatted()) games").tag($0) }
                Text("Custom").tag(0)
            }
            if customTarget || !Self.presets.contains(draft.targetGames) {
                Stepper("Once in \(draft.targetGames.formatted()) games", value: $draft.targetGames, in: 20...20000, step: 50)
            }
            Stepper("Ignore positions under \(draft.minGames) games", value: $draft.minGames, in: 1...500, step: 5)
        } header: {
            Text("Coverage target")
        } footer: {
            Text("Every opponent move you would meet at least once in this many games must have an answer in your repertoire.")
        }
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
