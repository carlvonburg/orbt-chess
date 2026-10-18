import OpeningCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuth
    @Environment(\.dismiss) private var dismiss
    @State private var cacheCount = 0
    @AppStorage(TrainingDefaults.newPerDayKey) private var newPerDay = DeckConfig().newPerDay
    @AppStorage(TrainingDefaults.reviewsPerDayKey) private var reviewsPerDay = DeckConfig().reviewsPerDay
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
                            Text(error).foregroundStyle(.red).font(.footnote)
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
                    Picker("Practice", selection: $practiceMode) {
                        ForEach(PracticeMode.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("Daily practice")
                } footer: {
                    Text("The default for every repertoire; each can override it in its settings. Scheduling follows Anki: learning steps of 1 and 10 minutes, FSRS with 90% retention, the day starts at 4 AM.")
                }

                Section {
                    LabeledContent("Storage", value: model.library.usesICloud ? "iCloud Drive › Opening Trainer" : "On this device")
                    LabeledContent("Cached positions", value: cacheCount.formatted())
                    Button("Clear Statistics Cache", role: .destructive) {
                        model.stats.clear()
                        cacheCount = model.stats.entryCount
                    }
                } header: {
                    Text("Data")
                } footer: {
                    Text("Repertoires are PGN files you can open in any chess program. Statistics are cached on this device and fetched again when needed.")
                }

                Section("About") {
                    LabeledContent("License", value: "AGPL-3.0")
                    Link("Lichess opening explorer", destination: URL(string: "https://lichess.org/analysis#explorer")!)
                    Text("Pieces: cburnett (GPLv2+), via Lichess. Rules: chesskit-swift (MIT). Scheduling: ported from Anki (AGPL-3.0) and fsrs-rs (BSD-3-Clause).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
            .onAppear { cacheCount = model.stats.entryCount }
        }
    }
}
