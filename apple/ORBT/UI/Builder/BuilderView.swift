import OpeningCoreRust
import SwiftUI

/// The main screen: board, move path, and a panel that shows the opponent's replies
/// (with gaps) or your moves and candidates.
struct BuilderView: View {
    @Environment(AppModel.self) private var app
    /// In the split view (iPad, Mac) the board is in the board column and this is the panel.
    @Environment(\.inSplitView) private var inSplitView
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openScreen) private var openScreen
    @Environment(\.openAnalysis) private var openAnalysis
    let model: BuilderModel
    let presentation: BuilderPresentation

    enum Sheet: String, Identifiable {
        case outline, gaps, note, cardInfo
        var id: String { rawValue }
    }

    /// The library makes the models before pushing the screen (`LibraryScreens`); elsewhere
    /// `BuilderScreen` owns them.
    init(model: BuilderModel, presentation: BuilderPresentation) {
        self.model = model
        self.presentation = presentation
    }

    private var document: RepertoireDocument { model.document }
    /// The tour's step for the draft on the board, while it builds the line.
    private var tourDraftStep: Tour.Step? {
        guard isSample, [.answer, .extend, .save].contains(Tour.current), model.hasDraft else { return nil }
        if model.isUserTurnOnBoard { return .answer }
        return model.draftReachedTarget ? .save : .extend
    }

    /// The bundled sample, where the tour's tips show.
    private var isSample: Bool { RepertoireLibrary.isSample(document.pgnURL) }

    var body: some View {
        let _ = document.revision
        @Bindable var presentation = presentation
        // A List so saved moves can be swiped to delete.
        List {
            if !inSplitView {
                // Edge to edge on a phone.
                BuilderBoard(model: model)
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                if model.current != RepertoireTree.rootID || model.hasDraft {
                    MovePathStrip(model: model)
                        .builderRow(separator: false)
                }
            }
            panelRows
        }
        .listStyle(.plain)
        .tourScreen(running: isSample)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollDismissesKeyboard(.immediately)
        .onAppear {
            if isSample {
                Tour.advance(from: .browse, to: .biggestGap)
                // A line being built is gone (the app was closed): find the gap again.
                if !model.hasDraft {
                    for step in [Tour.Step.answer, .extend, .save] { Tour.advance(from: step, to: .biggestGap) }
                }
            }
            // Edit > Undo and ⌘Z undo through the builder, which also leaves a removed position.
            document.attachUndo(undoManager) { [weak model, weak document] in
                if let model { model.undo() } else { document?.undo() }
            }
        }
        // The menu bar's Move commands act on this builder, unless a sheet has the keys.
        .focusedSceneValue(\.builder, presentation.sheet == nil ? model : nil)
        .boardScreenTitle("Browse", subtitle: document.name)
        .toolbar { toolbar }
        .hidesTabBar()
        .sheet(item: $presentation.sheet) { sheet in sheetContent(sheet).presentationSizing(.form) }
        .analysisDestination($presentation.analysis)
        .navigationDestination(item: $presentation.drill) { request in
            DrillScreen(document: document, mode: request.mode)
        }
        .checksCoverage(document)
        .onChange(of: model.current, initial: true) { requestStats() }
        .onChange(of: model.draft) { requestStats() }
        // The tour builds the line until coverage is reached: your answer, then a reply that
        // needs one, and so on; Save only once every reply is below the target.
        .onChange(of: tourDraftStep) { _, step in
            if let step { Tour.draftChanged(to: step) }
        }
        .alert("Could not save", isPresented: Binding(
            get: { document.saveError != nil }, set: { if !$0 { document.dismissSaveError() } })) {
            Button("OK") {}
        } message: {
            Text(document.saveError ?? "")
        }
    }

    /// Studies the branch from `node`: through the library, which keeps only this screen
    /// under it, else pushed here.
    private func studyBranch(_ node: NodeID) {
        if let openScreen {
            openScreen(.branch(document.entryID, node))
        } else {
            presentation.drill = DrillRequest(mode: .branch(node))
        }
    }

    private func requestStats() {
        let epd = model.position.epd()
        document.requestStats(for: epd)
    }

    // MARK: Panel

    /// The panel as List rows: header rows without separators, then one row per move.
    @ViewBuilder
    private var panelRows: some View {
        if model.hasDraft {
            DraftPanel(model: model)
        } else if let node = model.node {
            NodeHeader(model: model, node: node, onNote: { presentation.sheet = .note })
                .builderRow(separator: false)
            // At a transposition the panels show the moves stored for this position elsewhere.
            let shown = model.shownNode ?? node
            if let target = model.continuation {
                TranspositionNote(model: model, target: target)
                    .builderRow(separator: false)
            }
            if shown.sideToMove == document.color {
                YourMovePanel(model: model, node: shown)
            } else {
                RepliesPanel(model: model, replies: document.coverage[shown.id]?.replies, saved: shown)
            }
        }
    }

    // MARK: Toolbar

    /// On a phone move navigation and the actions are in the bottom bar, the menu top
    /// trailing. In the split view the actions are in the panel's bar; move navigation, Analysis
    /// and the menu, which act on the board, in the board column's.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        let split = inSplitView
        let actions: ToolbarItemPlacement = split ? .trailingBar : .bottomActions
        if !split {
            ToolbarItemGroup(placement: .bottomActions) {
                BuilderNavigationButtons(model: model, tourRunning: isSample)
            }
            ToolbarSpacer(.flexible, placement: .bottomActions)
        }
        if model.hasDraft {
            // While a new line is on the board: keep it or drop it.
            ToolbarItemGroup(placement: actions) {
                if !split {
                    Button("Analysis", systemImage: "cpu") { presentation.analyze(model, open: openAnalysis) }
                        .tourBarButton(.analysis, running: isSample)
                }
                Button("Discard", systemImage: "xmark", role: .destructive) { model.discardDraft() }
                    .tourBarButton(nil, running: isSample)
            }
            ToolbarSpacer(.fixed, placement: actions)
            ToolbarItem(placement: actions) {
                Button {
                    // Where the draft starts, and its first move (Biggest Gap's reply).
                    let start = model.current
                    let first = model.draft.first?.uci
                    model.saveDraft()
                    if isSample, Tour.current == .save {
                        Tour.saved()
                        // To the first new move, so Study Branch trains only the line just added
                        // (from `start`, it would also train the rest of the repertoire).
                        model.go(to: first.flatMap { model.tree.child(of: start, uci: $0) } ?? start)
                    }
                } label: {
                    Label(model.draft.count == 1 ? "Save" : "Save \(model.draft.count)", systemImage: "checkmark")
                }
                .buttonStyle(.glassProminent)
                .tourBarButton(.save, running: isSample)

            }
        } else {
            ToolbarItemGroup(placement: actions) {
                Button("Biggest Gap", systemImage: "scope") {
                    model.goToBiggestGap()
                    if isSample {
                        Tour.advance(from: .biggestGap, to: .answer)
                    }
                }
                .disabled(document.coverage.root?.biggestGap == nil)
                .tourBarButton(.biggestGap, running: isSample)

                Button("Study Branch", systemImage: "graduationcap") {
                    // The tour's last step.
                    if isSample { Tour.advance(from: .study, to: .studying) }
                    studyBranch(model.current)
                }
                .disabled(document.learningProgress(under: model.current).cards == 0)
                .tourBarButton(.studyBranch, running: isSample)

                if !split {
                    Button("Analysis", systemImage: "cpu") { presentation.analyze(model, open: openAnalysis) }
                        .tourBarButton(nil, running: isSample)
                }
            }
        }
        if !split {
            ToolbarItem(placement: .trailingBar) {
                BuilderMoreMenu(model: model, presentation: presentation).tourBarButton(nil, running: isSample)
            }
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: Sheet) -> some View {
        switch sheet {
        case .outline:
            OutlineSheet(model: model) { studyBranch($0) }
        case .gaps:
            GapsSheet(model: model)
                .presentationDetents([.medium, .large])
        case .note:
            NoteSheet(document: document, node: model.current)
                .presentationDetents([.medium, .large])
        case .cardInfo:
            CardInfoSheet(document: document, node: model.current)
                .presentationDetents([.medium, .large])
        }
    }
}

/// A builder that owns its models: opened outside the library (a weakest move in the
/// Statistics tab).
struct BuilderScreen: View {
    @State private var model: BuilderModel
    @State private var presentation = BuilderPresentation()

    init(document: RepertoireDocument, start: NodeID? = nil) {
        _model = State(initialValue: BuilderModel(document: document, start: start))
    }

    var body: some View {
        BuilderView(model: model, presentation: presentation)
    }
}

/// What the builder presents: a sheet, the analysis board (outside the library), a branch
/// drill. In the split view the board column's buttons set it and the panel presents it.
@Observable
final class BuilderPresentation {
    var sheet: BuilderView.Sheet?
    var analysis: AnalysisModel?
    var drill: DrillRequest?

    init(sheet: BuilderView.Sheet? = nil) {
        self.sheet = sheet
    }

    /// The analysis board from the position on the board, pushed through the library (`open`),
    /// else here; going back puts its line on the builder as a draft.
    func analyze(_ model: BuilderModel, open: ((AnalysisModel) -> Void)?) {
        let analysis = AnalysisModel(document: model.document, moves: model.movesToBoard,
                                     orientation: model.orientation, origin: .build(model))
        if let open { open(analysis) } else { self.analysis = analysis }
    }
}

/// The builder's menu: top trailing on a phone, at the end of the board column's bar in the
/// split view.
struct BuilderMoreMenu: View {
    let model: BuilderModel
    let presentation: BuilderPresentation

    var body: some View {
        let document = model.document
        Menu("More", systemImage: "ellipsis") {
            Button("Undo", systemImage: "arrow.uturn.backward") { model.undo() }
                .disabled(!document.canUndo)
            Divider()
            Button("Outline", systemImage: "list.bullet.indent") { presentation.sheet = .outline }
            Button("Gaps", systemImage: "exclamationmark.circle") { presentation.sheet = .gaps }
            Button("Edit Note", systemImage: "note.text") { presentation.sheet = .note }
            Button("Move Info", systemImage: "info.circle") { presentation.sheet = .cardInfo }
                .disabled(document.tree[model.current].flatMap { document.sidecar.studyCards[$0.epd] } == nil
                          || document.tree[model.current]?.sideToMove != document.color)
            Button("Flip Board", systemImage: "arrow.up.arrow.down") { model.orientation = model.orientation.opposite }
        }
    }
}

/// The builder's board: moves played on it go to the model.
struct BuilderBoard: View {
    let model: BuilderModel

    var body: some View {
        BoardView(position: model.position, orientation: model.orientation, lastMove: model.lastMove,
                  arrows: model.arrows, movableSide: model.position.sideToMove()) { from, to, promotion in
            model.play(from: from, to: to, promotion: promotion)
        }
        .tourTarget(.board)
    }
}

/// Back and forward, in the bottom bar (on a phone, and under the board in the split view). Their
/// keys (←/→) are in the menu bar's Move menu.
struct BuilderNavigationButtons: View {
    let model: BuilderModel
    /// On the sample: the tour locks them while a step asks for something else.
    var tourRunning = false

    var body: some View {
        // Each button its own: the bar takes the buttons out of this view.
        Button("Back", systemImage: "chevron.backward") { model.back() }
            .disabled(!model.canBack)
            .tourBarButton(nil, running: tourRunning)
        Button("Forward", systemImage: "chevron.forward") { model.forward() }
            .disabled(!model.canForward)
            .tourBarButton(nil, running: tourRunning)
    }
}

extension FocusedValues {
    /// The builder on screen, for the menu bar's Move commands.
    @Entry var builder: BuilderModel?
}

/// The builder's moves in the menu bar (iPad, Mac; listed when ⌘ is held on iPad and iPhone),
/// with their keys: ←/→ through the line, ↑/↓ to the previous or next line.
struct BuilderCommands: Commands {
    @FocusedValue(\.builder) private var model

    var body: some Commands {
        CommandMenu("Move") {
            Button("Back") { model?.back() }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(!(model?.canBack ?? false))
            Button("Forward") { model?.forward() }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(!(model?.canForward ?? false))
            Divider()
            Button("Previous Line") { model?.sibling(-1) }
                .keyboardShortcut(.upArrow, modifiers: [])
                .disabled(model == nil)
            Button("Next Line") { model?.sibling(1) }
                .keyboardShortcut(.downArrow, modifiers: [])
                .disabled(model == nil)
            Divider()
            Button("Biggest Gap") { model?.goToBiggestGap() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(model?.document.coverage.root?.biggestGap == nil)
            Button("Flip Board") { model.map { $0.orientation = $0.orientation.opposite } }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(model == nil)
        }
    }
}

/// The builder's board in the split view's board column. Its moves are in the column's bottom
/// bar with move navigation; Analysis and the menu in its top bar.
struct BuilderBoardColumn: View {
    let model: BuilderModel

    var body: some View {
        BoardColumnLayout {
            BuilderBoard(model: model)
        } below: {
            EmptyView()
        }
    }
}

/// The current position's lines are stored under another move order.
struct TranspositionNote: View {
    let model: BuilderModel
    let target: NodeID
    /// The board shows an unsaved draft that reaches `target`'s position.
    var inDraft = false

    var body: some View {
        if inDraft {
            // Not a link: going there would drop the draft. Saving it covers this position.
            content(detail: "Save to cover this move order.")
                .padding(.vertical, 6)
        } else {
            Button { model.go(to: target) } label: {
                content(detail: nil)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 6)
        }
    }

    private func content(detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(.built)
            VStack(alignment: .leading, spacing: 2) {
                Text(inDraft ? "Transposed into" : "Transposes. Lines continue after").font(.callout)
                Text(Format.moveList(model.tree.moves(to: target), startPly: model.tree.root.ply))
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !inDraft {
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(.fill.tertiary, in: .rect(cornerRadius: 10))
        .contentShape(Rectangle())
    }
}

struct DrillRequest: Hashable {
    let mode: DrillMode
}

/// The moves to here, then the main line ahead (what → plays), dimmed; tap a move to go there.
/// Draft moves are dashed. Scrolls sideways: it starts at the left and grows, and once full it
/// keeps the current move in view. In a bar it gets a fixed width, so the bar never resizes.
struct MovePathStrip: View {
    let model: BuilderModel

    var body: some View {
        let path = Array(model.tree.path(to: model.current).dropFirst())
        // One list for the moves to here and the line ahead, so going back or forward only
        // moves the highlight: no chip comes or goes.
        let line = path + model.lineAhead
        let target = model.hasDraft ? "draft\(model.draft.count - 1)" : "move\(model.current)"
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    // Only needed once you have left the start position.
                    if model.current != RepertoireTree.rootID || model.hasDraft {
                        Button { model.go(to: RepertoireTree.rootID) } label: {
                            Image(systemName: "house")
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 6)
                        .accessibilityLabel("Start position")
                    }
                    ForEach(Array(line.enumerated()), id: \.element) { index, id in
                        if let node = model.tree[id], let move = node.move {
                            MoveChip(ply: Int(node.ply), san: move.san, isCurrent: id == model.current && !model.hasDraft)
                                .opacity(index < path.count ? 1 : 0.45)
                                .onTapGesture { model.go(to: id) }
                                .id("move\(id)")
                        }
                    }
                    let basePly = Int(model.node?.ply ?? 0)
                    ForEach(Array(model.draft.enumerated()), id: \.offset) { i, move in
                        MoveChip(ply: basePly + i + 1, san: move.san, isCurrent: i == model.draft.count - 1, dashed: true)
                            .id("draft\(i)")
                    }
                }
                .padding(.vertical, 4)
            }
            // Room at both ends, so the first and last moves (highlighted) clear the bar's edge.
            .contentMargins(.horizontal, 8, for: .scrollContent)
            .onAppear { proxy.scrollTo(target, anchor: .center) }
            .onChange(of: target) {
                withAnimation { proxy.scrollTo(target, anchor: .center) }
            }
        }
    }
}

/// One move of a move list: "1. d4", with the current move highlighted.
struct MoveChip: View {
    let ply: Int
    let san: String
    let isCurrent: Bool
    var dashed = false

    var body: some View {
        HStack(spacing: 2) {
            if ply % 2 == 1 {
                Text("\(ply / 2 + 1).").foregroundStyle(.secondary)
            }
            Text(san).fontWeight(isCurrent ? .bold : .regular)
        }
        .font(.callout.monospacedDigit())
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background {
            if isCurrent {
                RoundedRectangle(cornerRadius: 6).fill(.tint.opacity(0.25))
            }
        }
        .overlay {
            if dashed {
                RoundedRectangle(cornerRadius: 6).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Opening name, reach, building and learning progress, and the note of the current node.
struct NodeHeader: View {
    let model: BuilderModel
    let node: Node
    let onNote: () -> Void

    var body: some View {
        let document = model.document
        let info = document.coverage[node.id]
        // At a transposition, the moves shown below are stored at the target.
        let saved = model.tree.subtree(of: model.shownNode?.id ?? node.id).count - 1
        VStack(alignment: .leading, spacing: 8) {
            if let name = document.openingName(at: node.id) {
                Text(name).font(.subheadline.weight(.semibold)).lineLimit(2)
            }
            HStack(spacing: 8) {
                statusChip(info)
                if let reach = info?.reach, node.id != RepertoireTree.rootID {
                    Text(reach >= 0.67 ? "Seen in every game" : "Seen \(Format.seenEvery(reach)) games").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if node.sideToMove == document.color, document.sidecar.studyCards[node.epd]?.leech == true {
                    // Anki's "leech" tag: a move you keep forgetting
                    Label("Leech", systemImage: "ant.fill")
                        .font(.caption)
                        .statusBadge(tint: .todo)
                        .accessibilityHint("You keep forgetting this move.")
                }
            }
            CoverageCheckStatus(document: document)
            HStack(spacing: 12) {
                progress("Built", value: info?.completion ?? 0)
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    if let gaps = info?.gapCount, gaps > 0 {
                        Text("\(gaps.formatted()) \(gaps == 1 ? "gap" : "gaps")").foregroundStyle(.todo)
                        Text(" · ").foregroundStyle(.secondary)
                    }
                    Text("\(saved.formatted()) \(saved == 1 ? "move" : "moves")").foregroundStyle(.secondary)
                }
                .font(.caption2.monospacedDigit())
            }
            if !node.note.isEmpty {
                Button(action: onNote) {
                    Text(node.note)
                        .font(.callout)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.fill.tertiary, in: .rect(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 4)
    }

    private func progress(_ title: String, value: Double) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            CoverageBar(value: value)
            Text(Format.percent(value)).font(.caption2.monospacedDigit())
        }
    }

    @ViewBuilder
    private func statusChip(_ info: NodeCoverage?) -> some View {
        switch info?.status {
        case .gap:
            Text("Your move is missing").font(.caption).statusBadge(tint: .todo)
        case .pending:
            Text("Stats not loaded yet").font(.caption).statusBadge()
        case .belowTarget:
            Text("Beyond your target").font(.caption).statusBadge()
        case .transposition:
            Text("Transposes").font(.caption).statusBadge(tint: .built)
        case .alternative:
            Text("Alternative line").font(.caption).statusBadge()
        case .unknown:
            Text("Stats unavailable").font(.caption).statusBadge()
        default:
            EmptyView()
        }
    }
}

/// Opponent to move: the replies from the explorer with coverage, plus moves in the
/// repertoire that the explorer does not list. `saved` is the node when the position is in the
/// repertoire, nil for a draft.
struct RepliesPanel: View {
    @Environment(AppModel.self) private var app
    let model: BuilderModel
    let replies: [ReplyInfo]?
    let saved: Node?
    @State private var eval: CloudEval?

    var body: some View {
        let epd = saved?.epd ?? model.position.epd()
        Group {
            HStack {
                Text("Replies").font(.headline)
                    // The tour's replies step shows the heading row with the replies.
                Spacer()
                Text("Seen").font(.caption).foregroundStyle(.secondary).frame(width: 74, alignment: .trailing)
                Text("Covered").font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                Text("Games").font(.caption).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
            }
            .padding(.top, 8)
            .tourTarget(.replies, part: -1)
            .builderRow(separator: false)
            if let replies, !replies.isEmpty {
                // Replies in the repertoire, needed or excluded first, then the ones not needed;
                // each group by how often it is played.
                let matters = { (r: ReplyInfo) in r.child != nil || r.transposesTo != nil || r.required || r.excluded }
                let ordered = replies.filter(matters).sorted { $0.share > $1.share }
                    + replies.filter { !matters($0) }.sorted { $0.share > $1.share }
                // The tour asks for a reply that needs an answer: the first few of those (they
                // come first), so the highlight ends above the bottom bar.
                let needed = min(4, ordered.prefix { $0.required && !$0.excluded }.count)
                ForEach(Array(ordered.enumerated()), id: \.element.uci) { index, reply in
                    ReplyRow(reply: reply, node: saved?.id, model: model, eval: eval?.text(for: reply.uci))
                        .tourTarget(.replies, part: index < max(needed, 1) ? index : nil)
                        .builderRow()
                }
            } else {
                ForEach(saved?.children ?? [], id: \.self) { child in
                    if let move = model.tree[child]?.move {
                        Button { model.go(to: child) } label: {
                            HStack {
                                Text(move.san).font(.body.weight(.semibold))
                                Spacer()
                            }
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .deletable(child, model: model)
                        .builderRow()
                    }
                }
                if model.document.stats(epd) != nil {
                    Text("No games in this position.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                        .builderRow(separator: false)
                } else if app.isLoadingStats {
                    // Stand-ins until the stats come in; your saved replies are already above.
                    ForEach(0..<4, id: \.self) { _ in
                        ReplyPlaceholderRow().builderRow()
                    }
                } else {
                    StatsUnavailableNote()
                        .builderRow(separator: false)
                }
            }
        }
        // Lichess's cloud eval of each reply, as for your candidates.
        .task(id: epd) {
            eval = nil
            eval = await CloudEvalClient.fetch(epd)
        }
    }
}

/// Stands in for an explorer reply while the stats load, laid out like `ReplyRow`.
struct ReplyPlaceholderRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("Nf6").font(.body.weight(.semibold)).frame(minWidth: 48, alignment: .leading)
            Text("+0.0").font(.caption.monospacedDigit().weight(.semibold)).frame(width: 40)
            Spacer()
            Text("1 in 100").font(.caption.monospacedDigit()).frame(width: 74, alignment: .trailing)
            RoundedRectangle(cornerRadius: 3).fill(.quaternary).frame(width: 64, height: 8)
            Text("1.2M").font(.caption2.monospacedDigit()).frame(width: 40, alignment: .trailing)
        }
        .redacted(reason: .placeholder)
        .padding(.vertical, 9)
        .accessibilityHidden(true)
    }
}

struct ReplyRow: View {
    let reply: ReplyInfo
    /// The saved position the reply is at; nil in a draft.
    let node: NodeID?
    let model: BuilderModel
    /// Lichess's cloud eval after the reply, nil while unknown.
    var eval: String?

    var body: some View {
        let transposes = reply.child == nil && (reply.transposesTo != nil || model.transposition(after: reply.uci) != nil)
        let inRepertoire = reply.child != nil || transposes
        // Tapping opens the reply; one not in the repertoire is played on the board so you can
        // add your answer, and is saved with it.
        Button {
            if let child = reply.child {
                model.go(to: child)
            } else if node != nil {
                model.preview(uci: reply.uci)
            } else {
                model.play(uci: reply.uci)
            }
        } label: {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Text(reply.san).font(.body.weight(.semibold))
                        .foregroundStyle(reply.required || inRepertoire ? .primary : .secondary)
                    if transposes {
                        TranspositionIcon()
                    }
                }
                .frame(minWidth: 48, alignment: .leading)
                Text(eval ?? "")
                    .font(.caption.monospacedDigit().weight(.semibold)).frame(width: 40)
                Spacer()
                Text(Format.seenEvery(reply.reach)).font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary).frame(width: 74, alignment: .trailing)
                Group {
                    if inRepertoire && reply.required {
                        CoverageBar(value: reply.completion, height: 4)
                    } else if reply.excluded {
                        Text("Excluded").font(.caption2).foregroundStyle(.tertiary)
                    } else if !reply.required {
                        Text("Not needed").font(.caption2).foregroundStyle(.tertiary)
                    } else {
                        CoverageBar(value: 0, height: 4)
                    }
                }
                .frame(width: 64)
                Text(reply.games > 0 ? Format.games(reply.games) : "").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 9)
        .deletable(reply.child, model: model)
        .excludable(reply.child == nil ? reply : nil, at: node, model: model)
    }
}

/// Your move: explorer candidates with your saved moves marked in place.
struct YourMovePanel: View {
    let model: BuilderModel
    let node: Node

    var body: some View {
        CandidatesSection(model: model, epd: node.epd, title: "Candidates", savedAt: node,
                          select: model.preview(uci:))
    }
}

/// Explorer moves for a position with cloud eval, results, games and share of games.
/// Moves saved under `savedAt` come first (with their note and Main/Alternative tag), then the
/// other explorer moves; each group is sorted by how often it is played. Once a move is saved,
/// the heading reads "Your Moves" and the other moves stay hidden behind "Add Alternative Move".
/// Tapping a row plays the move on the board (or opens a saved move).
struct CandidatesSection: View {
    @Environment(AppModel.self) private var app
    let model: BuilderModel
    let epd: EPD
    let title: String
    var savedAt: Node?
    let select: (String) -> Void
    @State private var eval: CloudEval?
    @State private var showOthers = false

    var body: some View {
        let stats = model.document.stats(epd)
        let explorer = stats?.moves ?? []
        let saved = savedChildren
        let isSaved = { (uci: String) in saved.contains { $0.uci == uci } }
        // Saved moves first, then the other explorer moves; each group by how often it is played.
        let savedRows = saved.map { move in (move, explorer.first { $0.uci == move.uci }) }
            .sorted { ($0.1?.games ?? -1) > ($1.1?.games ?? -1) }
        let otherRows = explorer.filter { !isSaved($0.uci) }.prefix(max(0, 12 - savedRows.count))
        let collapsed = !saved.isEmpty && !showOthers
        let loading = stats == nil && app.isLoadingStats
        Text(saved.isEmpty ? title : "Your Moves").font(.headline).padding(.top, 8)
            // The tour's answer step shows the heading with the candidates under it.
            .tourTarget(.candidates, part: -1)
            .builderRow(separator: false)
            .task(id: epd) {
                showOthers = false
                eval = nil
                eval = await CloudEvalClient.fetch(epd)
            }
        ForEach(savedRows, id: \.0.uci) { played, move in
            row(uci: played.uci, san: played.san, move: move, total: stats?.total ?? 0, loading: loading)
                .builderRow()
                .listRowBackground(Rectangle().fill(.built.opacity(0.08)))
        }
        if collapsed {
            Button("Add Alternative Move", systemImage: "plus") { showOthers = true }
                .padding(.vertical, 10)
                .builderRow(separator: false)
        } else {
            if !saved.isEmpty {
                Text(title).font(.headline).padding(.top, 8)
                    .builderRow(separator: false)
            }
            let tourRows = tourRows(otherRows.map(\.uci))
            ForEach(Array(otherRows.enumerated()), id: \.element.uci) { index, move in
                row(uci: move.uci, san: move.san, move: move, total: stats?.total ?? 0)
                    // The tour's answer step points at the candidates: the first few, so the
                    // highlight ends above the bottom bar. Inside the row's own modifiers:
                    // after them, the List sizes the row as a new one.
                    .tourTarget(.candidates, part: index < tourRows ? index : nil)
                    .builderRow()
            }
            if loading {
                // Stand-ins until the stats come in; your saved moves are already above.
                ForEach(0..<4, id: \.self) { _ in
                    CandidatePlaceholderRow().builderRow()
                }
            } else if stats == nil {
                StatsUnavailableNote()
                    .builderRow(separator: false)
            } else if explorer.isEmpty {
                Text("No games in this position.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                    .builderRow(separator: false)
            }
        }
    }

    /// How many of the first candidates the tour's answer step offers: up to four, and on the
    /// sample only those whose replies have stats (from the coverage table, so offline too),
    /// so the line can go on until coverage is reached instead of stopping at no replies.
    private func tourRows(_ moves: [String]) -> Int {
        guard Tour.current == .answer, RepertoireLibrary.isSample(model.document.pgnURL) else { return 4 }
        let position = model.position
        let known = moves.prefix(4).prefix { uci in
            position.playUci(uci: uci).map { model.document.stats($0.position.epd()) != nil } ?? false
        }.count
        return max(known, 1)
    }

    private var savedChildren: [PlayedMove] {
        guard let savedAt else { return [] }
        return savedAt.children.compactMap { model.tree[$0]?.move }
    }

    private func row(uci: String, san: String, move: ExplorerMove?, total: Int, loading: Bool = false) -> some View {
        let saved = savedAt.flatMap { parent in
            parent.children.firstIndex { model.tree[$0]?.move?.uci == uci }.map { index in
                SavedMove(id: parent.children[index], index: index, siblings: parent.children.count,
                          note: model.tree[parent.children[index]]?.note ?? "")
            }
        }
        return CandidateRow(san: san, move: move, total: total, eval: eval?.text(for: uci), loading: loading,
                            transposes: model.transposition(after: uci) != nil, saved: saved,
                            select: { if let saved { model.go(to: saved.id) } else { select(uci) } })
            .deletable(saved?.id, model: model,
                       promote: saved.flatMap { saved in saved.index > 0 ? { model.document.promote(saved.id) } : nil })
    }
}

extension View {
    /// Layout for one row of the builder's List.
    func builderRow(separator: Bool = true) -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
            .listRowSeparator(separator ? .automatic : .hidden)
    }

    /// Long-press menu and swipe actions for a saved move: Delete (confirmed in a dialog anchored
    /// to this row) and, for an alternative, Make Main Move. Does nothing for a move that is not saved.
    func deletable(_ id: NodeID?, model: BuilderModel, promote: (() -> Void)? = nil) -> some View {
        modifier(DeleteMove(id: id, model: model, promote: promote))
    }
}

extension View {
    /// Long-press menu and swipe action to exclude an opponent move you have no line for from
    /// coverage, or include it again. Does nothing when `reply` is nil.
    func excludable(_ reply: ReplyInfo?, at node: NodeID?, model: BuilderModel) -> some View {
        modifier(ExcludeMove(reply: node == nil ? nil : reply, node: node ?? RepertoireTree.rootID, model: model))
    }
}

private struct ExcludeMove: ViewModifier {
    let reply: ReplyInfo?
    let node: NodeID
    let model: BuilderModel

    func body(content: Content) -> some View {
        if let reply {
            let title = reply.excluded ? "Include" : "Exclude"
            let icon = reply.excluded ? "plus.circle" : "nosign"
            let toggle = { model.document.setExcluded(reply.uci, at: node, !reply.excluded) }
            content
                .contextMenu {
                    Button("\(title) \(reply.san)", systemImage: icon, action: toggle)
                }
                .swipeActions(edge: .trailing) {
                    Button(title, systemImage: icon, action: toggle)
                        .tint(.gray)
                }
        } else {
            content
        }
    }
}

private struct DeleteMove: ViewModifier {
    let id: NodeID?
    let model: BuilderModel
    let promote: (() -> Void)?
    @State private var confirming = false

    func body(content: Content) -> some View {
        if let id {
            content
                .contextMenu {
                    if let promote {
                        Button("Make Main Move", systemImage: "arrow.up.to.line", action: promote)
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) { confirming = true }
                }
                // Not .destructive: that role removes the row before the dialog is answered.
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Delete", systemImage: "trash") { confirming = true }
                        .tint(ThemeColor.failure)
                    if let promote {
                        Button("Main", systemImage: "arrow.up.to.line", action: promote)
                            .tint(ThemeColor.built)
                            .accessibilityLabel("Make Main Move")
                    }
                }
                .confirmationDialog(title(id), isPresented: $confirming, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) { model.delete(id) }
                } message: {
                    Text(message(id))
                }
        } else {
            content
        }
    }

    private func title(_ id: NodeID) -> String {
        model.tree[id]?.move.map { "Delete \($0.san)?" } ?? "Delete move?"
    }

    private func message(_ id: NodeID) -> String {
        guard model.tree[id]?.children.isEmpty == false else { return "You can undo this." }
        let lines = model.tree.leaves(under: id).count
        return lines == 1 ? "This also deletes the line that follows it. You can undo this."
            : "This also deletes the \(lines) lines that follow it. You can undo this."
    }
}

/// A candidate that is already in the repertoire.
struct SavedMove {
    let id: NodeID
    let index: Int
    let siblings: Int
    let note: String

    var tag: String? {
        if index > 0 { return "Alternative · not trained" }
        return siblings > 1 ? "Main" : nil
    }
}

struct CandidateRow: View {
    let san: String
    let move: ExplorerMove?
    let total: Int
    let eval: String?
    /// Stats not in yet: placeholders where they will be.
    var loading = false
    /// Playing it reaches a position whose lines you already have elsewhere.
    var transposes = false
    let saved: SavedMove?
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Text(san).font(.body.weight(.semibold))
                        if transposes { TranspositionIcon() }
                    }
                    .frame(minWidth: 48, alignment: .leading)
                    Text(eval ?? "")
                        .font(.caption.monospacedDigit().weight(.semibold)).frame(width: 40)
                    if let move {
                        ScoreBar(white: move.white, draws: move.draws, black: move.black)
                        // Games and share of games side by side, as in the Lichess explorer.
                        let share = Format.percent(total > 0 ? Double(move.games) / Double(total) : 0)
                        Text("\(Text(Format.games(move.games)).foregroundStyle(.primary)) · \(share)")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(width: 76, alignment: .trailing)
                    } else if loading {
                        StatsPlaceholder()
                    } else {
                        Spacer()
                    }
                }
                if let saved, saved.tag != nil || !saved.note.isEmpty {
                    HStack(spacing: 6) {
                        if let tag = saved.tag {
                            Text(tag).font(.caption2).foregroundStyle(.secondary)
                        }
                        if !saved.note.isEmpty {
                            Text(saved.note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 8)
    }
}

/// The score bar and game counts of a candidate, greyed out while its stats load.
private struct StatsPlaceholder: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 3).fill(.quaternary).frame(height: 18)
        Text("1.2M · 45%")
            .font(.caption2.monospacedDigit())
            .frame(width: 76, alignment: .trailing)
            .redacted(reason: .placeholder)
    }
}

/// Marks a move that leads into a position whose lines you already have.
struct TranspositionIcon: View {
    var body: some View {
        Image(systemName: "arrow.triangle.branch")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.built)
            .accessibilityLabel("Transposes")
    }
}

/// Stands in for an explorer candidate while the stats load.
struct CandidatePlaceholderRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("Nf3").font(.body.weight(.semibold)).frame(minWidth: 48, alignment: .leading)
                .redacted(reason: .placeholder)
            Color.clear.frame(width: 40, height: 1)
            StatsPlaceholder()
        }
        .padding(.vertical, 8)
        .accessibilityHidden(true)
    }
}

/// Shown while a draft is on the board: the same candidates or replies as a saved position.
/// Tapping a move extends the draft.
struct DraftPanel: View {
    let model: BuilderModel

    var body: some View {
        let target = model.draftTransposition
        let replies = model.isUserTurnOnBoard ? nil : model.draftReplies
        // Every reply is below the target: the line is deep enough to save.
        let reached = model.draftReachedTarget
        // Laid out like NodeHeader: opening name, then status and reach.
        VStack(alignment: .leading, spacing: 8) {
            if let name = openingName {
                Text(name).font(.subheadline.weight(.semibold)).lineLimit(2)
            }
            HStack(spacing: 8) {
                if target != nil {
                    Text("Transposed").font(.caption).statusBadge(tint: .built)
                } else if reached {
                    Text("Coverage target reached").font(.caption).statusBadge(tint: .built)
                } else {
                    Text("New line, not saved").font(.caption).statusBadge()
                }
                if let reach = model.reachOnBoard {
                    Text("Seen \(Format.seenEvery(reach)) games").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(.top, 4)
        .builderRow(separator: false)
        .sensoryFeedback(.success, trigger: reached) { old, new in !old && new }
        if let target, let node = model.tree[target] {
            // Your lines from this position, with their coverage.
            TranspositionNote(model: model, target: target, inDraft: true)
                .builderRow(separator: false)
            if node.sideToMove == model.document.color {
                YourMovePanel(model: model, node: node)
            } else {
                RepliesPanel(model: model, replies: model.document.coverage[target]?.replies, saved: node)
            }
        } else if model.isUserTurnOnBoard {
            CandidatesSection(model: model, epd: model.position.epd(), title: "Candidates",
                              select: model.play(uci:))
        } else {
            RepliesPanel(model: model, replies: replies, saved: nil)
        }
    }

    private var openingName: String? {
        model.document.stats(model.position.epd())?.opening?.name ?? model.document.openingName(at: model.current)
    }
}

extension AppModel {
    /// Stats for the position on screen are on their way: signed in, and not paused by
    /// Lichess or offline.
    var isLoadingStats: Bool {
        guard auth.isSignedIn else { return false }
        switch queue.state {
        case .needsLogin, .offline, .rateLimited: return false
        case .idle, .fetching: return true
        }
    }
}

struct StatsUnavailableNote: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        switch app.queue.state {
        case .needsLogin:
            SignInButton()
        case .offline:
            note("Offline. Statistics will load when you're back online.", systemImage: "wifi.slash")
        case .rateLimited:
            note("Lichess asked us to slow down. Resuming in a minute.", systemImage: "hourglass")
        default:
            if app.auth.isSignedIn {
                HStack { ProgressView(); Text("Loading statistics…") }
                    .font(.footnote).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                SignInButton()
            }
        }
    }

    private func note(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.footnote).foregroundStyle(.secondary).padding(.vertical, 8)
    }
}

extension View {
    /// Runs the background coverage check of `document` while this view is on screen.
    func checksCoverage(_ document: RepertoireDocument) -> some View {
        onAppear { document.startCoverageCheck() }
            .onDisappear { document.stopCoverageCheck() }
    }
}

/// Shows the background coverage check while it runs.
struct CoverageCheckStatus: View {
    @Environment(AppModel.self) private var app
    let document: RepertoireDocument

    var body: some View {
        let unchecked = document.uncheckedPositions
        if unchecked > 0 {
            HStack(spacing: 6) {
                switch app.queue.state {
                case .rateLimited(let until):
                    Image(systemName: "hourglass")
                    Text("Lichess asked to slow down · resuming \(Date(timeIntervalSince1970: TimeInterval(until) / 1000), style: .relative)")
                case .offline:
                    Image(systemName: "wifi.slash")
                    Text("Offline · \(unchecked) positions not checked yet")
                case .needsLogin:
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                    Text("Sign in to Lichess to check \(unchecked) positions")
                default:
                    ProgressView().controlSize(.mini)
                    Text("Checking coverage · \(unchecked) waiting")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
