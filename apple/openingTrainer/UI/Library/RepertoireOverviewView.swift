import OpeningCoreRust
import SwiftUI

/// Anki's deck overview for one repertoire: coverage and study progress and what is due
/// today, each section ending with its action (Browse / Edit, Study): the same buttons, the
/// most likely one prominent, building while there are gaps, else studying. Its history is in Statistics (beside it in the split view).
struct RepertoireOverviewView: View {
    @Environment(AppModel.self) private var app
    /// Set in the split view (iPad, Mac), whose board column shows this repertoire's statistics.
    @Environment(\.inSplitView) private var inSplitView
    let document: RepertoireDocument
    let editLines: () -> Void
    let study: () -> Void
    let practice: () -> Void
    @State private var sheet: Sheet?

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
        .checksCoverage(document)
        .navigationTitle(document.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Repertoire", systemImage: "gearshape") {
                    Button("Repertoire Settings…", systemImage: "gearshape") { sheet = .settings }
                    Button("Study Options…", systemImage: "slider.horizontal.3") { sheet = .options }
                }
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
                            .foregroundStyle(.attention)
                    }
                }
                CoverageBar(value: stats.completion)
                CoverageCheckStatus(document: document)
            }
            LabeledContent("Saved moves", value: stats.savedMoves.formatted())
            Button("Browse / Edit", action: editLines).actionButton(prominent: buildFirst(stats))
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
                    legend(stats.progress.learning, "learning", ThemeColor.wrong.opacity(0.5))
                    legend(stats.progress.young, "young", ThemeColor.done.opacity(0.5))
                    legend(stats.progress.mature, "mature", ThemeColor.done)
                    if stats.progress.suspended > 0 {
                        legend(stats.progress.suspended, "suspended", ThemeColor.inactive)
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
                    .foregroundStyle(stats.progress.studied > 0 ? AnyShapeStyle(.done) : AnyShapeStyle(.secondary))
            }
            if stats.progress.cards > 0 {
                studyButton(stats).actionButton(prominent: !buildFirst(stats))
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
            Text("Study")
        }
    }

    private func legend(_ value: Int64, _ label: String, _ color: ThemeColor) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(value.formatted()) \(label)").foregroundStyle(.secondary)
        }
    }

    /// Only the counts above zero, in Anki's colors.
    @ViewBuilder
    private func dueCounts(_ counts: Counts) -> some View {
        if counts.new > 0 { due(counts.new, "new", ThemeColor.new) }
        if counts.learning > 0 { due(counts.learning, "learning", ThemeColor.wrong) }
        if counts.review > 0 { due(counts.review, "review", ThemeColor.done) }
    }

    private func due(_ value: Int64, _ label: String, _ color: ThemeColor) -> some View {
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

    /// Study Now while moves are due, Study More Today once done for today.
    @ViewBuilder
    private func studyButton(_ stats: EntryStats) -> some View {
        if stats.counts.total > 0 {
            Button("Study Now", action: study)
        } else {
            studyMoreMenu(stats)
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
