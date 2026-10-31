import SwiftUI

/// The app's pages on the web and its version.
enum AppLinks {
    static let website = URL(string: "https://orbtchess.org")!
    static let privacy = URL(string: "https://orbtchess.org/privacy")!
    static let support = URL(string: "https://orbtchess.org/support")!
    static let source = URL(string: "https://github.com/carlvonburg/orbt-chess")!
    /// The App Store's page for writing a review (every platform: one app).
    static let review = URL(string: "https://apps.apple.com/app/id6828347828?action=write-review")!

    static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

/// What the app ships besides the Rust crates (those are in Acknowledgements.json).
struct Component {
    let name: String
    /// The license's text: a key of Acknowledgements.json's `licenses`.
    let text: String
    /// Shown above the license text, where the license asks for attribution.
    var attribution: String?

    static let all: [Component] = [
        Component(name: "Stockfish", text: "GPL-3.0"),
        Component(name: "multistockfish", text: "GPL-3.0"),
        Component(name: "Anki", text: "AGPL-3.0"),
        // GPL-2.0-or-later, so GPL-3.0's text applies.
        Component(name: "cburnett pieces", text: "GPL-3.0"),
        // CC BY-NC 4.0 §3(a): the creator, a link to the work, and that it was changed.
        Component(name: "Lumbra's Gigabase", text: "CC-BY-NC-4.0",
                  attribution: "Lumbra's Gigabase by Lumbra (lumbrasgigabase.com), licensed under CC BY-NC 4.0. ORBT Chess reduces its over-the-board games since 2000 to the move counts of the Classical coverage tables."),
    ]
}

/// Acknowledgements.json, written by core/scripts/acknowledgements.py: the license texts the app
/// bundles and every crate linked into it.
struct Acknowledgements: Decodable {
    struct Crate: Decodable, Identifiable {
        let name: String
        let version: String
        let license: String
        let repository: String
        let text: String?
        let shared: String?

        var id: String { "\(name) \(version)" }
    }

    let licenses: [String: String]
    let crates: [Crate]

    static let bundled: Acknowledgements = {
        guard let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(Acknowledgements.self, from: data)
        else { return Acknowledgements(licenses: [:], crates: []) }
        return value
    }()

    func text(of crate: Crate) -> String {
        crate.text ?? crate.shared.flatMap { licenses[$0] } ?? ""
    }
}

/// Settings › About: one row, as in the Lichess app.
struct AboutSection: View {
    var body: some View {
        Section {
            NavigationLink("About ORBT Chess") { AboutView() }
        }
    }
}

/// The app's pages, its source and licenses (the Lichess app's About screen).
struct AboutView: View {
    var body: some View {
        Form {
            Section {
                Link("Website", destination: AppLinks.website)
                Link("Support", destination: AppLinks.support)
                Link("Privacy Policy", destination: AppLinks.privacy)
            }
            Section {
                Link("Source Code", destination: AppLinks.source)
                NavigationLink("Licenses") { LicensesView() }
            } footer: {
                Text("Version \(AppLinks.version). ORBT Chess is free software: you can share and change it under the GNU AGPL 3.0 or later.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("About")
    }
}

/// Every license the app ships under, one row each (Flutter's license page, which the Lichess
/// app shows): ORBT Chess first, then the components and crates by name.
private struct LicensesView: View {
    private struct Entry: Identifiable {
        let id: String
        let name: String
        let text: String
        var attribution: String?
    }

    private let app: Entry
    private let entries: [Entry]

    init() {
        let acknowledgements = Acknowledgements.bundled
        app = Entry(id: "ORBT Chess", name: "ORBT Chess", text: acknowledgements.licenses["AGPL-3.0"] ?? "")
        let components = Component.all.map {
            Entry(id: $0.name, name: $0.name, text: acknowledgements.licenses[$0.text] ?? "", attribution: $0.attribution)
        }
        let crates = acknowledgements.crates.map {
            Entry(id: $0.id, name: $0.name, text: acknowledgements.text(of: $0))
        }
        entries = (components + crates).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section { row(app) }
            Section { ForEach(entries) { row($0) } }
        }
        .formStyle(.grouped)
        .navigationTitle("Licenses")
    }

    private func row(_ entry: Entry) -> some View {
        NavigationLink(entry.name) {
            LicenseTextView(title: entry.name, attribution: entry.attribution, text: entry.text)
        }
    }
}

private struct LicenseTextView: View {
    let title: String
    let attribution: String?
    let text: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let attribution { Text(attribution) }
                Text(reflowed).font(.footnote)
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle(title)
    }

    /// License files wrap at 80 columns; on a phone a paragraph's lines read better joined, so
    /// only blank lines and list items ("1.", "a.", "(i)", "-") start a new line.
    private var reflowed: String {
        var result = ""
        var previousEmpty = true
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingPrefix(while: \.isWhitespace)
            let item = trimmed.prefixMatch(of: /([0-9]+\.|[a-z]\.|\([a-z0-9]+\)|[-*•])\s/) != nil
            if !result.isEmpty {
                result += previousEmpty || trimmed.isEmpty || item ? "\n" : " "
            }
            result += trimmed
            previousEmpty = trimmed.isEmpty
        }
        return result
    }
}
