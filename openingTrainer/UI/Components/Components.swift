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
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 10_000 { return "\(n / 1000)k" }
        return n.formatted()
    }
}

struct SideIcon: View {
    let side: Side

    var body: some View {
        Image(side == .white ? "wK" : "bK")
            .resizable()
            .frame(width: 28, height: 28)
            .padding(4)
            .background(Circle().fill(side == .white ? Color(white: 0.3) : Color(white: 0.85)))
            .accessibilityLabel(side == .white ? "White repertoire" : "Black repertoire")
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
    /// Small rounded "chip" with Liquid Glass.
    func glassChip(tint: Color? = nil) -> some View {
        padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(tint.map { .regular.tint($0) } ?? .regular, in: .capsule)
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
