import OpeningCoreRust
#if os(iOS)
import SafariServices
#endif
import SwiftUI

/// The core's learning progress, not Foundation's `Progress`.
typealias Progress = OpeningCoreRust.Progress

/// The split view's board column: what belongs above the board, the board as large as the
/// column allows (edge to edge across its width, or its height in a wide window, then on the
/// leading side), then what belongs under it. What is above and below the board keeps the
/// scene's margins, as the title does.
struct BoardColumnLayout<Above: View, Board: View, Below: View>: View {
    @ViewBuilder var above: Above
    @ViewBuilder var board: Board
    @ViewBuilder var below: Below

    var body: some View {
        VStack(alignment: .leading) {
            above
                .scenePadding(.horizontal)
            board
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            below
                .scenePadding(.horizontal)
        }
    }
}

extension BoardColumnLayout where Above == EmptyView {
    init(@ViewBuilder board: () -> Board, @ViewBuilder below: () -> Below) {
        self.init(above: { EmptyView() }, board: board, below: below)
    }
}

extension View {
    /// The title of Browse and Study. In the split view the panel names the repertoire (the
    /// board column names the screen). On a phone the screen is named, with the repertoire as
    /// its subtitle, inline as on any pushed screen whose content fills it.
    @ViewBuilder
    func boardScreenTitle(_ screen: String, repertoire: String, inSplitView: Bool) -> some View {
        if inSplitView {
            navigationTitle(repertoire)
        } else {
            navigationTitle(screen)
                .navigationSubtitle(repertoire)
                .toolbarTitleDisplayMode(.inline)
        }
    }
}

extension View {
    /// A screen's action buttons, as the HIG asks: all the same size, the most likely one in
    /// the prominent style and the others bordered ("use style, not size").
    @ViewBuilder
    func actionButton(prominent: Bool) -> some View {
        Group {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
        .controlSize(.large)
        .buttonSizing(.flexible)
    }
}

/// White / draw / black result bar. Each part shows its share when the number fits in it, as
/// in the Lichess explorer.
struct ScoreBar: View {
    let white: Int64
    let draws: Int64
    let black: Int64

    var body: some View {
        let total = max(white + draws + black, 1)
        GeometryReader { geo in
            HStack(spacing: 0) {
                part(white, of: total, fill: Color(white: 0.96), text: .black)
                    .frame(width: geo.size.width * CGFloat(white) / CGFloat(total))
                part(draws, of: total, fill: Color(white: 0.6), text: .white)
                    .frame(width: geo.size.width * CGFloat(draws) / CGFloat(total))
                part(black, of: total, fill: Color(white: 0.15), text: .white)
            }
            .clipShape(.rect(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(.quaternary, lineWidth: 0.5))
        }
        .frame(height: 18)
        .accessibilityLabel("White \(white * 100 / total)%, draws \(draws * 100 / total)%, black \(black * 100 / total)%")
    }

    private func part(_ games: Int64, of total: Int64, fill: Color, text: Color) -> some View {
        fill.overlay {
            ViewThatFits(in: .horizontal) {
                Text(Format.percent(Double(games) / Double(total)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(text)
                    .padding(.horizontal, 2)
                Color.clear
            }
        }
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
    static func moveList(_ moves: [PlayedMove], startPly: UInt32 = 0) -> String {
        OpeningCoreRust.moveList(moves: moves, startPly: startPly)
    }

    static func games(_ n: Int64) -> String { games(Int(n)) }

    static func games(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.1fB", Double(n) / 1_000_000_000) }
        if n >= 100_000_000 { return "\(n / 1_000_000)M" }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 10_000 { return "\(n / 1000)k" }
        return n.formatted()
    }
}

/// A web page to show, e.g. the Lichess analysis board.
struct WebPage: Identifiable, Equatable {
    let url: URL
    var id: URL { url }
}

extension View {
    /// Shows `page` in a Safari sheet on iPhone and iPad, and in the default browser on macOS.
    func webPage(_ page: Binding<WebPage?>) -> some View {
        modifier(WebPagePresenter(page: page))
    }
}

private struct WebPagePresenter: ViewModifier {
    @Binding var page: WebPage?
    #if os(macOS)
    @Environment(\.openURL) private var openURL
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        content.sheet(item: $page) { page in
            SafariView(url: page.url).ignoresSafeArea()
        }
        #else
        content.onChange(of: page) {
            guard let page else { return }
            openURL(page.url)
            self.page = nil
        }
        #endif
    }
}

#if os(iOS)
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
#endif

enum LichessLinks {
    /// Opens the line in the Lichess analysis board, keeping the move history.
    static func analysis(moves: [PlayedMove], orientation: Side) -> URL {
        URL(string: lichessAnalysisUrl(moves: moves, orientation: orientation))!
    }
}

extension View {
    /// A small status label: tinted text on a light tint of the same color, or secondary text
    /// on a neutral fill. Not glass: it's content, not a control.
    func statusBadge(tint: ThemeColor? = nil) -> some View {
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

/// Coverage as a bar: the covered part in the app color on a neutral track, so the track is what is left
/// (a gap, or lines not checked yet, is an empty bar).
struct CoverageBar: View {
    let value: Double
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let filled = min(max(value, 0), 1)
            Capsule().fill(.quaternary)
                .overlay(alignment: .leading) {
                    Capsule().fill(.built)
                        .frame(width: geo.size.width * filled)
                }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Coverage")
        .accessibilityValue(Format.percent(value))
    }
}

/// Studied moves by Anki's groups (mature, young, learning) over all your moves, tinted like an
/// accented widget: the app color, lighter for young, then the learning gray; moves not
/// studied yet are the empty track.
struct StudiedBar: View {
    let progress: Progress
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let total = CGFloat(max(progress.cards, 1))
            HStack(spacing: 0) {
                Rectangle().fill(.learned).frame(width: geo.size.width * CGFloat(progress.mature) / total)
                Rectangle().fill(ThemeColor.learned.lighter()).frame(width: geo.size.width * CGFloat(progress.young) / total)
                Rectangle().fill(.learning).frame(width: geo.size.width * CGFloat(progress.learning) / total)
                Spacer(minLength: 0)
            }
            .background(.quaternary)
            .clipShape(.capsule)
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Studied")
        .accessibilityValue("\(progress.mature) mature, \(progress.young) young, \(progress.learning) learning, \(progress.notStudied) not studied")
    }
}

/// New / Learning / To Review, as on Anki's deck list. Nothing when the repertoire has no
/// moves of yours yet, only the new count before anything was studied, zeros faint. Colored
/// like the studied bar: new the label color, learning gray, review the app color.
struct DueCounts: View {
    let counts: Counts
    let progress: Progress
    var font: Font = .subheadline

    var body: some View {
        if progress.cards == 0 {
            EmptyView()
        } else if progress.studied == 0 {
            Text("\(counts.new) new").foregroundStyle(counts.new > 0 ? AnyShapeStyle(.new) : AnyShapeStyle(.tertiary))
                .font(font.weight(.semibold).monospacedDigit())
        } else {
            HStack(spacing: 8) {
                number(counts.new, .new)
                number(counts.learning, .learning)
                number(counts.review, .learned)
            }
            .font(font.weight(.semibold).monospacedDigit())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(counts.new) new, \(counts.learning) learning, \(counts.review) to review")
        }
    }

    private func number(_ value: Int64, _ color: ThemeColor) -> some View {
        Text(value.formatted()).foregroundStyle(value > 0 ? AnyShapeStyle(color) : AnyShapeStyle(.tertiary))
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
