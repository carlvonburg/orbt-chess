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
        case outline, gaps, note, paste, analysis, settings
        var id: String { rawValue }
    }

    init(document: RepertoireDocument) {
        _model = State(initialValue: BuilderModel(document: document))
    }

    private var document: RepertoireDocument { model.document }

    var body: some View {
        let _ = document.revision
        Group {
            if sizeClass == .regular {
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 12) {
                        board
                        MovePathStrip(model: model)
                        Spacer(minLength: 0)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    ScrollView { panel.padding() }
                        .frame(width: 420)
                        .background(.background.secondary)
                }
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        board
                        MovePathStrip(model: model)
                        panel
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.immediately)
            }
        }
        .navigationTitle(document.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) { draftBar }
        .sheet(item: $sheet) { sheet in sheetContent(sheet) }
        .fullScreenCover(item: $drill) { request in
            DrillView(document: document, mode: request.mode)
        }
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
        .frame(maxWidth: 560)
        .clipShape(.rect(cornerRadius: 6))
    }

    private func requestStats() {
        let epd = model.position.epd
        document.requestStats(for: epd)
    }

    // MARK: Panel

    @ViewBuilder
    private var panel: some View {
        if model.hasDraft {
            DraftPanel(model: model)
        } else if let node = model.node {
            NodeHeader(model: model, node: node, onNote: { sheet = .note }, onTrain: {
                drill = DrillRequest(mode: .branch(node.id))
            })
            if node.sideToMove == document.color {
                YourMovePanel(model: model, node: node)
            } else {
                RepliesPanel(model: model, node: node)
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
                Button("Train This Branch", systemImage: "graduationcap") {
                    drill = DrillRequest(mode: .branch(model.current))
                }
                Button("Gaps", systemImage: "exclamationmark.circle") { sheet = .gaps }
                Button("Paste PGN…", systemImage: "doc.on.clipboard") { sheet = .paste }
                Button("Edit Note", systemImage: "note.text") { sheet = .note }
                Button("Flip Board", systemImage: "arrow.up.arrow.down") { model.orientation = model.orientation.opposite }
                if model.current != RepertoireTree.rootID {
                    Button("Make Main Line", systemImage: "arrow.up.to.line") { document.promote(model.current) }
                    Button("Delete From Here", systemImage: "trash", role: .destructive) { model.deleteCurrent() }
                }
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
                .disabled(model.hasDraft || model.node?.children.isEmpty != false)
            Spacer()
            Button("Biggest Gap", systemImage: "scope") { model.goToBiggestGap() }
                .disabled(document.coverage.root?.biggestGap == nil)
            Button("Outline", systemImage: "list.bullet.indent") { sheet = .outline }
            Button("Analyze on Lichess", systemImage: "magnifyingglass") { sheet = .analysis }
        }
        ToolbarItem(placement: .keyboard) {
            HStack {
                Button("Previous line") { model.sibling(-1) }.keyboardShortcut(.upArrow, modifiers: [])
                Button("Next line") { model.sibling(1) }.keyboardShortcut(.downArrow, modifiers: [])
            }
        }
    }

    @ViewBuilder
    private var draftBar: some View {
        if model.hasDraft {
            GlassEffectContainer {
                HStack(spacing: 12) {
                    Button(role: .destructive) { model.discardDraft() } label: {
                        Label("Discard", systemImage: "xmark")
                    }
                    .buttonStyle(.glass)
                    Button { model.saveDraft() } label: {
                        Label("Save \(model.draft.count == 1 ? "move" : "\(model.draft.count) moves")", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                }
                .padding(.horizontal)
                .padding(.bottom, 6)
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
        case .paste:
            PastePGNSheet(model: model)
        case .analysis:
            SafariView(url: LichessLinks.analysis(moves: model.movesToBoard, orientation: model.orientation))
                .ignoresSafeArea()
        case .settings:
            RepertoireSettingsSheet(document: document)
        }
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
                    Button { model.go(to: RepertoireTree.rootID) } label: {
                        Image(systemName: "house")
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 6)
                    .accessibilityLabel("Start position")
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
    let onTrain: () -> Void

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
                    Text("Seen \(Format.seenEvery(reach)) games").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
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
            if let gaps = info?.gapCount, gaps > 0 || learning.cards > 0 {
                HStack {
                    if gaps > 0 {
                        Label("\(gaps) gaps below", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                    }
                    Spacer()
                    if learning.cards > 0 {
                        Button("Train branch", systemImage: "graduationcap", action: onTrain)
                            .buttonStyle(.glass)
                            .controlSize(.small)
                    }
                }
                .font(.caption)
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
            Text("Loading stats…").font(.caption).glassChip()
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
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Opponent's replies").font(.headline)
                Spacer()
                Text("Seen").font(.caption).foregroundStyle(.secondary).frame(width: 74, alignment: .trailing)
                Text("Covered").font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
            }
            .padding(.vertical, 8)
            if let replies = info?.replies, !replies.isEmpty {
                ForEach(replies, id: \.uci) { reply in
                    Divider()
                    ReplyRow(reply: reply, model: model)
                }
            } else {
                ForEach(node.children, id: \.self) { child in
                    if let move = model.tree[child]?.move {
                        Divider()
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
                    }
                }
                StatsUnavailableNote()
            }
        }
    }
}

struct ReplyRow: View {
    let reply: ReplyInfo
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
                }
                .opacity(reply.required || inRepertoire ? 1 : 0.55)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if reply.child == nil {
                Button("Add \(reply.san)", systemImage: "plus.circle.fill") { model.add(uci: reply.uci) }
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(isGap ? .orange : .secondary)
            } else {
                Image(systemName: "chevron.right").foregroundStyle(.tertiary).frame(width: 22)
            }
        }
        .padding(.vertical, 9)
    }
}

/// Your move: your saved moves and explorer candidates with results and cloud eval.
struct YourMovePanel: View {
    let model: BuilderModel
    let node: RepertoireNode
    @State private var eval: CloudEvalClient.Eval?

    var body: some View {
        let document = model.document
        VStack(alignment: .leading, spacing: 0) {
            if !node.children.isEmpty {
                Text("Your moves").font(.headline).padding(.vertical, 8)
                ForEach(Array(node.children.enumerated()), id: \.element) { index, child in
                    if let childNode = model.tree[child], let move = childNode.move {
                        Divider()
                        Button { model.go(to: child) } label: {
                            HStack(alignment: .firstTextBaseline) {
                                Text(move.san).font(.body.weight(.semibold)).frame(minWidth: 48, alignment: .leading)
                                if index == 0 && node.children.count > 1 {
                                    Text("Main").font(.caption2).glassChip(tint: .green)
                                } else if index > 0 {
                                    Text("Alternative · not trained").font(.caption2).foregroundStyle(.secondary)
                                }
                                Text(childNode.note.isEmpty ? "" : childNode.note)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if index > 0 { Button("Make Main Move", systemImage: "arrow.up.to.line") { document.promote(child) } }
                            Button("Delete", systemImage: "trash", role: .destructive) { model.delete(child) }
                        }
                    }
                }
            } else {
                Label("Choose your move: play it on the board or pick a candidate.", systemImage: "hand.point.up.left")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.vertical, 8)
            }

            Text("Candidates").font(.headline).padding(.top, 16).padding(.bottom, 8)
            if let stats = document.stats(node.epd), !stats.moves.isEmpty {
                ForEach(stats.moves.prefix(12), id: \.uci) { move in
                    Divider()
                    CandidateRow(move: move, total: stats.total, eval: evalText(for: move.uci),
                                 inRepertoire: model.tree.child(of: node.id, uci: move.uci) != nil, model: model)
                }
            } else {
                StatsUnavailableNote()
            }
        }
        .task(id: node.epd) {
            eval = nil
            eval = await CloudEvalClient.fetch(node.epd)
        }
    }

    private func evalText(for uci: String) -> String? {
        guard let pv = eval?.pvs.first(where: { $0.moves.hasPrefix(uci) }) else { return nil }
        if let mate = pv.mate { return "#\(mate)" }
        guard let cp = pv.cp else { return nil }
        return String(format: "%+.1f", Double(cp) / 100)
    }
}

struct CandidateRow: View {
    let move: ExplorerMove
    let total: Int
    let eval: String?
    let inRepertoire: Bool
    let model: BuilderModel

    var body: some View {
        HStack(spacing: 10) {
            Button { model.preview(uci: move.uci) } label: {
                HStack(spacing: 8) {
                    Text(move.san).font(.body.weight(.semibold)).frame(minWidth: 48, alignment: .leading)
                    Text(Format.percent(total > 0 ? Double(move.games) / Double(total) : 0))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                    Text(eval ?? "")
                        .font(.caption.monospacedDigit().weight(.semibold)).frame(width: 40)
                    ScoreBar(white: move.white, draws: move.draws, black: move.black)
                    Text(Format.games(move.games)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if inRepertoire {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
                    .accessibilityLabel("In repertoire")
            } else {
                Button("Add \(move.san)", systemImage: "plus.circle") { model.add(uci: move.uci) }
                    .labelStyle(.iconOnly)
                    .font(.title3)
            }
        }
        .padding(.vertical, 8)
    }
}

/// Shown while a draft is on the board.
struct DraftPanel: View {
    let model: BuilderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("New line").font(.headline)
            Text("Keep playing moves for both sides, then save. Moves are added to the repertoire and the PGN right away.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let stats = model.document.stats(model.position.epd) {
                let maxGames = stats.moves.first?.games ?? 1
                Text(model.isUserTurnOnBoard ? "Popular moves for you" : "Popular replies")
                    .font(.subheadline.weight(.semibold)).padding(.top, 6)
                ForEach(stats.moves.prefix(6), id: \.uci) { move in
                    Button { model.play(uci: move.uci) } label: {
                        HStack {
                            Text(move.san).fontWeight(.semibold).frame(width: 60, alignment: .leading)
                            CompletionBar(value: Double(move.games) / Double(max(maxGames, 1)), tint: .accentColor.opacity(0.6))
                            Text(Format.percent(Double(move.games) / Double(max(stats.total, 1))))
                                .font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(.top, 4)
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
