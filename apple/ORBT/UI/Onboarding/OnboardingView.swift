import OpeningCoreRust
import AuthenticationServices
import SwiftUI
import UniformTypeIdentifiers

/// The whole window while there is no repertoire, in place of the tabs and the library (which
/// have nothing to show yet): one welcome screen, what the app does above and the ways in at the
/// bottom, in reach — a new repertoire (the likely one, prominent), a PGN, or the repertoires
/// already kept in Dropbox or Google Drive. iCloud Drive needs no step: its repertoires arrive
/// on their own, and the first one ends onboarding (`RootView`), as does any repertoire made here.
///
/// HIG, Onboarding: brief, nothing to set up first (the setup's defaults do), the rest taught in
/// place by tips (`AppTips`). Liquid Glass: the content plain, glass only on the controls.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuth
    @State private var showImport = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 40) {
                VStack(spacing: 16) {
                    Image("AppIconImage")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 96, height: 96)
                        .accessibilityHidden(true)
                    Text("Welcome to ORBT Chess")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                }
                VStack(alignment: .leading, spacing: 28) {
                    FeatureRow(symbol: "chart.bar.xaxis", title: "See What Opponents Play",
                               text: "Every reply, with how often players at your level choose it and how it scores.")
                    FeatureRow(symbol: "scope", title: "Find the Gaps",
                               text: "The common replies you haven't prepared for yet, the most frequent first.")
                    FeatureRow(symbol: "brain.head.profile", title: "Remember Your Moves",
                               text: "Spaced repetition brings each move back just before you'd forget it.")
                }
            }
            .padding(.top, 48)
            .scenePadding(.horizontal)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaBar(edge: .bottom) { actions }
        .fileImporter(isPresented: $showImport, allowedContentTypes: [.pgn, .plainText]) { result in
            do {
                let file = try RepertoireLibrary.readImport(result.get())
                model.setup = SetupRequest(mode: .importing(data: file.data, name: file.name))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// The ways in, as the system's welcome screens stack them: the likely one prominent, the
    /// other the same size, and the sync as a menu of its providers under them.
    private var actions: some View {
        let sync = model.sync
        return VStack(spacing: 12) {
            Button("New Repertoire") { model.setup = SetupRequest(mode: .new) }
                .buttonStyle(.glassProminent)
            Button("Import a PGN…") { showImport = true }
                .buttonStyle(.glass)
            if let status = syncStatus {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(status)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            } else if let note = syncNote {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(sync.lastError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.failure))
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            if !sync.isSigningIn {
                // The choice Settings › Sync makes, checked on the one in use: iCloud Drive when
                // there is an account (it syncs already, nothing to do), else this device only.
                Menu {
                    Picker("Sync with", selection: Binding(get: { currentSync }, set: choose)) {
                        ForEach(syncChoices) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    if !hasICloud {
                        Button {} label: {
                            Text("iCloud Drive")
                            Text("Sign in to iCloud in the Settings app to use it.")
                        }
                        .disabled(true)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Sync: \(currentSync.title)")
                        Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                    }
                }
                .font(.subheadline)
                .padding(.top, 4)
            }
        }
        .buttonSizing(.flexible)
        .controlSize(.large)
        .frame(maxWidth: 480)
        .scenePadding()
    }

    private var hasICloud: Bool {
        FileManager.default.ubiquityIdentityToken != nil || model.library.usesICloud
    }

    /// As Settings › Sync: iCloud Drive while there is an iCloud account (or it is in use), the
    /// providers this build has, and off. Without an account iCloud Drive is listed disabled.
    private var syncChoices: [SyncChoice] {
        (hasICloud ? [.iCloud] : []) + SyncProvider.available.map(SyncChoice.provider) + [.off]
    }

    private var currentSync: SyncChoice {
        if let provider = model.sync.provider { return .provider(provider) }
        return model.library.usesICloud ? .iCloud : .off
    }

    /// A provider signs in (its repertoires then arrive); iCloud Drive is used again. Nothing to
    /// confirm: there are no repertoires to move.
    private func choose(_ choice: SyncChoice) {
        guard choice != currentSync else { return }
        let sync = model.sync
        Task {
            switch choice {
            case .provider(let provider):
                if sync.provider != nil { await sync.signOut() }
                await sync.signIn(provider, using: webAuth)
            case .iCloud:
                if sync.provider != nil { await sync.signOut(toICloud: true) } else { await model.moveRepertoires(toICloud: true) }
            case .off:
                if sync.provider != nil { await sync.signOut() } else { await model.moveRepertoires(toICloud: false) }
            }
        }
    }

    /// Signing in, then syncing until the first repertoire arrives (which ends onboarding).
    private var syncStatus: String? {
        let sync = model.sync
        if sync.isSigningIn { return "Signing in…" }
        guard let provider = sync.provider else { return nil }
        if case .syncing = sync.state { return "Downloading your repertoires from \(provider.title)…" }
        return nil
    }

    /// A failed sign-in, or a provider with nothing yet: what is made now syncs there.
    private var syncNote: String? {
        let sync = model.sync
        if let error = sync.lastError { return error }
        guard let provider = sync.provider, case .idle = sync.state else { return nil }
        return "\(provider.title) has no repertoires yet. The ones you create are kept there."
    }
}

/// One thing the app does, as Apple's welcome screens list them.
private struct FeatureRow: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol)
                .font(.title)
                .foregroundStyle(.tint)
                .frame(width: 44)
        }
        .labelStyle(.titleAndIcon)
    }
}
