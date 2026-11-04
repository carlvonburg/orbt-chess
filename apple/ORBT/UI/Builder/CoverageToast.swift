import OpeningCoreRust
import SwiftUI

/// What a save did to the repertoire's coverage.
struct CoverageChange: Equatable {
    struct Snapshot: Equatable {
        var completion: Double
        var gaps: Int

        init(_ root: NodeCoverage?) {
            completion = root?.completion ?? 0
            gaps = Int(root?.gapCount ?? 0)
        }
    }

    let before: Snapshot
    let after: Snapshot
    /// The saved line still has a gap below it (stopped before a reply that needs an answer).
    let lineOpen: Bool

    /// Nil when there is nothing to tell: coverage unchanged and the line has no gap (beyond
    /// the target, where nothing is required).
    init?(before: Snapshot, after: Snapshot, lineOpen: Bool) {
        self.before = before
        self.after = after
        self.lineOpen = lineOpen
        if !raised && !lineOpen { return nil }
    }

    /// Coverage went up: a gap filled, or a required reply answered further.
    var raised: Bool { after.gaps < before.gaps || after.completion > before.completion + 0.0005 }

    var title: String {
        let filled = before.gaps - after.gaps
        return switch filled {
        case _ where !raised: "Line Saved"
        case ..<1: "Coverage Up"
        case 1: "Gap Filled"
        default: "\(filled) Gaps Filled"
        }
    }

    var detail: String {
        // Saved, but a reply it reaches still needs an answer: the gap moved down the line.
        guard raised else { return "Not covered yet: a common reply in it still needs your answer." }
        let left = switch after.gaps {
        case 0: "no gaps left"
        case 1: "1 gap left"
        default: "\(after.gaps.formatted()) gaps left"
        }
        return "\(Format.percent(before.completion)) → \(Format.percent(after.completion)) complete, \(left)"
    }

    var symbol: String {
        if !raised { return "arrow.turn.down.right" }
        return after.gaps == 0 ? "checkmark.seal.fill" : "checkmark.circle.fill"
    }
}

/// The last save's effect on coverage, for a few seconds above the bottom bar: shows that
/// filling a gap raises coverage, and that a line stopped above the target leaves one. Tap to
/// dismiss.
struct CoverageToast: View {
    @Binding var change: CoverageChange?

    var body: some View {
        if let change {
            HStack(spacing: 10) {
                Image(systemName: change.symbol)
                    .font(.title3)
                    .foregroundStyle(change.raised ? ThemeColor.built : ThemeColor.todo)
                VStack(alignment: .leading, spacing: 1) {
                    Text(change.title).font(.subheadline.weight(.semibold))
                    Text(change.detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
            .padding(.bottom, 8)
            .onTapGesture { withAnimation { self.change = nil } }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isStaticText)
            .task(id: change.after) {
                AccessibilityNotification.Announcement("\(change.title). \(change.detail)").post()
                try? await Task.sleep(for: .seconds(4))
                withAnimation { self.change = nil }
            }
        }
    }
}
