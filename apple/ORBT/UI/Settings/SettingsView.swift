import OpeningCoreRust
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuth
    @Environment(\.dismiss) private var dismiss
    @State private var cacheCount = 0
    @AppStorage(TrainingDefaults.newPerDayKey) private var newPerDay = Int(TrainingDefaults.preset.newPerDay)
    @AppStorage(TrainingDefaults.reviewsPerDayKey) private var reviewsPerDay = Int(TrainingDefaults.preset.reviewsPerDay)
    @AppStorage(TrainingDefaults.practiceModeKey) private var practiceMode = PracticeMode.default

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if model.auth.isSignedIn {
                        LabeledContent("Signed in as", value: model.auth.username ?? "Lichess user")
                        if let expires = model.auth.expiresAt {
                            LabeledContent("Session valid until", value: expires.formatted(date: .abbreviated, time: .omitted))
                        }
                        Button("Sign Out", role: .destructive) {
                            Task { await model.auth.signOut() }
                        }
                    } else {
                        Button("Sign in with Lichess") {
                            Task { if await model.auth.signIn(using: webAuth) { model.queue.resume() } }
                        }
                        if let error = model.auth.lastError {
                            Text(error).foregroundStyle(.failure).font(.footnote)
                        }
                    }
                } header: {
                    Text("Lichess")
                } footer: {
                    Text("Used only to read opening statistics from the Lichess explorer. No scopes are requested.")
                }

                Section {
                    Stepper("New moves/day: \(newPerDay)", value: $newPerDay, in: 0...9999)
                    Stepper("Maximum reviews/day: \(reviewsPerDay)", value: $reviewsPerDay, in: 0...9999, step: 10)
                    PracticeModePicker(mode: $practiceMode)
                } header: {
                    Text("Study defaults")
                } footer: {
                    Text("For every repertoire. A repertoire's options can set its own. A line of new moves that has started is always finished.")
                }

                Section {
                    LabeledContent("Learning steps", value: steps(TrainingDefaults.preset.learnSteps))
                    LabeledContent("Relearning steps", value: steps(TrainingDefaults.preset.relearnSteps))
                    LabeledContent("Desired retention", value: Format.percent(TrainingDefaults.preset.desiredRetention))
                    LabeledContent("Next day starts at", value: "\(SchedTiming.rolloverHour) AM")
                } header: {
                    Text("Scheduling")
                } footer: {
                    Text("Anki's defaults with FSRS.")
                }

                Section {
                    AppColorPicker()
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("Buttons, selection and the board.")
                }

                EngineSettingsSection()

                Section {
                    LabeledContent("Storage", value: model.library.usesICloud ? "iCloud Drive › ORBT" : "On this device")
                    LabeledContent("Cached positions", value: cacheCount.formatted())
                    Button("Clear Statistics Cache", role: .destructive) {
                        model.stats.clear()
                        cacheCount = model.stats.entryCount
                    }
                } header: {
                    Text("Data")
                } footer: {
                    Text((model.library.usesICloud ? "" : "iCloud Drive is off, so repertoires are stored on this device only. ")
                         + "Repertoires are PGN files you can open in any chess program. Statistics are cached on this device and fetched again when needed.")
                }

                Section("About") {
                    LabeledContent("License", value: "AGPL-3.0")
                    LabeledContent("Core", value: "Rust \(coreVersion())")
                    Link("Lichess opening explorer", destination: URL(string: "https://lichess.org/analysis#explorer")!)
                    Link("Stockfish source code", destination: URL(string: "https://github.com/official-stockfish/Stockfish")!)
                    Text("Pieces: cburnett (GPLv2+), via Lichess. Rules: chesskit-swift (MIT). Scheduling: ported from Anki (AGPL-3.0) and fsrs-rs (BSD-3-Clause). Engine: Stockfish 19 by the Stockfish developers (GPL-3.0), built as in Lichess's multistockfish.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            #if os(iOS)
            // A sheet on iPhone and iPad; the Mac's Settings window closes like any window.
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
            #endif
            .onAppear { cacheCount = model.stats.entryCount }
        }
    }

    private func steps(_ minutes: [Double]) -> String {
        minutes.map { $0 < 60 ? "\(Int($0))m" : "\(Int($0 / 60))h" }.joined(separator: " ")
    }
}

/// The analysis engine's settings, in Settings and on the analysis board.
struct EngineSettingsSection: View {
    @Environment(AppModel.self) private var model
    @AppStorage(EngineDefaults.searchTimeKey) private var searchTime = EngineDefaults.searchTime
    @AppStorage(EngineDefaults.linesKey) private var engineLines = EngineDefaults.lines
    @AppStorage(EngineDefaults.cloudKey) private var cloudEvals = EngineDefaults.cloud
    @AppStorage(EngineDefaults.fullNetworkKey) private var fullNetwork = EngineDefaults.fullNetwork

    var body: some View {
        Section {
            LabeledContent("Search time") {
                Text("\(searchTime) s").monospacedDigit()
            }
            Slider(value: Binding(get: { Double(searchTime) }, set: { searchTime = Int($0) }),
                   in: Double(EngineDefaults.searchTimes.lowerBound)...Double(EngineDefaults.searchTimes.upperBound),
                   step: 1) {
                Text("Search time")
            }
            Stepper("Lines: \(engineLines)", value: $engineLines, in: EngineDefaults.lineCounts)
            Toggle("Lichess cloud evaluations", isOn: $cloudEvals)
            EngineNetworkRow(network: model.engineNetwork, use: $fullNetwork)
        } header: {
            Text("Analysis engine")
        } footer: {
            Text("Stockfish 19 runs on this device, with its 1 MB network built in; the full network is stronger. Where Lichess has a deep cloud evaluation of a position, it is shown and the engine does not run.")
        }
    }
}

/// Stockfish's full network: download it, follow the download, use or remove it.
private struct EngineNetworkRow: View {
    let network: EngineNetwork
    @Binding var use: Bool

    var body: some View {
        switch network.state {
        case .absent:
            Button("Download Full Network (94 MB)", systemImage: "arrow.down.circle") { network.start() }
        case .downloading(let fraction):
            HStack {
                ProgressView("Downloading full network", value: fraction)
                Button("Cancel", systemImage: "xmark.circle.fill") { network.cancel() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
        case .ready:
            Toggle("Use full network", isOn: $use)
            Button("Remove Full Network", systemImage: "trash", role: .destructive) { network.remove() }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Button("Download Full Network (94 MB)", systemImage: "arrow.down.circle") { network.start() }
                Text(message).font(.footnote).foregroundStyle(.failure)
            }
        }
    }
}

/// The app color, each shown as a strip of the board it gives (as lichess shows its boards).
struct AppColorPicker: View {
    @AppStorage(AppColor.key) private var appColor = AppColor.default

    var body: some View {
        NavigationLink {
            List {
                ForEach(AppColor.allCases) { option in
                    Button { appColor = option } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(option.title)
                                BoardStrip(color: option, squares: 6).frame(height: 36)
                            }
                            Spacer()
                            if option == appColor { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                    .tint(.primary)
                    .accessibilityAddTraits(option == appColor ? .isSelected : [])
                }
            }
            .navigationTitle("Color")
        } label: {
            LabeledContent("Color") {
                HStack(spacing: 8) {
                    Text(appColor.title)
                    BoardStrip(color: appColor, squares: 2).frame(width: 36, height: 18)
                }
            }
        }
    }
}

/// A row of board squares in the board's colors for an app color.
private struct BoardStrip: View {
    let color: AppColor
    let squares: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<squares, id: \.self) { i in
                Rectangle()
                    .fill(i.isMultiple(of: 2) ? Theme(appColor: color).board.light : Theme(appColor: color).board.dark)
                    .aspectRatio(1, contentMode: .fit)
            }
        }
        .clipShape(.rect(cornerRadius: 3))
        .accessibilityHidden(true)
    }
}
