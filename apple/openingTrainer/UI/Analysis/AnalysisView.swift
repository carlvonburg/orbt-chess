import OpeningCoreRust
import SwiftUI

extension View {
    /// Presents the analysis board over Browse or Study: full screen on iPhone and iPad, a
    /// sheet on the Mac. However it closes, the line goes back as `AnalysisModel.finish` says.
    func analysisBoard(_ model: Binding<AnalysisModel?>) -> some View {
        #if os(iOS)
        fullScreenCover(item: model) { AnalysisScreen(model: $0) }
        #else
        sheet(item: model) { AnalysisScreen(model: $0).frame(minWidth: 900, minHeight: 680) }
        #endif
    }
}

/// The analysis board: engine lines above the board (Lichess's cloud eval, then Stockfish),
/// the moves with their variations and evaluations, and the explorer's moves.
struct AnalysisScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    let model: AnalysisModel
    @State private var page: WebPage?
    /// The evaluation last written to the move list, so it is written once per depth.
    @State private var recorded: (key: EngineService.Key, depth: UInt32)?

    private var engine: EngineService { app.engine }

    var body: some View {
        NavigationStack {
            Group {
                if isRegularWidth(sizeClass) {
                    HStack(spacing: 0) {
                        boardColumn
                            .scenePadding()
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        Divider()
                        panel.frame(width: 380)
                    }
                } else {
                    VStack(spacing: 0) {
                        // Edge to edge on a phone; the moves scroll below.
                        boardColumn.layoutPriority(1)
                        panel
                    }
                }
            }
            .navigationTitle("Analysis")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbar }
        }
        .webPage($page)
        .task(id: EngineTask(key: model.engineKey, on: model.engineOn)) {
            if model.engineOn {
                engine.analyse(model.engineKey, epd: model.position.epd())
            } else {
                engine.stop()
            }
        }
        .onChange(of: engine.lines) { record() }
        .onDisappear {
            engine.stop()
            model.finish()
        }
    }

    private struct EngineTask: Hashable {
        let key: EngineService.Key
        let on: Bool
    }

    /// The engine's lines for the position on the board, if they are for it.
    private var shownLines: [PvLine] {
        guard model.engineOn, engine.analysed == model.engineKey else { return [] }
        return engine.lines.lines
    }

    private func record() {
        let key = model.engineKey
        guard engine.analysed == key, let best = engine.lines.lines.first else { return }
        let depth = engine.lines.depth
        if let recorded, recorded.key == key, recorded.depth == depth { return }
        recorded = (key, depth)
        model.setEval(NodeEval(text: best.eval, depth: depth))
    }

    private var boardColumn: some View {
        VStack(spacing: 0) {
            if model.engineOn {
                EngineLinesView(engine: engine, lines: shownLines) { model.play(uci: $0) }
            }
            BoardView(position: model.position, orientation: model.orientation, lastMove: model.lastMove,
                      arrows: arrows, movableSide: model.position.sideToMove()) { from, to, promotion in
                model.play(from: from, to: to, promotion: promotion)
            }
            .aspectRatio(1, contentMode: .fit)
        }
    }

    /// The first move of each engine line, the best one boldest.
    private var arrows: [BoardArrow] {
        shownLines.enumerated().compactMap { index, line in
            guard let move = line.moves.first else { return nil }
            let rank = Double(index)
            return BoardArrow(from: move.from, to: move.to, style: .engine,
                              width: max(0.1, 0.2 - rank * 0.04), opacity: max(0.35, 0.85 - rank * 0.2))
        }
    }

    private var panel: some View {
        List {
            Section("Moves") {
                AnalysisMoveList(model: model)
            }
            AnalysisExplorerSection(model: model)
        }
        #if os(iOS)
        .listStyle(.plain)
        #endif
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Done", systemImage: "checkmark") { dismiss() }
        }
        ToolbarItemGroup(placement: .bottomActions) {
            Button("Back", systemImage: "chevron.backward") { model.back() }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(!model.canBack)
            Button("Forward", systemImage: "chevron.forward") { model.forward() }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(!model.canForward)
        }
        ToolbarSpacer(.flexible, placement: .bottomActions)
        ToolbarItemGroup(placement: .bottomActions) {
            Toggle(isOn: Binding(get: { model.engineOn }, set: { model.engineOn = $0 })) {
                Label("Engine", systemImage: "cpu")
            }
            Menu("More", systemImage: "ellipsis") {
                Button("Flip Board", systemImage: "arrow.up.arrow.down") { model.orientation = model.orientation.opposite }
                Button("Copy PGN", systemImage: "doc.on.doc") { copy(model.pgn) }
                Button("Open in Lichess", systemImage: "safari") {
                    page = WebPage(url: LichessLinks.analysis(moves: model.movesToBoard, orientation: model.orientation))
                }
            }
        }
    }
}

/// Puts text on the clipboard.
func copy(_ text: String) {
    #if os(iOS)
    UIPasteboard.general.string = text
    #else
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #endif
}

/// The engine's lines above the board: the evaluation and the moves, tap to play the first.
/// The status says where they come from: a Lichess cloud eval, or Stockfish at some depth.
struct EngineLinesView: View {
    let engine: EngineService
    let lines: [PvLine]
    let play: (String) -> Void

    var body: some View {
        let shown = engine.lines
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Button {
                    if let first = line.moves.first { play(first.uci) }
                } label: {
                    HStack(spacing: 8) {
                        EvalChip(text: line.eval, score: line.score)
                        Text(line.text)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 6) {
                if let source = shown.source, !lines.isEmpty {
                    Text(source == .cloud ? "Cloud" : (engine.name ?? "Stockfish"))
                    Text("depth \(shown.depth)")
                    if source == .local, let knps = shown.knps {
                        Text("\(knps.formatted()) kn/s")
                    }
                } else if let error = engine.error {
                    Text(error)
                } else {
                    Text(shown.searching ? "Thinking…" : "Waiting for an evaluation…")
                }
                if shown.searching { ProgressView().controlSize(.mini) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        // The lines keep their space while a new position is analysed, so the board stays put.
        .frame(minHeight: CGFloat(EngineDefaults.lines) * 24 + 22, alignment: .top)
        .animation(nil, value: lines)
    }
}

/// An evaluation, light when White is better and dark when Black is, as Lichess shows it.
struct EvalChip: View {
    let text: String
    let score: Score

    private var whiteBetter: Bool {
        switch score {
        case .cp(let cp): cp >= 0
        case .mate(let n): n > 0
        }
    }

    var body: some View {
        Text(text)
            .font(.callout.monospacedDigit().weight(.semibold))
            .foregroundStyle(whiteBetter ? Color.black : Color.white)
            .frame(minWidth: 46)
            .padding(.vertical, 2)
            .background(whiteBetter ? Color(white: 0.92) : Color(white: 0.18), in: .rect(cornerRadius: 5))
    }
}

/// The moves of the analysis: the main line, cut where variations branch off, and each
/// variation indented. A move's menu promotes it, makes it the main line, copies its line or
/// deletes it.
struct AnalysisMoveList: View {
    let model: AnalysisModel

    var body: some View {
        let lines = model.lines
        if lines.isEmpty {
            Text("Play a move on the board.")
                .foregroundStyle(.secondary)
        }
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
            FlowLayout(spacing: 2, lineSpacing: 2) {
                ForEach(line.moves, id: \.id) { move in
                    AnalysisMoveChip(move: move)
                        .onTapGesture { model.go(to: move.id) }
                        .contextMenu { menu(move) }
                }
            }
            .padding(.leading, CGFloat(min(line.depth, 6)) * 14)
            .listRowBackground(line.depth > 0 ? Color.secondary.opacity(0.06) : nil)
        }
    }

    @ViewBuilder
    private func menu(_ move: AnalysisMove) -> some View {
        if !model.isMainLine(move.id) {
            Button("Promote Variation", systemImage: "chevron.up") { model.promote(move.id) }
            Button("Make Main Line", systemImage: "checkmark") { model.makeMainLine(move.id) }
        }
        Button("Copy Variation PGN", systemImage: "doc.on.doc") { copy(model.linePGN(move.id)) }
        Button("Delete from Here", systemImage: "trash", role: .destructive) { model.delete(from: move.id) }
    }
}

/// One move of the analysis: number, move and the evaluation after it.
struct AnalysisMoveChip: View {
    let move: AnalysisMove

    var body: some View {
        HStack(spacing: 3) {
            if let number = move.number {
                Text(number).foregroundStyle(.secondary)
            }
            Text(move.san).fontWeight(move.isCurrent ? .bold : .regular)
            if let eval = move.eval {
                Text(eval).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .font(.callout.monospacedDigit())
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background {
            if move.isCurrent {
                RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.25))
            }
        }
        .contentShape(.rect)
    }
}

/// The explorer's moves in the position, from the repertoire's database: tap to play one.
struct AnalysisExplorerSection: View {
    @Environment(AppModel.self) private var app
    let model: AnalysisModel

    var body: some View {
        let epd = model.position.epd()
        let stats = model.document.stats(epd)
        Section {
            if let stats {
                if stats.moves.isEmpty {
                    Text("No games in this position.").foregroundStyle(.secondary)
                }
                let total = max(stats.white + stats.draws + stats.black, 1)
                ForEach(stats.moves.prefix(12), id: \.uci) { move in
                    let games = move.white + move.draws + move.black
                    Button { model.play(uci: move.uci) } label: {
                        HStack(spacing: 10) {
                            Text(move.san).frame(width: 56, alignment: .leading)
                            Text(Format.games(games)).monospacedDigit()
                                .frame(width: 56, alignment: .trailing)
                            Text(Format.percent(Double(games) / Double(total))).monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                            ScoreBar(white: move.white, draws: move.draws, black: move.black)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            } else if app.isLoadingStats {
                ProgressView()
            } else {
                StatsUnavailableNote()
            }
        } header: {
            Text(stats?.opening.map { "\($0.eco) \($0.name)" } ?? "Explorer")
        }
        .task(id: epd) { model.document.requestStats(for: epd) }
    }
}
