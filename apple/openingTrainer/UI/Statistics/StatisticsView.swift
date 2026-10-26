import Charts
import OpeningCoreRust
import SwiftUI

/// The Statistics tab: a summary, after Apple's Health and Fitness. Each card answers one
/// question with one number and a small chart, and opens Anki's full graph for it:
/// today (studied against still due), how well you know the repertoire (expected recall),
/// the streak (calendar), reviews over time, what is coming (future due), how much you
/// remember (true retention), where your moves stand (move counts), the moves to work on
/// (weakest moves) and the memory model (FSRS's retrievability, stability, difficulty).
struct StatisticsView: View {
    @Environment(AppModel.self) private var app
    @State private var model = StatisticsModel()

    var body: some View {
        NavigationStack {
            StatisticsSummary(model: model)
                .navigationTitle("Statistics")
                .navigationSubtitle(scopeTitle)
                .toolbar {
                    ToolbarItem(placement: .trailingBar) { filterMenu }
                }
                .task(id: TaskKey(scope: model.scope, entries: app.library.entries.count)) {
                    await model.load(app)
                }
                .refreshable { await model.load(app) }
                .onChange(of: app.statisticsScope, initial: true) { model.scope = app.statisticsScope }
                .onChange(of: model.scope) { app.statisticsScope = model.scope }
        }
    }

    private struct TaskKey: Hashable {
        let scope: StatisticsModel.Scope
        let entries: Int
    }

    /// The repertoire, in the toolbar as iOS 26 apps do; the icon is filled while filtering.
    private var filterMenu: some View {
        Menu {
            Picker("Repertoire", selection: $model.scope) {
                Text("All Repertoires").tag(StatisticsModel.Scope.all)
                ForEach(app.library.entries.filter { !$0.needsSetup }) { entry in
                    Text(entry.name).tag(StatisticsModel.Scope.repertoire(entry.id))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Filter", systemImage: model.scope == .all ? "line.3.horizontal.decrease.circle"
                                                             : "line.3.horizontal.decrease.circle.fill")
        }
    }

    private var scopeTitle: String {
        switch model.scope {
        case .all: "All Repertoires"
        case .repertoire(let id): app.library.entry(id: id)?.name ?? "Repertoire"
        }
    }
}

/// The Statistics screen's content for one scope, beside an overview (iPad, Mac): the same
/// summary with the repertoire filter set to what the overview shows.
struct InlineStatistics: View {
    @Environment(AppModel.self) private var app
    @State private var model = StatisticsModel()
    let scope: StatisticsModel.Scope

    var body: some View {
        StatisticsSummary(model: model)
            .task(id: scope) {
                model.scope = scope
                await model.load(app)
            }
            .refreshable { await model.load(app) }
    }
}

/// The summary cards, one section each.
struct StatisticsSummary: View {
    let model: StatisticsModel

    var body: some View {
        if let graphs = model.graphs, graphs.cardCounts().total > 0 || graphs.reviewsSummary(range: .all).answers > 0 {
            List {
                Section { TodaySummary(graphs: graphs, dueLeft: model.dueLeft) }
                if let recall = model.expectedRecall {
                    Section { ExpectedRecallSummary(recall: recall, counts: graphs.cardCounts()) }
                }
                Section {
                    NavigationLink { CalendarDetail(graphs: graphs) } label: { StreakSummary(graphs: graphs) }
                }
                Section {
                    NavigationLink { ReviewsDetail(graphs: graphs) } label: { ReviewsSummaryCard(graphs: graphs) }
                }
                Section {
                    NavigationLink { UpcomingDetail(graphs: graphs) } label: { UpcomingSummary(graphs: graphs) }
                }
                Section {
                    NavigationLink { RetentionDetail(model: model, graphs: graphs) } label: { RetentionSummary(graphs: graphs) }
                }
                Section {
                    NavigationLink { MovesDetail(graphs: graphs) } label: { MovesSummary(graphs: graphs) }
                }
                if model.document != nil { WeakestMovesSection(model: model) }
                Section {
                    NavigationLink { MemoryDetail(graphs: graphs) } label: { MemorySummary(graphs: graphs) }
                }
            }
        } else if model.graphs == nil {
            ProgressView()
        } else {
            ContentUnavailableView("No Statistics Yet", systemImage: "chart.bar",
                                   description: Text("Study a repertoire to see your progress here."))
        }
    }
}

// MARK: Cards

/// Fitness's rings card: the moves studied today against those still due, then time and
/// correct answers.
private struct TodaySummary: View {
    let graphs: Graphs
    let dueLeft: Int

    var body: some View {
        let today = graphs.today()
        let done = Int(today.cardCount)
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "Today", systemImage: "checkmark.circle.fill", color: .learned,
                       trailing: dueLeft == 0 && done > 0 ? "All done" : nil)
            HStack(spacing: 20) {
                Gauge(value: Double(done), in: 0...Double(max(done + dueLeft, 1))) {
                    Text("Studied")
                } currentValueLabel: {
                    Text(done.formatted()).fontDesign(.rounded)
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(ThemeColor.learned)
                .accessibilityLabel("Studied \(done) of \(done + dueLeft) moves due today")
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                    GridRow {
                        Metric(title: "Studied", value: done.formatted(), unit: "of \((done + dueLeft).formatted())")
                        Metric(title: "Time", value: today.answerCount > 0 ? durationText(millis: Int(today.answerMillis)) : "—")
                    }
                    GridRow {
                        Metric(title: "Correct", value: today.answerCount > 0
                               ? percent(Double(today.correctCount) / Double(today.answerCount)) : "—")
                        Metric(title: "Answers", value: today.answerCount.formatted())
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ExpectedRecallSummary: View {
    let recall: Double
    let counts: CardCounts

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(title: "Expected Recall", systemImage: "brain", color: .learned)
            StatValue(value: percent(recall), unit: "in your games")
            Gauge(value: recall) { Text("Expected recall") }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(ThemeColor.learned)
                .labelsHidden()
            Text("The chance you know your move in the positions you will meet, weighted by how often they come up. Moves not studied yet count as forgotten.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

/// The streak and the last seven days, ticked when studied (Fitness's week of rings).
private struct StreakSummary: View {
    let graphs: Graphs

    var body: some View {
        let streak = graphs.streak()
        let counts = graphs.reviews().count.intKeys
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(title: "Streak", systemImage: "flame.fill", color: .todo,
                       trailing: streak.longest > 0 ? "Longest \(streak.longest.formatted())" : nil)
            StatValue(value: streak.current.formatted(), unit: streak.current == 1 ? "day" : "days")
            HStack {
                ForEach(-6...0, id: \.self) { day in
                    let studied = (counts[day]?.total ?? 0) > 0
                    VStack(spacing: 4) {
                        Text(StatDay.date(day).formatted(.dateTime.weekday(.narrow)))
                            .font(.caption2.weight(day == 0 ? .bold : .regular))
                            .foregroundStyle(day == 0 ? .primary : .secondary)
                        Image(systemName: studied ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(studied ? AnyShapeStyle(.todo) : AnyShapeStyle(.quaternary))
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(StatDay.title(StatDay.date(day), .day)): \(studied ? "studied" : "not studied")")
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// The daily average of the last seven days, and their bars.
private struct ReviewsSummaryCard: View {
    let graphs: Graphs

    var body: some View {
        let summary = graphs.reviewsSummary(range: .week)
        let counts = graphs.reviews().count.intKeys
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(title: "Reviews", systemImage: "chart.bar.fill", trailing: GraphRange.week.periodTitle)
            StatValue(value: (Double(summary.answers) / Double(max(summary.periodDays, 1))).formatted(.number.precision(.fractionLength(0))),
                      unit: "answers a day")
            Chart(-6...0, id: \.self) { day in
                BarMark(x: .value("Day", StatDay.date(day), unit: .day),
                        y: .value("Answers", counts[day]?.total ?? 0))
                    .foregroundStyle(.tint)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true) }
            }
            .chartYAxis(.hidden)
            .frame(height: 70)
            .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
    }
}

/// Tomorrow's moves, and the next seven days' bars (overdue moves count as due today).
private struct UpcomingSummary: View {
    let graphs: Graphs

    var body: some View {
        let summary = graphs.futureDueSummary(range: .week)
        let due = graphs.futureDue().dueByDay.ints
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(title: "Upcoming", systemImage: "calendar", trailing: GraphRange.week.nextTitle)
            StatValue(value: summary.dueTomorrow.formatted(), unit: "due tomorrow")
            Chart {
                ForEach(0...6, id: \.self) { day in
                    BarMark(x: .value("Day", StatDay.date(day), unit: .day), y: .value("Moves", due[day] ?? 0))
                        .foregroundStyle(.tint)
                }
                BarMark(x: .value("Day", StatDay.date(0), unit: .day), y: .value("Moves", summary.overdue))
                    .foregroundStyle(.wrong)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true) }
            }
            .chartYAxis(.hidden)
            .frame(height: 70)
            .accessibilityHidden(true)
            if summary.overdue > 0 {
                Label("\(movesText(Int(summary.overdue))) overdue", systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.wrong)
            }
        }
        .padding(.vertical, 4)
    }
}

/// True retention over the last month.
private struct RetentionSummary: View {
    let graphs: Graphs

    var body: some View {
        let month = graphs.retentionTable()[.month] ?? TrueRetention()
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(title: "Retention", systemImage: "checkmark.seal.fill", color: .correct,
                       trailing: RetentionPeriod.month.title)
            if month.count > 0 {
                StatValue(value: percent(month.total), unit: "remembered")
                HStack(spacing: 20) {
                    Metric(title: "Young", value: percent(month.young))
                    Metric(title: "Mature", value: percent(month.mature))
                    Metric(title: "Reviews", value: month.count.formatted())
                }
            } else {
                Text("Moves you review a day or more after learning them show here.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Where the moves stand: learned (young and mature) of all, and the studied bar.
private struct MovesSummary: View {
    let graphs: Graphs

    var body: some View {
        let c = graphs.cardCounts()
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(title: "Moves", systemImage: "square.stack.3d.up.fill", color: .learned,
                       trailing: movesText(Int(c.total)))
            StatValue(value: Int(c.young + c.mature).formatted(), unit: "learned")
            MoveGroupsBar(counts: c)
            FlowLayout(spacing: 12) {
                ForEach(MoveGroup.allCases.filter { $0.count(c) > 0 }, id: \.self) { group in
                    LegendItem(name: group.title, color: group.color, value: group.count(c).formatted())
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// The three weakest moves, each opening Browse at it, then all of them.
private struct WeakestMovesSection: View {
    let model: StatisticsModel

    var body: some View {
        let moves = model.weakestMoves(limit: 3)
        Section {
            CardHeader(title: "Weakest Moves", systemImage: "exclamationmark.triangle.fill", color: .wrong)
            if moves.isEmpty {
                Text("Nothing forgotten yet.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(moves) { WeakMoveRow(model: model, move: $0) }
                NavigationLink("Show All") { WeakestMovesDetail(model: model) }
            }
        }
    }
}

/// FSRS's average recall now and its estimate of what you know.
private struct MemorySummary: View {
    let graphs: Graphs

    var body: some View {
        let r = graphs.retrievability()
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(title: "Memory", systemImage: "brain.head.profile")
            if r.bins.isEmpty {
                Text("How likely you are to recall each move, once you have studied some.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                StatValue(value: percent(r.average / 100), unit: "average recall")
                Text("You would recall about \(movesText(Int(r.sum.rounded()))) right now.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
