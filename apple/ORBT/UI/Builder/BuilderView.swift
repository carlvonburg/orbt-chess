import OpeningCoreRust
import StoreKit
import SwiftUI
import TipKit

/// The main screen: board, move path, and a panel that shows the opponent's replies
/// (with gaps) or your moves and candidates.
struct BuilderView: View {
    @Environment(AppModel.self) private var app
    /// In the split view (iPad, Mac) the board is in the board column and this is the panel.
    @Environment(\.inSplitView) private var inSplitView
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openScreen) private var openScreen
    @Environment(\.openAnalysis) private var openAnalysis
    @Environment(\.requestReview) private var requestReview
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
    /// The split view's tips, one at a time, the first whose rules hold (`builderTip`).
    @State private var panelTips = TipGroup(.firstAvailable) {
        AnswerTip()
        RepliesTip()
        SaveTip()
        SaveDraftTip()
        BiggestGapTip()
        StudyBranchTip()
    }
    /// What the last save did to coverage, shown for a moment (`CoverageToast`).
    @State private var coverageChange: CoverageChange?

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
        // In a split view, pinned to the bottom of this column with the list scrolling under it:
        // in view however long the list (as its last row it sat below the fold), and off the
        // board, which has its own column, so no popover over it.
        .safeAreaBar(edge: .bottom) {
            if inSplitView {
                TipView(panelTips.currentTip)
                    .padding(.horizontal)
                    .padding(.bottom, 12)
            }
        }
        // The list fades under the tip, with no divider above it.
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollDismissesKeyboard(.immediately)
        .onDisappear { StudyBranchTip.justSaved = false }
        .onAppear {
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
        // The tips' rules (`AppTips`): what the board shows.
        .onChange(of: tipState, initial: true) { _, state in
            AnswerTip.yourMoveMissing = state.yourMoveMissing
            RepliesTip.repliesNeeded = state.repliesNeeded
            SaveTip.lineReached = state.lineReached
            SaveDraftTip.canSave = state.canSave
            BiggestGapTip.canJump = state.canJump
            StudyBranchTip.canStudy = state.canStudy
        }
        // Their actions: your move played where it was missing, a reply that needs an answer
        // played in a new line.
        .onChange(of: model.draft.count) { old, new in
            guard new > old else { return }
            StudyBranchTip.justSaved = false
            if model.isUserTurnOnBoard {
                if new >= 2 { RepliesTip().invalidate(reason: .actionPerformed) }
            } else {
                AnswerTip().invalidate(reason: .actionPerformed)
            }
        }
        // Over the list, clear of a phone's floating bottom bar (which the list runs under).
        .overlay(alignment: .bottom) {
            CoverageToast(change: $coverageChange).padding(.bottom, inSplitView ? 0 : 64)
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
        study(.branch(node))
    }

    /// Opens a study session: through the library, which keeps only this screen under it,
    /// else pushed here.
    private func study(_ mode: DrillMode) {
        StudyBranchTip().invalidate(reason: .actionPerformed)
        if let openScreen {
            switch mode {
            case .study: openScreen(.study(document.entryID))
            case .branch(let node): openScreen(.branch(document.entryID, node))
            case .practice(let node): openScreen(.practice(document.entryID, node))
            }
        } else {
            presentation.drill = DrillRequest(mode: mode)
        }
    }

    private struct TipState: Equatable {
        var yourMoveMissing = false
        var repliesNeeded = false
        var lineReached = false
        var canSave = false
        var canJump = false
        var canStudy = false
    }

    /// Your move missing on the board (a gap, or a new line at your move); a new line at the
    /// opponent's move with replies that still need an answer, then (from your second move on)
    /// that it can be saved already; saved moves with a gap for Biggest Gap to go to.
    private var tipState: TipState {
        if model.hasDraft {
            if model.draftTransposition != nil { return TipState() }
            if model.isUserTurnOnBoard { return TipState(yourMoveMissing: true) }
            if model.draftReachedTarget { return TipState(lineReached: true) }
            // From the third move of the line (two of yours as White, the second of yours as
            // Black at the fourth): by then the replies' tip has been shown.
            if model.draft.count >= 3 { return TipState(canSave: true) }
            return TipState(repliesNeeded: model.draftReplies?.contains(where: \.required) == true)
        }
        return TipState(yourMoveMissing: model.node.flatMap { document.coverage[$0.id]?.status } == .gap,
                        // Gaps below this move (Biggest Gap's own fallback, the repertoire's
                        // biggest gap elsewhere, is not "in this line").
                        canJump: model.canGoToBiggestGap && (document.coverage[model.current]?.gapCount ?? 0) > 0,
                        canStudy: document.learningProgress(under: model.current).cards > 0)
    }

    private func goToBiggestGap() {
        BiggestGapTip().invalidate(reason: .actionPerformed)
        model.goToBiggestGap()
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
                BuilderNavigationButtons(model: model)
            }
            ToolbarSpacer(.flexible, placement: .bottomActions)
        }
        if model.hasDraft {
            // While a new line is on the board: keep it or drop it.
            ToolbarItemGroup(placement: actions) {
                if !split {
                    Button("Analysis", systemImage: "cpu") { presentation.analyze(model, open: openAnalysis) }
                }
                Button("Discard", systemImage: "xmark", role: .destructive) { model.discardDraft() }
            }
            ToolbarSpacer(.fixed, placement: actions)
            ToolbarItem(placement: actions) {
                Button {
                    let before = CoverageChange.Snapshot(document.coverage.root)
                    // Where the line starts and its first move, to find it once saved.
                    let start = model.current
                    let first = model.draft.first?.uci
                    if model.draftReachedTarget { SaveTip().invalidate(reason: .actionPerformed) }
                    SaveDraftTip().invalidate(reason: .actionPerformed)
                    // The study tip's turn only once the gaps tip has had its own.
                    StudyBranchTip.justSaved = if case .invalidated = BiggestGapTip().status { true } else { false }
                    model.saveDraft()
                    let saved = first.flatMap { model.tree.child(of: start, uci: $0) }
                    var open = false
                    if let saved, let gaps = document.coverage[saved]?.gapCount { open = gaps > 0 }
                    withAnimation {
                        coverageChange = CoverageChange(before: before, after: .init(document.coverage.root),
                                                        lineOpen: open)
                    }
                    ReviewPrompt.ask(requestReview)
                } label: {
                    Label(model.draft.count == 1 ? "Save" : "Save \(model.draft.count)", systemImage: "checkmark")
                }
                .buttonStyle(.glassProminent)
            }
        } else {
            ToolbarItemGroup(placement: actions) {
                Button("Biggest Gap", systemImage: "scope", action: goToBiggestGap)
                    .disabled(!model.canGoToBiggestGap)

                StudyMenu(progress: document.learningProgress(under: model.current),
                          atRoot: model.current == RepertoireTree.rootID,
                          study: { study($0 ? .branch(model.current) : .study) },
                          practice: { study(.practice(model.current)) })

                if !split {
                    Button("Analysis", systemImage: "cpu") { presentation.analyze(model, open: openAnalysis) }
                }
            }
        }
        if !split {
            ToolbarItem(placement: .trailingBar) {
                BuilderMoreMenu(model: model, presentation: presentation)
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
    }
}


/// Back and forward, in the bottom bar (on a phone, and under the board in the split view). Their
/// keys (←/→) are in the menu bar's Move menu.
struct BuilderNavigationButtons: View {
    let model: BuilderModel

    var body: some View {
        // Each button its own: the bar takes the buttons out of this view.
        Button("Back", systemImage: "chevron.backward") { model.back() }
            .disabled(!model.canBack)
        Button("Forward", systemImage: "chevron.forward") { model.forward() }
            .disabled(!model.canForward)
    }
}

extension View {
    /// A Browse tip: on a phone a popover from what it explains, over the board above; in the
    /// split view nothing here, the panel lists its tips under its rows (`BuilderView.panelTips`).
    func builderTip(_ tip: some Tip) -> some View {
        modifier(BuilderTip(tip: tip))
    }

    /// A `TipGroup`'s current tip, the same way.
    func builderTip(_ tip: (any Tip)?) -> some View {
        modifier(BuilderGroupTip(tip: tip))
    }
}

private struct BuilderTip<T: Tip>: ViewModifier {
    @Environment(\.inSplitView) private var inSplitView
    let tip: T

    func body(content: Content) -> some View {
        if inSplitView {
            content
        } else {
            content.popoverTip(tip, arrowEdge: .bottom)
        }
    }
}

private struct BuilderGroupTip: ViewModifier {
    @Environment(\.inSplitView) private var inSplitView
    let tip: (any Tip)?

    func body(content: Content) -> some View {
        if inSplitView {
            content
        } else {
            content.popoverTip(tip, arrowEdge: .bottom)
        }
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
                .disabled(model?.canGoToBiggestGap != true)
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

/// Studies from Build: today's moves in this branch (Anki's subdeck), today's moves of the whole
/// repertoire, or every learned move in the branch again.
private struct StudyMenu: View {
    let progress: Progress
    /// At the start position the branch is the whole repertoire.
    let atRoot: Bool
    /// true: the branch; false: the whole repertoire.
    let study: (Bool) -> Void
    let practice: () -> Void

    var body: some View {
        Menu("Study", systemImage: "graduationcap") {
            Button("Study Repertoire", systemImage: "graduationcap") { study(false) }
            if !atRoot {
                Button("Study Branch", systemImage: "arrow.triangle.branch") { study(true) }
                    .disabled(progress.cards == 0)
            }
            Button(atRoot ? "Practice Repertoire" : "Practice Branch",
                   systemImage: "arrow.trianglehead.2.clockwise", action: practice)
                .disabled(progress.studied == 0)
        }
        // In this order from the top, also in a bottom bar (which would reverse it).
        .menuOrder(.fixed)
    }
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
    /// On the gaps and moves under the board, one at a time: how to reach the gaps, else (no
    /// gaps, or that tip done) how to study the saved moves.
    @State private var countTips = TipGroup(.firstAvailable) {
        BiggestGapTip()
        StudyBranchTip()
    }
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
                    Text(Format.seenGames(reach)).font(.caption).foregroundStyle(.secondary)
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
                // The whole repertoire's, as on the overview: the number a save raises. A
                // branch's own share read as the repertoire's (100% deep in a line).
                progress("Built", value: document.coverage.root?.completion ?? 0)
                Spacer(minLength: 0)
                // What lies below this move; at the start, the whole repertoire.
                HStack(spacing: 0) {
                    if let gaps = info?.gapCount, gaps > 0 {
                        Text("\(gaps.formatted()) \(gaps == 1 ? "gap" : "gaps")").foregroundStyle(.todo)
                        Text(" · ").foregroundStyle(.secondary)
                    }
                    Text("\(saved.formatted()) \(saved == 1 ? "move" : "moves")").foregroundStyle(.secondary)
                    if node.id != RepertoireTree.rootID {
                        Text(" below").foregroundStyle(.secondary)
                    }
                }
                .font(.caption2.monospacedDigit())
                // What the counts lead to (⌖ the gaps, 🎓 the saved moves); over the board.
                .builderTip(countTips.currentTip)
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
                .contentTransition(.numericText(value: value))
        }
        .animation(.default, value: value)
    }

    @ViewBuilder
    private func statusChip(_ info: NodeCoverage?) -> some View {
        switch info?.status {
        case .gap:
            Text("Your move is missing").font(.caption).statusBadge(tint: .todo)
                .builderTip(AnswerTip())
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
                Spacer()
                Text("Seen").font(.caption).foregroundStyle(.secondary).frame(width: 74, alignment: .trailing)
                Text("Covered").font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                    // In a new line that still needs answers, where covering a reply is the step.
                    .builderTip(RepliesTip())
                Text("Games").font(.caption).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
            }
            .padding(.top, 8)
            .builderRow(separator: false)
            if let replies, !replies.isEmpty {
                // Replies in the repertoire, needed or excluded first, then the ones not needed;
                // each group by how often it is played.
                let matters = { (r: ReplyInfo) in r.child != nil || r.transposesTo != nil || r.required || r.excluded }
                let ordered = replies.filter(matters).sorted { $0.share > $1.share }
                    + replies.filter { !matters($0) }.sorted { $0.share > $1.share }
                ForEach(ordered, id: \.uci) { reply in
                    ReplyRow(reply: reply, node: saved?.id, model: model, eval: eval?.text(for: reply.uci))
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
            ForEach(otherRows, id: \.uci) { move in
                row(uci: move.uci, san: move.san, move: move, total: stats?.total ?? 0)
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
                        // What the badge means. Over the board.
                        .builderTip(SaveTip())
                } else {
                    Text("New line, not saved").font(.caption).statusBadge()
                        // Your move in a new line (Biggest Gap's reply played): the gap's tip,
                        // over the board (its rule keeps it to your move). After your move, that
                        // the line can be saved already.
                        .builderTip(AnswerTip())
                        .builderTip(SaveDraftTip())
                }
                if let reach = model.reachOnBoard {
                    Text(Format.seenGames(reach)).font(.caption).foregroundStyle(.secondary)
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
        let positions = unchecked == 1 ? "1 position" : "\(unchecked.formatted()) positions"
        if unchecked > 0 {
            HStack(spacing: 6) {
                switch app.queue.state {
                case .rateLimited(let until):
                    Image(systemName: "hourglass")
                    Text("Lichess asked to slow down · resuming \(Date(timeIntervalSince1970: TimeInterval(until) / 1000), style: .relative)")
                case .offline:
                    Image(systemName: "wifi.slash")
                    Text("Offline · \(positions) not checked yet")
                case .needsLogin:
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                    Text("Sign in to Lichess to check \(positions)")
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
