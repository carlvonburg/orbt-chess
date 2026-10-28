import OpeningCoreRust
import SwiftUI

extension EnvironmentValues {
    /// Pushes the analysis board on the screen it is opened from (set by the library). Going
    /// back finishes it (`AnalysisModel.finish`).
    @Entry var openAnalysis: ((AnalysisModel) -> Void)?
}

extension View {
    /// Pushes the analysis board where the library doesn't (`openAnalysis` unset): Browse or
    /// Study opened from Statistics. Going back finishes it.
    func analysisDestination(_ model: Binding<AnalysisModel?>) -> some View {
        navigationDestination(item: model) { AnalysisView(model: $0) }
            .onChange(of: model.wrappedValue) { old, new in
                if new == nil { old?.finish() }
            }
    }
}

/// The analysis board, pushed on Browse or Study and laid out as they are: the engine's lines
/// above the board (Lichess's cloud eval, then Stockfish), and in the panel the moves with their
/// variations and evaluations, then the explorer's moves. In the split view this is the panel;
/// the board is in the board column (`AnalysisBoard`).
struct AnalysisView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.inSplitView) private var inSplitView
    let model: AnalysisModel
    /// On a phone the panel shows the moves or the explorer, not both.
    @State private var tab = PanelTab.explorer
    /// The evaluation last written to the move list, so it is written once per depth.
    @State private var recorded: (key: EngineService.Key, depth: UInt32)?

    private var engine: EngineService { app.engine }

    var body: some View {
        @Bindable var model = model
        Group {
            if inSplitView {
                panel(compact: false)
            } else if isRegularWidth(sizeClass) {
                // Outside the library on an iPad (Browse from Statistics): board and panel.
                HStack(spacing: 0) {
                    AnalysisBoard(model: model)
                        .scenePadding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    Divider()
                    panel(compact: false).frame(width: 380)
                }
            } else {
                VStack(spacing: 0) {
                    // Edge to edge on a phone; the moves scroll below.
                    AnalysisBoard(model: model).layoutPriority(1)
                    panel(compact: true)
                }
            }
        }
        .modifier(AnalysisTitle(model: model, inSplitView: inSplitView))
        .toolbar { toolbar }
        .hidesTabBar()
        .webPage($model.page)
        .sheet(isPresented: $model.showsSettings, onDismiss: reanalyse) { EngineSettingsSheet() }
        .task(id: EngineTask(key: model.engineKey, on: model.engineOn)) {
            if model.engineOn {
                engine.analyse(model.engineKey, epd: model.position.epd())
            } else {
                engine.stop()
            }
        }
        .onChange(of: engine.lines) { record() }
        // Covered (or popped): the engine stops, and runs again when the screen is back.
        .onDisappear { engine.stop() }
    }

    /// Analyses the position again with the settings just changed.
    private func reanalyse() {
        guard model.engineOn else { return }
        engine.stop()
        engine.analyse(model.engineKey, epd: model.position.epd())
    }

    private struct EngineTask: Hashable {
        let key: EngineService.Key
        let on: Bool
    }

    private func record() {
        let key = model.engineKey
        guard engine.analysed == key, let best = engine.lines.lines.first else { return }
        let depth = engine.lines.depth
        if let recorded, recorded.key == key, recorded.depth == depth { return }
        recorded = (key, depth)
        model.setEval(NodeEval(text: best.eval, depth: depth))
    }

    private enum PanelTab: Hashable {
        case moves, explorer
    }

    private func panel(compact: Bool) -> some View {
        Group {
            if compact {
                switch tab {
                case .explorer: explorer(showsHeader: false)
                case .moves: moves
                }
            } else {
                VStack(spacing: 0) {
                    moves
                    Divider()
                    explorer(showsHeader: true)
                }
            }
        }
        .safeAreaBar(edge: .top) {
            if compact {
                Picker("Panel", selection: $tab) {
                    Text("Explorer").tag(PanelTab.explorer)
                    Text("Moves").tag(PanelTab.moves)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
        }
    }

    /// Not a List: a list row has one context menu, and each move needs its own.
    private var moves: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                AnalysisMoveList(model: model)
            }
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func explorer(showsHeader: Bool) -> some View {
        List {
            AnalysisExplorerSection(model: model, showsHeader: showsHeader)
        }
        #if os(iOS)
        .listStyle(.plain)
        #endif
    }

    /// On a phone move navigation is in the bottom bar, the engine and the menu top trailing,
    /// as in Browse. In the split view they act on the board, so they are in the board
    /// column's bar. Leaving is the back button: it adds nothing to the repertoire (Browse
    /// gets an unsaved draft).
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if !inSplitView {
            ToolbarItemGroup(placement: .bottomActions) { AnalysisNavigationButtons(model: model) }
            ToolbarSpacer(.flexible, placement: .bottomActions)
            ToolbarItem(placement: .trailingBar) { AnalysisEngineToggle(model: model) }
            ToolbarSpacer(.fixed, placement: .trailingBar)
            ToolbarItem(placement: .trailingBar) { AnalysisMoreMenu(model: model) }
        }
    }
}

/// The title of the analysis board: on a phone "Analysis" with where the engine's lines come
/// from; in the split view the panel names the repertoire, as Browse's does (the board column
/// names the screen).
private struct AnalysisTitle: ViewModifier {
    @Environment(AppModel.self) private var app
    let model: AnalysisModel
    let inSplitView: Bool

    func body(content: Content) -> some View {
        if inSplitView {
            content.navigationTitle(model.document.name)
        } else {
            content
                .navigationTitle("Analysis")
                .navigationSubtitle(app.engine.status(for: model))
                .toolbarTitleDisplayMode(.inline)
        }
    }
}

extension EngineService {
    /// Where the lines come from, under the title: a Lichess cloud eval, or Stockfish at some
    /// depth. Empty while the engine is off.
    func status(for model: AnalysisModel) -> String {
        guard model.engineOn else { return "" }
        if let source = lines.source, !shownLines(for: model).isEmpty {
            return "\(source == .cloud ? "Cloud" : name ?? "Stockfish") · depth \(lines.depth)"
        }
        // Until lines come in (the placeholders show that), which engine will run.
        return error ?? name ?? ""
    }

    /// The engine's lines for the position on the board, if they are for it.
    func shownLines(for model: AnalysisModel) -> [PvLine] {
        guard model.engineOn, analysed == model.engineKey else { return [] }
        return lines.lines
    }
}

/// The analysis board: the engine's lines above it, their first moves as arrows. On a phone
/// at the top of the screen; in the split view in the board column.
struct AnalysisBoard: View {
    @Environment(AppModel.self) private var app
    let model: AnalysisModel

    var body: some View {
        let lines = app.engine.shownLines(for: model)
        VStack(spacing: 0) {
            if model.engineOn {
                EngineLinesView(lines: lines) { model.play(uci: $0) }
            }
            BoardView(position: model.position, orientation: model.orientation, lastMove: model.lastMove,
                      arrows: arrows(lines), movableSide: model.position.sideToMove()) { from, to, promotion in
                model.play(from: from, to: to, promotion: promotion)
            }
            .aspectRatio(1, contentMode: .fit)
        }
    }

    /// The first move of each engine line, the best one boldest.
    private func arrows(_ lines: [PvLine]) -> [BoardArrow] {
        lines.enumerated().compactMap { index, line in
            guard let move = line.moves.first else { return nil }
            let rank = Double(index)
            return BoardArrow(from: move.from, to: move.to, style: .engine,
                              width: max(0.1, 0.2 - rank * 0.04), opacity: max(0.3, 0.7 - rank * 0.25))
        }
    }
}

/// Back and forward through the analysis, with ← and →: in the bottom bar, as Browse's.
struct AnalysisNavigationButtons: View {
    let model: AnalysisModel

    var body: some View {
        Button("Back", systemImage: "chevron.backward") { model.back() }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(!model.canBack)
        Button("Forward", systemImage: "chevron.forward") { model.forward() }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(!model.canForward)
    }
}

/// The engine on or off.
struct AnalysisEngineToggle: View {
    let model: AnalysisModel

    var body: some View {
        Toggle(isOn: Binding(get: { model.engineOn }, set: { model.engineOn = $0 })) {
            Label("Engine", systemImage: "cpu")
        }
    }
}

/// The analysis board's menu: top trailing on a phone, at the end of the board column's bar
/// in the split view.
struct AnalysisMoreMenu: View {
    let model: AnalysisModel

    var body: some View {
        Menu("More", systemImage: "ellipsis") {
            Button("Flip Board", systemImage: "arrow.up.arrow.down") { model.orientation = model.orientation.opposite }
            Button("Copy PGN", systemImage: "doc.on.doc") { copy(model.pgn) }
            Button("Open in Lichess", systemImage: "safari") {
                model.page = WebPage(url: LichessLinks.analysis(moves: model.movesToBoard, orientation: model.orientation))
            }
            Divider()
            Button("Engine Settings", systemImage: "gearshape") { model.showsSettings = true }
        }
    }
}

/// The engine's settings over the analysis board, the same as in Settings: a full sheet, like
/// Settings itself (a partial one would be glass).
private struct EngineSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form { EngineSettingsSection() }
                .navigationTitle("Engine Settings")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", systemImage: "checkmark") { dismiss() }
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
/// Where they come from is the screen's subtitle (`EngineService.status(for:)`).
struct EngineLinesView: View {
    let lines: [PvLine]
    let play: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Button {
                    if let first = line.moves.first { play(first.uci) }
                } label: {
                    row(eval: line.eval, score: line.score, text: line.text)
                }
                .buttonStyle(.plain)
            }
            // Rows not in yet are placeholders, as in Browse, so the board stays put.
            ForEach(lines.count..<max(lines.count, EngineDefaults.lines), id: \.self) { _ in
                row(eval: "+0.0", score: .cp(0), text: "1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 Nf6")
                    .redacted(reason: .placeholder)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .animation(nil, value: lines)
    }

    private func row(eval: String, score: Score, text: String) -> some View {
        HStack(spacing: 8) {
            EvalChip(text: eval, score: score)
            Text(text)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
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

/// The moves of the analysis, laid out by the core as lichess's app does (`MoveListRow`):
/// the main line one full move per row, each variation a row under the move it replaces, with
/// a guide per level. Tap a move to go to it; long-press it to promote, copy or delete its line.
struct AnalysisMoveList: View {
    let model: AnalysisModel

    var body: some View {
        let rows = model.moveList
        if rows.isEmpty {
            Text("Play a move on the board.")
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        }
        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
            switch row {
            case .main(let row):
                HStack(spacing: 4) {
                    Text("\(row.number)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 28, alignment: .leading)
                    cell(row.white)
                    // "…" where the line goes on below the variations, nothing at its end.
                    // keeps its half either way, so White's move stays its width.
                    if row.black != nil || index < rows.count - 1 {
                        cell(row.black)
                    } else {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 2)
            case .variation(let row):
                HStack(alignment: .top, spacing: 4) {
                    HStack(spacing: 4) {
                        ForEach(Array(row.guides.enumerated()), id: \.offset) { level, goesOn in
                            Guide(own: level == row.guides.count - 1, goesOn: goesOn)
                                .stroke(.tertiary, lineWidth: 1)
                                .frame(width: 12)
                        }
                    }
                    FlowLayout(spacing: 2, lineSpacing: 2) {
                        ForEach(Array(row.tokens.enumerated()), id: \.offset) { _, token in
                            switch token {
                            case .move(let move): button(move) { AnalysisMoveChip(move: move) }
                            case .open: Text("(").foregroundStyle(.secondary)
                            case .close: Text(")").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .padding(.horizontal)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.06))
            }
        }
    }

    /// One level of a variation's guides: an outer level's line passing by (if it goes on),
    /// or this row's own ├ or └.
    private struct Guide: Shape {
        let own: Bool
        let goesOn: Bool

        func path(in rect: CGRect) -> Path {
            let x = rect.minX + 0.5
            let tick = rect.minY + 16
            var path = Path()
            if own {
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: goesOn ? rect.maxY : tick))
                path.move(to: CGPoint(x: x, y: tick))
                path.addLine(to: CGPoint(x: rect.maxX, y: tick))
            } else if goesOn {
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
            }
            return path
        }
    }

    @ViewBuilder
    private func cell(_ move: AnalysisMove?) -> some View {
        if let move {
            button(move) {
                HStack(spacing: 4) {
                    Text(move.san).fontWeight(move.isCurrent ? .semibold : .regular)
                    Spacer(minLength: 0)
                    if let eval = move.eval {
                        Text(eval).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background {
                    if move.isCurrent {
                        RoundedRectangle(cornerRadius: 6).fill(.tint.opacity(0.25))
                    }
                }
            }
            .frame(maxWidth: .infinity)
        } else {
            Text("…")
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func button(_ move: AnalysisMove, @ViewBuilder label: () -> some View) -> some View {
        Button { model.go(to: move.id) } label: {
            label().contentShape(.rect)
        }
        // Several buttons in one list row: borderless, so a tap presses this move, not the row;
        // moves read as text, not in the accent colour.
        .buttonStyle(.borderless)
        .tint(.primary)
        // Long-press lifts this move only, not the row it shares with the other side's move.
        .contextMenuPreviewShape(.rect(cornerRadius: 6))
        .contextMenu { menu(move) }
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

/// One move of a variation: number, move and the evaluation after it.
struct AnalysisMoveChip: View {
    let move: AnalysisMove

    var body: some View {
        HStack(spacing: 3) {
            if let number = move.number {
                Text(number).foregroundStyle(.secondary)
            }
            Text(move.san).fontWeight(move.isCurrent ? .semibold : .regular)
            if let eval = move.eval {
                Text(eval).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .font(.callout.monospacedDigit())
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background {
            if move.isCurrent {
                RoundedRectangle(cornerRadius: 6).fill(.tint.opacity(0.25))
            }
        }
    }
}

/// The explorer's moves in the position, from the repertoire's database: tap to play one.
struct AnalysisExplorerSection: View {
    @Environment(AppModel.self) private var app
    let model: AnalysisModel
    /// Off under the phone's Moves/Explorer control, which already names the section.
    var showsHeader = true

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
                        row(san: move.san, games: Format.games(games),
                            share: Format.percent(Double(games) / Double(total))) {
                            ScoreBar(white: move.white, draws: move.draws, black: move.black)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            } else if app.isLoadingStats {
                // Placeholders while the stats load, as in Browse.
                ForEach(0..<5, id: \.self) { _ in
                    row(san: "Nf3", games: "1.2M", share: "45%") {
                        RoundedRectangle(cornerRadius: 3).fill(.quaternary).frame(height: 18)
                    }
                    .redacted(reason: .placeholder)
                    .accessibilityHidden(true)
                }
            } else {
                StatsUnavailableNote()
            }
        } header: {
            if showsHeader {
                Text(stats?.opening.map { "\($0.eco) \($0.name)" } ?? "Explorer")
            }
        }
        .task(id: epd) { model.document.requestStats(for: epd) }
    }

    private func row(san: String, games: String, share: String,
                     @ViewBuilder bar: () -> some View) -> some View {
        HStack(spacing: 10) {
            Text(san).frame(width: 56, alignment: .leading)
            Text(games).monospacedDigit()
                .frame(width: 56, alignment: .trailing)
            Text(share).monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
            bar()
        }
    }
}
