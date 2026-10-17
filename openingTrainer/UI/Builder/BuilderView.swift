import OpeningCore
import SwiftUI

/// The main screen: board, move path, and a panel that shows the opponent's replies
/// (with gaps) or your moves and candidates.
struct BuilderView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var model: BuilderModel
    @State private var sheet: Sheet?
    @State private var drill: DrillRequest?

    enum Sheet: String, Identifiable {
        case outline, gaps, note, analysis, settings
        var id: String { rawValue }
    }

    init(document: RepertoireDocument, start: NodeID? = nil) {
        _model = State(initialValue: BuilderModel(document: document, start: start))
    }

    private var document: RepertoireDocument { model.document }

    var body: some View {
        let _ = document.revision
        GeometryReader { geo in
            if sizeClass == .regular && geo.size.width > geo.size.height {
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 12) {
                        board
                        MovePathStrip(model: model)
                        Spacer(minLength: 0)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    List { panelRows }
                        .listStyle(.plain)
                        .frame(width: 420)
                }
            } else {
                // A List so saved moves can be swiped to delete.
                List {
                    // Edge to edge on a phone.
                    board
                        .frame(maxWidth: .infinity)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                    if model.current != RepertoireTree.rootID || model.hasDraft {
                        MovePathStrip(model: model)
                            .builderRow(separator: false)
                    }
                    panelRows
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 0)
                .scrollDismissesKeyboard(.immediately)
            }
        }
        .navigationTitle(document.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(item: $sheet) { sheet in sheetContent(sheet) }
        .fullScreenCover(item: $drill) { request in
            DrillView(document: document, mode: request.mode)
        }
        .onAppear { document.startCoverageCheck() }
        .onDisappear { document.stopCoverageCheck() }
        .onChange(of: model.current, initial: true) { requestStats() }
        .onChange(of: model.draft) { requestStats() }
        .alert("Could not save", isPresented: .constant(document.saveError != nil)) {
            Button("OK") {}
        } message: {
            Text(document.saveError ?? "")
        }
    }

    private var board: some View {
        BoardView(position: model.position, orientation: model.orientation, lastMove: model.lastMove,
                  arrows: model.arrows, movableSide: model.position.sideToMove) { from, to, promotion in
            model.play(from: from, to: to, promotion: promotion)
        }
        .frame(maxWidth: 680)
    }

    private func requestStats() {
        let epd = model.position.epd
        document.requestStats(for: epd)
    }

    // MARK: Panel

    /// The panel as List rows: header rows without separators, then one row per move.
    @ViewBuilder
    private var panelRows: some View {
        if model.hasDraft {
            DraftPanel(model: model)
        } else if let node = model.node {
            NodeHeader(model: model, node: node, onNote: { sheet = .note })
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
                RepliesPanel(model: model, node: shown)
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("Undo", systemImage: "arrow.uturn.backward") { document.undo() }
                .disabled(!document.canUndo)
            Menu("More", systemImage: "ellipsis") {
                Button("Outline", systemImage: "list.bullet.indent") { sheet = .outline }
                Button("Gaps", systemImage: "exclamationmark.circle") { sheet = .gaps }
                Button("Edit Note", systemImage: "note.text") { sheet = .note }
                Button("Flip Board", systemImage: "arrow.up.arrow.down") { model.orientation = model.orientation.opposite }
                Divider()
                Button("Repertoire Settings", systemImage: "gearshape") { sheet = .settings }
            }
        }
        ToolbarItemGroup(placement: .bottomBar) {
            Button("Back", systemImage: "chevron.backward") { model.back() }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(model.current == RepertoireTree.rootID && !model.hasDraft)
            Button("Forward", systemImage: "chevron.forward") { model.forward() }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(!model.canForward)
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        if model.hasDraft {
            // While a new line is on the board: keep it or drop it.
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Analyze on Lichess", systemImage: "cpu") { sheet = .analysis }
                Button("Discard", systemImage: "xmark", role: .destructive) { model.discardDraft() }
            }
            ToolbarSpacer(.fixed, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button { model.saveDraft() } label: {
                    Label(model.draft.count == 1 ? "Save" : "Save \(model.draft.count)", systemImage: "checkmark")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.glassProminent)
            }
        } else {
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Biggest Gap", systemImage: "scope") { model.goToBiggestGap() }
                    .disabled(document.coverage.root?.biggestGap == nil)
                Button("Train This Branch", systemImage: "graduationcap") {
                    drill = DrillRequest(mode: .branch(model.current))
                }
                .disabled(document.learningProgress(under: model.current).cards == 0)
                Button("Analyze on Lichess", systemImage: "cpu") { sheet = .analysis }
            }
        }
        ToolbarItem(placement: .keyboard) {
            HStack {
                Button("Previous line") { model.sibling(-1) }.keyboardShortcut(.upArrow, modifiers: [])
                Button("Next line") { model.sibling(1) }.keyboardShortcut(.downArrow, modifiers: [])
            }
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: Sheet) -> some View {
        switch sheet {
        case .outline:
            OutlineSheet(model: model) { drill = DrillRequest(mode: .branch($0)) }
        case .gaps:
            GapsSheet(model: model)
                .presentationDetents([.medium, .large])
        case .note:
            NoteSheet(document: document, node: model.current)
                .presentationDetents([.medium, .large])
        case .analysis:
            SafariView(url: LichessLinks.analysis(moves: model.movesToBoard, orientation: model.orientation))
                .ignoresSafeArea()
        case .settings:
            RepertoireSettingsSheet(document: document)
        }
    }
}

/// The current position's lines are stored under another move order.
struct TranspositionNote: View {
    let model: BuilderModel
    let target: NodeID

    var body: some View {
        Button { model.go(to: target) } label: {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transposes. Lines continue after").font(.callout)
                    Text(Format.moveList(model.tree.moves(to: target), startPly: model.tree.root.ply))
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(.blue.opacity(0.12), in: .rect(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 6)
    }
}

struct DrillRequest: Identifiable {
    let mode: DrillMode
    var id: String { "\(mode)" }
}

/// Horizontally scrolling move list; tap a move to go there. Draft moves are dashed.
struct MovePathStrip: View {
    let model: BuilderModel

    var body: some View {
        let path = Array(model.tree.path(to: model.current).dropFirst())
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
                    ForEach(path, id: \.self) { id in
                        if let node = model.tree[id], let move = node.move {
                            chip(ply: node.ply, san: move.san, isCurrent: id == model.current && !model.hasDraft, dashed: false)
                                .onTapGesture { model.go(to: id) }
                                .id(id)
                        }
                    }
                    let basePly = model.node?.ply ?? 0
                    ForEach(Array(model.draft.enumerated()), id: \.offset) { i, move in
                        chip(ply: basePly + i + 1, san: move.san, isCurrent: i == model.draft.count - 1, dashed: true)
                            .id("draft\(i)")
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: model.current) { proxy.scrollTo(model.current, anchor: .trailing) }
            .onChange(of: model.draft.count) {
                if model.hasDraft { proxy.scrollTo("draft\(model.draft.count - 1)", anchor: .trailing) }
            }
        }
    }

    private func chip(ply: Int, san: String, isCurrent: Bool, dashed: Bool) -> some View {
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
                RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.25))
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
    let node: RepertoireNode
    let onNote: () -> Void

    var body: some View {
        let document = model.document
        let info = document.coverage[node.id]
        let learning = document.learningProgress(under: node.id)
        VStack(alignment: .leading, spacing: 8) {
            if let name = openingName {
                Text(name).font(.subheadline.weight(.semibold)).lineLimit(2)
            }
            HStack(spacing: 8) {
                statusChip(info)
                if let reach = info?.reach, node.id != RepertoireTree.rootID {
                    Text(reach >= 0.67 ? "Seen in every game" : "Seen \(Format.seenEvery(reach)) games").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            CoverageCheckStatus(document: document)
            HStack(spacing: 12) {
                progress("Built", value: info?.completion ?? 0, tint: .green)
                progress("Learned", value: learning.matureFraction, tint: .blue)
            }
            if !node.note.isEmpty {
                Button(action: onNote) {
                    Text(node.note)
                        .font(.callout)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.yellow.opacity(0.15), in: .rect(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 4)
    }

    private var openingName: String? {
        var cursor: NodeID? = node.id
        while let id = cursor, let n = model.tree[id] {
            if let name = model.document.stats(n.epd)?.opening?.name { return name }
            cursor = n.parent
        }
        return nil
    }

    private func progress(_ title: String, value: Double, tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            CompletionBar(value: value, tint: tint)
            Text(Format.percent(value)).font(.caption2.monospacedDigit())
        }
    }

    @ViewBuilder
    private func statusChip(_ info: NodeCoverage?) -> some View {
        switch info?.status {
        case .gap:
            Text("Your move is missing").font(.caption.weight(.semibold)).glassChip(tint: .orange)
        case .pending:
            Text("Stats not loaded yet").font(.caption).glassChip()
        case .belowTarget:
            Text("Beyond your target").font(.caption).glassChip()
        case .transposition:
            Text("Transposes").font(.caption).glassChip(tint: .blue)
        case .alternative:
            Text("Alternative line").font(.caption).glassChip()
        case .unknown:
            Text("Stats unavailable").font(.caption).glassChip()
        default:
            EmptyView()
        }
    }
}

/// Opponent to move: the replies from the explorer with coverage, plus moves in the
/// repertoire that the explorer does not list.
struct RepliesPanel: View {
    @Environment(AppModel.self) private var app
    let model: BuilderModel
    let node: RepertoireNode

    var body: some View {
        let document = model.document
        let info = document.coverage[node.id]
        Group {
            HStack {
                Text("Replies").font(.headline)
                Spacer()
                Text("Seen").font(.caption).foregroundStyle(.secondary).frame(width: 74, alignment: .trailing)
                Text("Covered").font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                Text("Games").font(.caption).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                Color.clear.frame(width: 22, height: 1)
            }
            .padding(.top, 8)
            .builderRow(separator: false)
            if let replies = info?.replies, !replies.isEmpty {
                let stats = document.stats(node.epd)
                // Replies in the repertoire first, then the rest; each group by how often it is played.
                let ordered = replies.filter { $0.child != nil || $0.transposesTo != nil }.sorted { $0.share > $1.share }
                    + replies.filter { $0.child == nil && $0.transposesTo == nil }.sorted { $0.share > $1.share }
                ForEach(ordered, id: \.uci) { reply in
                    ReplyRow(reply: reply, games: stats?.moves.first { $0.uci == reply.uci }?.games, model: model)
                        .builderRow()
                }
            } else {
                ForEach(node.children, id: \.self) { child in
                    if let move = model.tree[child]?.move {
                        Button { model.go(to: child) } label: {
                            HStack {
                                Text(move.san).font(.body.weight(.semibold))
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .deletable(child, model: model)
                        .builderRow()
                    }
                }
                StatsUnavailableNote()
                    .builderRow(separator: false)
            }
        }
    }
}

struct ReplyRow: View {
    let reply: ReplyInfo
    let games: Int?
    let model: BuilderModel

    var body: some View {
        let inRepertoire = reply.child != nil || reply.transposesTo != nil
        let isGap = reply.required && !inRepertoire
        HStack(spacing: 10) {
            Button {
                if let child = reply.child { model.go(to: child) } else { model.preview(uci: reply.uci) }
            } label: {
                HStack(spacing: 8) {
                    Text(reply.san).font(.body.weight(.semibold)).frame(minWidth: 48, alignment: .leading)
                    if isGap {
                        Text("Gap").font(.caption2.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.orange, in: .capsule)
                    } else if reply.transposesTo != nil && reply.child == nil {
                        Text("Transposes").font(.caption2).foregroundStyle(.blue)
                    }
                    Spacer()
                    Text(Format.seenEvery(reply.reach)).font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary).frame(width: 74, alignment: .trailing)
                    Group {
                        if inRepertoire && reply.required {
                            CompletionBar(value: reply.completion, tint: reply.completion >= 0.999 ? .green : .yellow)
                        } else if !reply.required {
                            Text("Not needed").font(.caption2).foregroundStyle(.tertiary)
                        } else {
                            CompletionBar(value: 0, tint: .orange)
                        }
                    }
                    .frame(width: 64)
                    Text(games.map(Format.games) ?? "").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                .opacity(reply.required || inRepertoire ? 1 : 0.55)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if reply.child == nil {
                // Opens the reply on the board so you can add your answer; it is saved with it.
                Button("Add \(reply.san)", systemImage: "plus.circle.fill") { model.preview(uci: reply.uci) }
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(isGap ? .orange : .secondary)
                    .buttonStyle(.borderless)
            } else {
                Image(systemName: "chevron.right").foregroundStyle(.tertiary).frame(width: 22)
            }
        }
        .padding(.vertical, 9)
        .deletable(reply.child, model: model)
    }
}

/// Your move: explorer candidates with your saved moves marked in place.
struct YourMovePanel: View {
    let model: BuilderModel
    let node: RepertoireNode

    var body: some View {
        if node.children.isEmpty {
            Label("Choose your move: play it on the board or pick a candidate.", systemImage: "hand.point.up.left")
                .font(.callout)
                .foregroundStyle(.orange)
                .padding(.vertical, 8)
                .builderRow(separator: false)
        }
        CandidatesSection(model: model, epd: node.epd, title: "Candidates", savedAt: node,
                          select: model.preview(uci:), add: model.add(uci:))
    }
}

/// Explorer moves for a position with cloud eval, results, games and share of games.
/// Moves saved under `savedAt` come first (with their note and Main/Alternative tag), then the
/// other explorer moves; each group is sorted by how often it is played.
/// Tapping a row plays the move on the board (or opens a saved move); + adds it.
struct CandidatesSection: View {
    let model: BuilderModel
    let epd: EPD
    let title: String
    var savedAt: RepertoireNode?
    let select: (String) -> Void
    let add: (String) -> Void
    @State private var eval: CloudEvalClient.Eval?

    var body: some View {
        let stats = model.document.stats(epd)
        let explorer = stats?.moves ?? []
        let saved = savedChildren
        let isSaved = { (uci: String) in saved.contains { $0.uci == uci } }
        // Saved moves first, then the other explorer moves; each group by how often it is played.
        let savedRows = saved.map { move in (move, explorer.first { $0.uci == move.uci }) }
            .sorted { ($0.1?.games ?? -1) > ($1.1?.games ?? -1) }
        let otherRows = explorer.filter { !isSaved($0.uci) }.prefix(max(0, 12 - savedRows.count))
        Text(title).font(.headline).padding(.top, 8)
            .builderRow(separator: false)
            .task(id: epd) {
                eval = nil
                eval = await CloudEvalClient.fetch(epd)
            }
        ForEach(savedRows, id: \.0.uci) { played, move in
            row(uci: played.uci, san: played.san, move: move, total: stats?.total ?? 0)
                .builderRow()
                .listRowBackground(Color.green.opacity(0.08))
        }
        ForEach(otherRows, id: \.uci) { move in
            row(uci: move.uci, san: move.san, move: move, total: stats?.total ?? 0)
                .builderRow()
        }
        if explorer.isEmpty {
            StatsUnavailableNote()
                .builderRow(separator: false)
        }
    }

    private var savedChildren: [PlayedMove] {
        guard let savedAt else { return [] }
        return savedAt.children.compactMap { model.tree[$0]?.move }
    }

    private func row(uci: String, san: String, move: ExplorerMove?, total: Int) -> some View {
        let saved = savedAt.flatMap { parent in
            parent.children.firstIndex { model.tree[$0]?.move?.uci == uci }.map { index in
                SavedMove(id: parent.children[index], index: index, siblings: parent.children.count,
                          note: model.tree[parent.children[index]]?.note ?? "")
            }
        }
        return CandidateRow(san: san, move: move, total: total, eval: eval?.text(for: uci), saved: saved,
                            select: { if let saved { model.go(to: saved.id) } else { select(uci) } },
                            add: { add(uci) })
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
                        .tint(.red)
                    if let promote {
                        Button("Main", systemImage: "arrow.up.to.line", action: promote)
                            .tint(.green)
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

extension CloudEvalClient.Eval {
    /// Eval after `uci`, from White's point of view, if it is one of the cloud lines.
    func text(for uci: String) -> String? {
        guard let pv = pvs.first(where: { $0.moves.hasPrefix(uci) }) else { return nil }
        if let mate = pv.mate { return "#\(mate)" }
        guard let cp = pv.cp else { return nil }
        return String(format: "%+.1f", Double(cp) / 100)
    }
}

struct CandidateRow: View {
    let san: String
    let move: ExplorerMove?
    let total: Int
    let eval: String?
    let saved: SavedMove?
    let select: () -> Void
    let add: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: select) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(san).font(.body.weight(.semibold)).frame(minWidth: 48, alignment: .leading)
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
                        } else {
                            Spacer()
                        }
                    }
                    if let saved, saved.tag != nil || !saved.note.isEmpty {
                        HStack(spacing: 6) {
                            if let tag = saved.tag {
                                if saved.index == 0 {
                                    Text(tag).font(.caption2).glassChip(tint: .green)
                                } else {
                                    Text(tag).font(.caption2).foregroundStyle(.secondary)
                                }
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
            if saved != nil {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
                    .accessibilityLabel("In repertoire")
            } else {
                Button("Add \(san)", systemImage: "plus.circle", action: add)
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 8)
    }
}

/// Shown while a draft is on the board: the same candidates as a saved position.
/// Tapping a move extends the draft; + extends it and saves the line.
struct DraftPanel: View {
    let model: BuilderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("New line").font(.headline)
            Text("Keep playing moves for both sides, then save.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
        .builderRow(separator: false)
        CandidatesSection(model: model, epd: model.position.epd,
                          title: model.isUserTurnOnBoard ? "Candidates" : "Opponent's replies",
                          select: model.play(uci:),
                          add: { uci in
                              model.play(uci: uci)
                              model.saveDraft()
                          })
    }
}

struct StatsUnavailableNote: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            switch app.queue.state {
            case .needsLogin:
                SignInBanner()
            case .offline:
                Label("Offline. Statistics will load when you're back online.", systemImage: "wifi.slash")
            case .rateLimited:
                Label("Lichess asked us to slow down. Resuming in a minute.", systemImage: "hourglass")
            default:
                if app.auth.isSignedIn {
                    HStack { ProgressView(); Text("Loading statistics…") }
                } else {
                    SignInBanner()
                }
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.vertical, 8)
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
                    Text("Lichess asked to slow down · resuming \(until, style: .relative)")
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
