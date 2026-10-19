import OpeningCore
import SwiftUI

/// Anki's deck overview for one repertoire: building progress, today's counts with Study Now
/// and Options, and a short version of its statistics.
struct RepertoireOverviewView: View {
    @Environment(AppModel.self) private var app
    let document: RepertoireDocument
    let editLines: () -> Void
    let study: () -> Void
    let practice: () -> Void
    @State private var sheet: Sheet?
    @State private var graphs: GraphsContext?

    private enum Sheet: String, Identifiable {
        case settings, options
        var id: Self { self }
    }

    var body: some View {
        let stats = EntryStats(document: document)
        List {
            buildSection(stats)
            studySection(stats)
            statisticsSection(stats)
        }
        .navigationTitle(document.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Repertoire Settings", systemImage: "gearshape") { sheet = .settings }
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .settings: RepertoireSettingsSheet(document: document)
            case .options: StudyOptionsSheet(document: document)
            }
        }
        .task(id: document.revision) {
            graphs = GraphsContext(cards: Array(document.sidecar.studyCards.values), newCount: 0,
                                   revlog: document.reviewLog(), timing: SchedTiming())
        }
    }

    // MARK: Build

    private func buildSection(_ stats: EntryStats) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(Format.percent(stats.completion)) complete").font(.headline.monospacedDigit())
                CompletionBar(value: stats.completion, tint: .green)
            }
            LabeledContent("Saved moves", value: stats.savedMoves.formatted())
            if stats.gaps > 0 {
                LabeledContent {
                    Text(stats.gaps.formatted()).foregroundStyle(.orange)
                } label: {
                    Text("Gaps").foregroundStyle(.orange)
                }
            }
            Button(action: editLines) {
                Text("Browse / Edit").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
        }
    }

    // MARK: Study

    private func studySection(_ stats: EntryStats) -> some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                Text("Study").font(.headline)
                Spacer()
                Button("Options", systemImage: "slider.horizontal.3") { sheet = .options }
                    .font(.subheadline)
                    .buttonStyle(.borderless)
            }
            if stats.counts.total > 0 {
                countRow("New", stats.counts.new, StudyColors.new)
                countRow("Learning", stats.counts.learning, StudyColors.learning)
                countRow("To Review", stats.counts.review, StudyColors.review)
                Button(action: study) {
                    Text("Study Now").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
            } else {
                Label(doneText(stats), systemImage: stats.progress.studied > 0 ? "checkmark.circle.fill" : "checkmark.circle")
                    .foregroundStyle(stats.progress.studied > 0 ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                // Done for today: Study More Today takes Study Now's place.
                if stats.progress.cards > 0 {
                    studyMoreMenu(stats)
                }
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
            Text("Study More Today").frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
    }

    private func doneText(_ stats: EntryStats) -> String {
        if stats.progress.cards == 0 { return "Add moves of yours to study them." }
        guard let next = document.sidecar.nextDue(timing: SchedTiming()) else { return "Done for today." }
        if Calendar.current.isDateInToday(next) {
            return "Done for now. More moves are due at \(next.formatted(date: .omitted, time: .shortened))."
        }
        return "Done for today. Next review \(next.formatted(.relative(presentation: .named)))."
    }

    private func countRow(_ title: String, _ value: Int, _ color: Color) -> some View {
        LabeledContent(title) {
            Text(value.formatted())
                .foregroundStyle(value > 0 ? color : .secondary)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
    }

    // MARK: Statistics

    private func statisticsSection(_ stats: EntryStats) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Statistics").font(.headline)
                    Spacer()
                    Text("\(stats.progress.cards.formatted()) trainable").font(.footnote).foregroundStyle(.secondary)
                }
                StudiedBar(progress: stats.progress)
            }
            groupRow("Not studied", stats.progress.notStudied, Color(.quaternaryLabel))
            groupRow("Learning", stats.progress.learning, StudyColors.learningGroup)
            groupRow("Young", stats.progress.young, StudyColors.young)
            groupRow("Mature", stats.progress.mature, StudyColors.mature)
            if stats.progress.suspended > 0 {
                groupRow("Suspended", stats.progress.suspended, StudyColors.suspended)
            }
            if let graphs {
                let today = graphs.today()
                LabeledContent("Today", value: today.answerCount == 0 ? "Not studied"
                               : "\(today.answerCount) \(today.answerCount == 1 ? "move" : "moves") · \(Int((Double(today.answerMillis) / 60_000).rounded())) min")
                if let retention = graphs.trueRetention()[.month]?.total {
                    LabeledContent("True retention (month)", value: Format.percent(retention))
                }
            }
            Button("Show More", systemImage: "chart.bar") {
                app.statisticsScope = .repertoire(document.entryID)
                app.selectedTab = .statistics
            }
        } footer: {
            if stats.progress.suspended > 0 {
                Text("Suspended: your moves below alternative moves. They keep their progress and are studied again if their line becomes the main line.")
            }
        }
    }

    private func groupRow(_ title: String, _ value: Int, _ color: Color) -> some View {
        LabeledContent {
            Text(value.formatted()).monospacedDigit()
        } label: {
            Label {
                Text(title)
            } icon: {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            }
        }
    }
}
