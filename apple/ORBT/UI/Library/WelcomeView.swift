import SwiftUI

/// The repertoire list before there is any repertoire: how the app is used (enter lines, fill
/// gaps, train) as a grouped list, with the actions at the bottom (iOS 26 layout).
struct WelcomeView: View {
    let usesICloud: Bool
    let newRepertoire: () -> Void
    let importPGN: () -> Void

    var body: some View {
        List {
            Section {
                step("Enter the lines", "Your moves and the replies the book or video covers.",
                     icon: "text.book.closed.fill", color: .built)
                step("Fill the gaps", "See which common replies you haven't answered yet.",
                     icon: "puzzlepiece.fill", color: .todo)
                step("Train daily", "Spaced repetition, a few minutes a day.",
                     icon: "graduationcap.fill", color: .learned)
            } header: {
                Text("How it works")
            } footer: {
                Text(usesICloud ? "Repertoires are PGN files in iCloud Drive › ORBT."
                                : "Repertoires are PGN files on this device.")
            }
        }
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: 12) {
                Button("New Repertoire", action: newRepertoire)
                    .buttonStyle(.glassProminent)
                Button("Import PGN…", action: importPGN)
                    .buttonStyle(.glass)
            }
            .controlSize(.extraLarge)
            .buttonSizing(.flexible)
            .padding()
        }
    }

    /// A row with a Settings-style icon.
    private func step(_ title: String, _ detail: String, icon: String, color: ThemeColor) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(color, in: .rect(cornerRadius: 8))
        }
        .padding(.vertical, 4)
    }
}
