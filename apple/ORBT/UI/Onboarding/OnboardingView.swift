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
/// place by tips (`AppTips`). The app shows itself as on the App Store: a product shot of its
/// own board and cards (a gap, a correct answer, today's moves) on a glow of the app color. All
/// of it content (solid cards, never glass); Liquid Glass only on the controls.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuth
    @State private var showImport = false
    @State private var errorMessage: String?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            // A wide, short window (iPad in landscape, the Mac): the shot beside the text and the
            // ways in, as a landscape App Store screenshot; else one column.
            if size.width > size.height && size.width >= 600 {
                sideBySide(size)
            } else {
                column(size)
            }
        }
        // The setup sheet's keyboard is the window's: without this the screen behind the sheet
        // lays out again while it comes and goes. Nothing here takes text.
        .ignoresSafeArea(.keyboard)
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

    /// One column: the shot, then the text, scrolling over the glow; the ways in in the bottom
    /// bar. The shot gets smaller where the window is narrow or short, so the text stays in view,
    /// and larger on a big screen (up to 1.4×).
    private func column(_ size: CGSize) -> some View {
        ScrollView {
            VStack(spacing: 28) {
                ProductShot(scale: ProductShot.fit(width: size.width - 16, height: size.height - 440, largest: 1.4))
                headline
            }
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        // Centered in the room above the bar when it fits (a tall iPad), not at its top.
        .defaultScrollAnchor(.center, for: .alignment)
        // The glow of the app color behind the shot, to the top edge; the backdrop, so it
        // stays put while the rest scrolls at large text sizes.
        .background(alignment: .top) { glow }
        .safeAreaBar(edge: .bottom) { actions }
    }

    /// Side by side: the shot in the leading half (larger on a big screen, where it has half the
    /// window to itself), the text and the ways in centered in the trailing half.
    private func sideBySide(_ size: CGSize) -> some View {
        HStack(spacing: 0) {
            ProductShot(scale: ProductShot.fit(width: size.width / 2 - 32, height: size.height - 32, largest: 1.4))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(alignment: .top) { glow }
            ScrollView {
                VStack(spacing: 24) {
                    headline
                    actions
                }
                .frame(maxWidth: .infinity, minHeight: size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity)
        }
    }

    /// The app's name, its headline and what it does.
    private var headline: some View {
        VStack(spacing: 8) {
            Text("ORBT CHESS")
                .font(.caption.weight(.semibold))
                .tracking(1.5)
                .foregroundStyle(.tint)
            Text("Your Openings,\nWithout the Gaps")
                .font(.largeTitle.bold())
            Text("Build from what opponents really play. Remember it with spaced repetition.")
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .multilineTextAlignment(.center)
        .scenePadding(.horizontal)
        .frame(maxWidth: 480)
    }

    /// A glow of the app color from the top edge, behind the shot.
    private var glow: some View {
        Rectangle()
            .fill(.tint.opacity(0.55))
            .mask(RadialGradient(colors: [.black, .clear], center: .top, startRadius: 0, endRadius: 460))
            // Its own width, not its container's: in half a window it would end in a straight edge.
            .frame(width: 920, height: 520)
            .ignoresSafeArea()
            .accessibilityHidden(true)
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
        if model.library.folder == nil {
            // Still finding the folder: the one it will be.
            return hasICloud && !UserDefaults.standard.bool(forKey: AppModel.onDeviceKey) ? .iCloud : .off
        }
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

/// The app on show, as on the App Store: the Najdorf as Browse draws it for Black (White's most
/// played reply, solid; one not prepared yet, dashed), tilted, with cards from the app floating
/// around it: that reply as a gap, a correct answer in Study, today's moves. Fixed example
/// numbers, so it looks the same offline on the first launch. A fixed layout, scaled to fit.
private struct ProductShot: View {
    @Environment(\.colorScheme) private var colorScheme
    /// Drawn at its own size and scaled, in a frame of the scaled size (`fit`).
    var scale: CGFloat = 1

    static let size = CGSize(width: 380, height: 350)

    /// The scale that fits `width` × `height`: at most `largest`, and never below 55%.
    static func fit(width: CGFloat, height: CGFloat, largest: CGFloat = 1) -> CGFloat {
        max(0.55, min(largest, width / size.width, height / size.height))
    }

    var body: some View {
        ZStack {
            BoardView(position: Self.najdorf, orientation: .black,
                      lastMove: PlayedMove(san: "a6", uci: "a7a6"),
                      arrows: [
                          BoardArrow(from: BoardSquare("c1")!, to: BoardSquare("g5")!, style: .opponent, width: 0.2),
                          BoardArrow(from: BoardSquare("f1")!, to: BoardSquare("c4")!, style: .gap, width: 0.16, dashed: true),
                      ])
                .frame(width: 250, height: 250)
                .clipShape(.rect(cornerRadius: 16))
                .shadow(color: .black.opacity(0.35), radius: 24, y: 14)
                .rotationEffect(.degrees(-5))
                .allowsHitTesting(false)

            HStack(spacing: 8) {
                Text("Bc4").font(.headline)
                Text("1 in 67").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                Text("Gap")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(.todo, in: .capsule)
            }
            .floatingCard(colorScheme)
            .offset(x: -88, y: 130)

            Label("Correct", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.correct)
                .floatingCard(colorScheme)
                .offset(x: 118, y: -112)

            VStack(alignment: .leading, spacing: 0) {
                Text("35").font(.title2.bold().monospacedDigit())
                Text("due today").font(.caption).foregroundStyle(.secondary)
            }
            .floatingCard(colorScheme)
            .offset(x: 136, y: 60)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .scaleEffect(scale)
        .frame(width: Self.size.width * scale, height: Self.size.height * scale)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Example: a Najdorf position with a reply you haven't prepared, Bc4, met 1 in 67 games; a correct answer; 35 moves due today.")
    }

    private static let najdorf = positionFromFen(fen: "rnbqkb1r/1p2pppp/p2p1n2/8/3NP3/2N5/PPP2PPP/R1BQKB1R w KQkq - 0 6")!
}

private extension View {
    /// A card from the app, raised over the shot: lighter than the page in either appearance
    /// (white in light, the next gray up in dark). Content, so solid, not glass.
    func floatingCard(_ scheme: ColorScheme) -> some View {
        padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(scheme == .dark ? AnyShapeStyle(.background.tertiary) : AnyShapeStyle(.background),
                        in: .rect(cornerRadius: 14))
            .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.18), radius: 16, y: 8)
    }
}
