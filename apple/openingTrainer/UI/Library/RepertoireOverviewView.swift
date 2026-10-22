import OpeningCoreRust
import SwiftUI

/// Anki's deck overview for one repertoire: coverage progress, today's counts and Options,
/// and a short version of its statistics. The study action is pinned at the bottom (iOS 26).
struct RepertoireOverviewView: View {
    @Environment(AppModel.self) private var app
    /// Set in the split view (iPad, Mac), whose board column shows this repertoire's statistics.
    @Environment(\.inSplitView) private var inSplitView
    let document: RepertoireDocument
    let editLines: () -> Void
    let study: () -> Void
    let practice: () -> Void
    @State private var sheet: Sheet?
    @State private var graphs: Graphs?

    private enum Sheet: String, Identifiable {
        case settings, options
        var id: Self { self }
    }

    var body: some View {
        let stats = EntryStats(document: document)
        List {
            coverageSection(stats)
            studySection(stats)
        }
        .safeAreaBar(edge: .bottom) {
            // A phone's actions are at the bottom; in the split view in their sections.
            if !inSplitView { studyBar(stats) }
        }
        .checksCoverage(document)
        // A detail screen with its own actions at the bottom, like the study screen.
        .hidesTabBar()
        .navigationTitle(document.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Repertoire Settings", systemImage: "gearshape") { sheet = .settings }
            }
        }
        .sheet(item: $sheet) { sheet in
            Group {
                switch sheet {
                case .settings: RepertoireSettingsSheet(document: document)
                case .options: StudyOptionsSheet(document: document)
                }
            }
            .presentationSizing(.form)
        }
        .task(id: document.revision) {
            let revlog = await document.reviewLog()
            graphs = Graphs(cards: Array(document.sidecar.studyCards.values), newCount: 0, suspendedNewCount: 0,
                            revlog: revlog, timing: SchedTiming(),
                            localOffsetSecs: Int64(TimeZone.current.secondsFromGMT()))
        }
    }

    // MARK: Coverage

    private func coverageSection(_ stats: EntryStats) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(Format.percent(stats.completion)) complete").font(.headline.monospacedDigit())
                    Spacer()
                    if stats.gaps > 0 {
                        Text(stats.gaps == 1 ? "1 gap" : "\(stats.gaps.formatted()) gaps")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.orange)
                    }
                }
                CompletionBar(value: stats.completion, tint: .green)
                CoverageCheckStatus(document: document)
            }
            LabeledContent("Saved moves", value: stats.savedMoves.formatted())
            if inSplitView {
                Button("Browse / Edit", action: editLines)
                    .modifier(ActionButtonStyle(prominent: buildFirst(stats)))
            }
        } header: {
            Text("Coverage")
        }
    }

    // MARK: Study

    private func studySection(_ stats: EntryStats) -> some View {
        Section {
            // Like Coverage: how far along, then the numbers.
            VStack(alignment: .leading, spacing: 8) {
                Text("\(stats.progress.studied.formatted()) of \(stats.progress.cards.formatted()) moves studied")
                    .font(.headline.monospacedDigit())
                StudiedBar(progress: stats.progress)
                FlowLayout {
                    legend(stats.progress.learning, "learning", StudyColors.learningGroup)
                    legend(stats.progress.young, "young", StudyColors.young)
                    legend(stats.progress.mature, "mature", StudyColors.mature)
                    if stats.progress.suspended > 0 {
                        legend(stats.progress.suspended, "suspended", StudyColors.suspended)
                    }
                }
                .font(.caption)
            }
            if stats.counts.total > 0 {
                // One line when it fits, else the counts below the label (narrow or large text).
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Text("Due today")
                        Spacer(minLength: 12)
                        HStack(spacing: 10) { dueCounts(stats.counts) }.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Due today")
                        FlowLayout(spacing: 10) { dueCounts(stats.counts) }
                    }
                }
            } else {
                Label(doneText(stats), systemImage: stats.progress.studied > 0 ? "checkmark.circle.fill" : "checkmark.circle")
                    .foregroundStyle(stats.progress.studied > 0 ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
            }
            if let graphs {
                let today = graphs.today()
                LabeledContent("Today", value: today.answerCount == 0 ? "Not studied"
                               : "\(today.answerCount) \(today.answerCount == 1 ? "move" : "moves") · \(Int((Double(today.answerMillis) / 60_000).rounded())) min")
                if let retention = graphs.retentionTable()[.month]?.total {
                    LabeledContent("True retention (month)", value: Format.percent(retention))
                }
            }
            if inSplitView && stats.progress.cards > 0 {
                studyButton(stats, prominent: !buildFirst(stats))
            }
            // The split view shows the statistics beside the overview.
            if !inSplitView {
                Button {
                    app.statisticsScope = .repertoire(document.entryID)
                    app.selectedTab = .statistics
                } label: {
                    HStack {
                        Label("Statistics", systemImage: "chart.bar")
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .tint(.primary)
            }
        } header: {
            HStack {
                Text("Study")
                Spacer()
                Button("Options", systemImage: "slider.horizontal.3") { sheet = .options }
            }
        }
    }

    private func legend(_ value: Int64, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(value.formatted()) \(label)").foregroundStyle(.secondary)
        }
    }

    /// Only the counts above zero, in Anki's colors.
    @ViewBuilder
    private func dueCounts(_ counts: Counts) -> some View {
        if counts.new > 0 { due(counts.new, "new", StudyColors.new) }
        if counts.learning > 0 { due(counts.learning, "learning", StudyColors.learning) }
        if counts.review > 0 { due(counts.review, "review", StudyColors.review) }
    }

    private func due(_ value: Int64, _ label: String, _ color: Color) -> some View {
        Text("\(value.formatted()) \(label)")
            .foregroundStyle(color)
            .fontWeight(.semibold)
            .monospacedDigit()
            .fixedSize()
    }

    /// While there are gaps (or nothing of yours to study), building is the main action.
    private func buildFirst(_ stats: EntryStats) -> Bool {
        stats.gaps > 0 || stats.progress.cards == 0
    }

    /// The actions on a phone, pinned at the bottom, the main one first: Browse / Edit while
    /// there are gaps (or nothing of yours to study), else studying (Study Now while moves are
    /// due, Study More Today once done for today).
    private func studyBar(_ stats: EntryStats) -> some View {
        let buildFirst = self.buildFirst(stats)
        return VStack(spacing: 12) {
            if stats.progress.cards > 0 {
                if !buildFirst { studyButton(stats, prominent: true) }
                Button("Browse / Edit", action: editLines)
                    .modifier(ActionButtonStyle(prominent: buildFirst))
                if buildFirst { studyButton(stats, prominent: false) }
            } else {
                Button("Browse / Edit", action: editLines).buttonStyle(.glassProminent)
            }
        }
        .controlSize(.extraLarge)
        .buttonSizing(.flexible)
        .padding()
    }

    @ViewBuilder
    private func studyButton(_ stats: EntryStats, prominent: Bool) -> some View {
        if stats.counts.total > 0 {
            Button("Study Now", action: study).modifier(ActionButtonStyle(prominent: prominent))
        } else {
            studyMoreMenu(stats).modifier(ActionButtonStyle(prominent: prominent))
        }
    }

    /// Glass in the phone's bottom bar; the standard styles in the content (split view).
    private struct ActionButtonStyle: ViewModifier {
        @Environment(\.inSplitView) private var inSplitView
        let prominent: Bool
        func body(content: Content) -> some View {
            if inSplitView {
                if prominent { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
            } else {
                if prominent { content.buttonStyle(.glassProminent) } else { content.buttonStyle(.glass) }
            }
        }
    }

    /// Anki's custom study: raise today's limits, or practice every learned move. Only today
    /// changes; the repertoire's limits stay as they are.
    private func studyMoreMenu(_ stats: EntryStats) -> some View {
        let extraReviews = document.reviewsBeyondLimit()
        return Menu {
            if stats.progress.notStudied > 0 {
                Section("\(stats.progress.notStudied) new moves not studied yet") {
                    ForEach([5, 10, 20], id: \.self) { n in
                        Button("Learn \(n) More New Moves", systemImage: "sparkles") {
                            document.extendNewLimitToday(by: n)
                            study()
                        }
                    }
                }
            }
            if extraReviews > 0 {
                Button("Review \(extraReviews) More Moves", systemImage: "arrow.clockwise") {
                    document.extendReviewLimitToday(by: extraReviews)
                    study()
                }
            }
            if stats.progress.studied > 0 {
                Button("Practice the Whole Repertoire", systemImage: "arrow.trianglehead.2.clockwise", action: practice)
            }
        } label: {
            Text("Study More Today")
        }
    }

    private func doneText(_ stats: EntryStats) -> String {
        if stats.progress.cards == 0 { return "Add moves of yours to study them." }
        guard let next = document.sidecar.nextDue(timing: SchedTiming()) else { return "Done for today." }
        if Calendar.current.isDateInToday(next) {
            return "Done for now. More moves are due at \(next.formatted(date: .omitted, time: .shortened))."
        }
        return "Done for today. Next review \(next.formatted(.relative(presentation: .named)))."
    }
}
