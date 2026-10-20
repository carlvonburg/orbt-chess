import OpeningCore
import SafariServices
import SwiftUI

/// Thin horizontal progress bar.
struct CompletionBar: View {
    let value: Double
    var tint: Color = .green
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint)
                    .frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue(Text(value, format: .percent.precision(.fractionLength(0))))
    }
}

/// White / draw / black result bar.
struct ScoreBar: View {
    let white: Int
    let draws: Int
    let black: Int

    var body: some View {
        let total = max(white + draws + black, 1)
        GeometryReader { geo in
            HStack(spacing: 0) {
                Rectangle().fill(Color(white: 0.96))
                    .frame(width: geo.size.width * CGFloat(white) / CGFloat(total))
                Rectangle().fill(Color(white: 0.6))
                    .frame(width: geo.size.width * CGFloat(draws) / CGFloat(total))
                Rectangle().fill(Color(white: 0.15))
            }
            .clipShape(.rect(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(.quaternary, lineWidth: 0.5))
        }
        .frame(height: 8)
        .accessibilityLabel("White \(white * 100 / total)%, draws \(draws * 100 / total)%, black \(black * 100 / total)%")
    }
}

enum Format {
    static func seenEvery(_ reach: Double?) -> String {
        guard let reach, reach > 0 else { return "—" }
        let n = 1 / reach
        if n < 1.5 { return "every game" }
        return "1 in \(Int(n.rounded()).formatted())"
    }

    static func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }

    /// "1. d4 d5 2. c4 c6", numbered from `startPly` (0 = White's first move).
    static func moveList(_ moves: [PlayedMove], startPly: Int = 0) -> String {
        var parts: [String] = []
        for (i, move) in moves.enumerated() {
            let ply = startPly + i
            if ply % 2 == 0 {
                parts.append("\(ply / 2 + 1). \(move.san)")
            } else {
                parts.append(i == 0 ? "\(ply / 2 + 1)… \(move.san)" : move.san)
            }
        }
        return parts.joined(separator: " ")
    }

    static func games(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.1fB", Double(n) / 1_000_000_000) }
        if n >= 100_000_000 { return "\(n / 1_000_000)M" }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 10_000 { return "\(n / 1000)k" }
        return n.formatted()
    }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

enum LichessLinks {
    /// Opens the line in the Lichess analysis board, keeping the move history.
    static func analysis(moves: [PlayedMove], orientation: Side) -> URL {
        let sans = moves.map { SAN.loose($0.san) }
        let path = sans.isEmpty ? "" : sans.joined(separator: "_")
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "#?")
        let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        let base = sans.isEmpty ? "https://lichess.org/analysis" : "https://lichess.org/analysis/pgn/\(encoded)"
        return URL(string: base + (orientation == .black ? "?color=black" : ""))!
    }
}

extension View {
    /// A small status label: tinted text on a light tint of the same color, or secondary text
    /// on a neutral fill. Not glass: it's content, not a control.
    func statusBadge(tint: Color? = nil) -> some View {
        padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
            .background(tint.map { AnyShapeStyle($0.opacity(0.18)) } ?? AnyShapeStyle(.fill.tertiary), in: .capsule)
    }
}

/// Shows `content` once the entry's document is open, opening it in the background.
struct OpenDocument<Content: View, Placeholder: View>: View {
    @Environment(AppModel.self) private var model
    let entry: RepertoireEntry
    @ViewBuilder let content: (RepertoireDocument) -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    var body: some View {
        if let doc = model.documents[entry.id] {
            content(doc)
        } else if let error = model.openErrors[entry.id] {
            ContentUnavailableView("Repertoire unavailable", systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else {
            placeholder()
                .task(id: entry.id) { _ = await model.open(entry) }
        }
    }
}

/// Colors of Anki's due counts, and of its card-count groups (used by the overview, the list
/// and the Statistics tab alike).
enum StudyColors {
    static let new = Color.blue
    static let learning = Color.red
    static let review = Color.green

    static let newGroup = Color.blue
    static let learningGroup = Color.orange
    static let relearningGroup = Color.red
    static let young = Color(red: 0.6, green: 0.8, blue: 0.4)
    static let mature = Color(red: 0.2, green: 0.5, blue: 0.1)
    static let suspended = Color.yellow
    /// Reviews ahead (Anki's filtered decks).
    static let filtered = Color.purple
}

/// Studied moves by Anki's groups (learning, young, mature) over all your moves; moves not
/// studied yet are the empty track.
struct StudiedBar: View {
    let progress: Trainer.Progress
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let total = CGFloat(max(progress.cards, 1))
            HStack(spacing: 0) {
                Rectangle().fill(StudyColors.learningGroup).frame(width: geo.size.width * CGFloat(progress.learning) / total)
                Rectangle().fill(StudyColors.young).frame(width: geo.size.width * CGFloat(progress.young) / total)
                Rectangle().fill(StudyColors.mature).frame(width: geo.size.width * CGFloat(progress.mature) / total)
                Spacer(minLength: 0)
            }
            .background(.quaternary)
            .clipShape(.capsule)
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Studied")
        .accessibilityValue("\(progress.learning) learning, \(progress.young) young, \(progress.mature) mature, \(progress.notStudied) not studied")
    }
}

/// New / Learning / To Review, as on Anki's deck list. Nothing when the repertoire has no
/// moves of yours yet, only the new count before anything was studied, zeros greyed.
struct DueCounts: View {
    let counts: CardQueues.Counts
    let progress: Trainer.Progress
    var font: Font = .subheadline

    var body: some View {
        if progress.cards == 0 {
            EmptyView()
        } else if progress.studied == 0 {
            Text("\(counts.new) new").foregroundStyle(counts.new > 0 ? StudyColors.new : .secondary)
                .font(font.weight(.semibold).monospacedDigit())
        } else {
            HStack(spacing: 8) {
                number(counts.new, StudyColors.new)
                number(counts.learning, StudyColors.learning)
                number(counts.review, StudyColors.review)
            }
            .font(font.weight(.semibold).monospacedDigit())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(counts.new) new, \(counts.learning) learning, \(counts.review) to review")
        }
    }

    private func number(_ value: Int, _ color: Color) -> some View {
        Text(value.formatted()).foregroundStyle(value > 0 ? color : Color.secondary.opacity(0.6))
    }
}

/// Lays its subviews out in rows, starting a new row when the next one doesn't fit, so short
/// labels (a legend) wrap instead of being truncated on narrow screens or large text.
struct FlowLayout: Layout {
    var spacing: CGFloat = 12
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
