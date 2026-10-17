import OpeningCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuth
    @State private var cacheCount = 0

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
                    LabeledContent("License", value: "GPL-3.0")
                    Link("Lichess opening explorer", destination: URL(string: "https://lichess.org/analysis#explorer")!)
                    Text("Pieces: cburnett (GPLv2+), via Lichess. Rules: chesskit-swift (MIT). Scheduling: FSRS.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .onAppear { cacheCount = model.stats.entryCount }
        }
    }
}
