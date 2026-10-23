import Charts
import OpeningCoreRust
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Anki's statistics (Today, Future Due, Calendar, Reviews, Card Counts, Intervals,
/// Difficulty, Stability, Retrievability, Hourly Breakdown, Answer Buttons, True Retention),
/// then statistics that use the repertoire: expected recall in games, weakest moves and
/// retention per opening branch.
struct StatisticsView: View {
    @Environment(AppModel.self) private var app
    @State private var model = StatisticsModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                StatisticsCards(model: model)
                    .scenePadding()
            }
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

/// The Statistics screen's content for one scope, inline under an overview (iPad, Mac): the
/// same cards with the repertoire filter set to what the overview shows.
struct InlineStatistics: View {
    @Environment(AppModel.self) private var app
    @State private var model = StatisticsModel()
    let scope: StatisticsModel.Scope

    var body: some View {
        StatisticsCards(model: model)
            .task(id: scope) {
                model.scope = scope
                await model.load(app)
            }
    }
}

/// The period, then every card for the model's scope.
struct StatisticsCards: View {
    @Bindable var model: StatisticsModel

    var body: some View {
        VStack(spacing: 16) {
            filters
            if let graphs = model.graphs {
                if model.document != nil { ExpectedRecallCard(model: model, graphs: graphs) }
                TodayCard(graphs: graphs)
                FutureDueCard(graphs: graphs)
                CalendarCard(graphs: graphs)
                ReviewsCard(graphs: graphs, range: model.range)
                CardCountsCard(graphs: graphs)
                HistogramCard(title: "Review Intervals", unit: "days", values: graphs.intervals().ints,
                              footer: "The delay until each move is shown again.")
                HistogramCard(title: "Difficulty", unit: "%", values: graphs.difficulty().ints, maxBin: 100,
                              footer: "How hard each move is to remember (FSRS).")
                HistogramCard(title: "Stability", unit: "days", values: graphs.stability().ints,
                              footer: "How long until recall drops to 90% (FSRS).")
                RetrievabilityCard(graphs: graphs)
                HourlyCard(graphs: graphs, range: model.range)
                AnswerButtonsCard(graphs: graphs, range: model.range)
                TrueRetentionCard(graphs: graphs)
                if model.document != nil {
                    WeakestMovesCard(model: model)
                    BranchRetentionCard(model: model)
                }
            } else if model.isLoading {
                ProgressView().padding(.top, 60)
            } else {
                ContentUnavailableView("No statistics yet", systemImage: "chart.bar",
                                       description: Text("Study a repertoire to see statistics."))
            }
        }
    }

    /// The period stays in the content; which repertoire is in the toolbar (or the overview).
    private var filters: some View {
        Picker("Period", selection: $model.range) {
            ForEach(GraphRange.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
    }
}

// MARK: Cards

struct StatCard<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background.secondary, in: .rect(cornerRadius: 16))
    }
}

private func percent(_ value: Double?) -> String {
    value.map { $0.formatted(.percent.precision(.fractionLength(1))) } ?? "—"
}

private func moves(_ n: Int) -> String { n == 1 ? "1 move" : "\(n.formatted()) moves" }
private func moves(_ n: Int64) -> String { moves(Int(n)) }

private func duration(_ millis: Int64) -> String { duration(Int(millis)) }

private func duration(_ millis: Int) -> String {
    let secs = Double(millis) / 1000
    if secs < 90 { return "\(Int(secs.rounded())) seconds" }
    return "\(Int((secs / 60).rounded())) minutes"
}

private struct ExpectedRecallCard: View {
    let model: StatisticsModel
    let graphs: Graphs

    var body: some View {
        StatCard(title: "Expected Recall in Games",
                 subtitle: "Chance you know your move in the positions you will meet, weighted by how often they come up.") {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(percent(model.expectedRecall)).font(.system(size: 44, weight: .bold, design: .rounded))
                VStack(alignment: .leading) {
                    let counts = graphs.cardCounts()
                    Text("\(counts.total - Int(counts.new)) of \(counts.total) moves studied")
                    Text("\(counts.mature) mature").foregroundStyle(.secondary)
                }
                .font(.footnote)
            }
        }
    }
}

private struct TodayCard: View {
    let graphs: Graphs

    var body: some View {
        let today = graphs.today()
        StatCard(title: "Today") {
            if today.answerCount == 0 {
                Text("No moves have been studied today.").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Studied \(moves(today.answerCount)) in \(duration(today.answerMillis)) today (\(String(format: "%.1f", Double(today.answerMillis) / 1000 / Double(today.answerCount)))s/move).")
                    let again = today.answerCount - today.correctCount
                    Text("Again count: \(again) (\(percent(Double(again) / Double(today.answerCount))))")
                    Text("Learn: \(today.learnCount), Review: \(today.reviewCount), Relearn: \(today.relearnCount), Filtered: \(today.earlyReviewCount)")
                    if today.matureCount > 0 {
                        Text("Correct answers on mature moves: \(today.matureCorrect)/\(today.matureCount) (\(percent(Double(today.matureCorrect) / Double(today.matureCount))))")
                    } else {
                        Text("No mature moves were studied today.").foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
            }
        }
    }
}

private struct FutureDueCard: View {
    let graphs: Graphs
    @State private var selected: Int?

    var body: some View {
        let due = graphs.futureDue()
        let dueByDay = due.dueByDay.ints
        let days = 30
        let overdue = dueByDay.filter { $0.key < 0 }.values.reduce(0, +)
        let bars = (0..<days).map { ($0, dueByDay[$0] ?? 0) } + (overdue > 0 ? [(-1, overdue)] : [])
        let total = bars.reduce(0) { $0 + $1.1 }
        StatCard(title: "Future Due", subtitle: "Moves due in the next 30 days\(overdue > 0 ? "; the bar left of today is overdue" : "").") {
            Chart(bars, id: \.0) { day, count in
                BarMark(x: .value("Day", day), y: .value("Moves", count))
                    .foregroundStyle(day < 0 ? AnyShapeStyle(.wrong) : AnyShapeStyle(.tint))
                    .cornerRadius(4)
                if let selected, selected == day {
                    RuleMark(x: .value("Day", day))
                        .foregroundStyle(.secondary.opacity(0.3))
                        .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                            Tooltip(title: day < 0 ? "Overdue" : day == 0 ? "Today" : "In \(day) days", value: moves(count))
                        }
                }
            }
            .chartXSelection(value: $selected)
            .chartXAxis { AxisMarks(values: .stride(by: 7)) }
            .frame(height: 160)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 2) {
                GridRow { Text("Total"); Text(moves(total)).monospacedDigit() }
                GridRow { Text("Average"); Text(String(format: "%.1f moves/day", Double(total) / Double(days))).monospacedDigit() }
                GridRow { Text("Due tomorrow"); Text(moves(dueByDay[1] ?? 0)).monospacedDigit() }
                GridRow { Text("Daily load"); Text("\(due.dailyLoad) moves/day").monospacedDigit() }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }
}

private struct Tooltip: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold))
            Text(value).font(.caption).monospacedDigit()
        }
        .padding(6)
        .background(.regularMaterial, in: .rect(cornerRadius: 6))
    }
}

private struct CalendarCard: View {
    let graphs: Graphs

    var body: some View {
        let counts = graphs.reviews().count.intKeys
        let weeks = 20
        let weekdayToday = Calendar.current.component(.weekday, from: .now) - 1  // 0 = Sunday
        let cells = (0..<(weeks * 7)).compactMap { i -> (week: Int, weekday: Int, count: Int)? in
            let day = -(weeks * 7 - 1) + i + (6 - weekdayToday)
            guard day <= 0 else { return nil }
            return (i / 7, i % 7, counts[day]?.total ?? 0)
        }
        let maxCount = max(cells.map(\.count).max() ?? 1, 1)
        let studiedDays = counts.filter { $0.value.total > 0 && $0.key > -365 }.count
        let streak = graphs.streak()
        StatCard(title: "Calendar", subtitle: "Moves studied per day, last \(weeks) weeks. Studied on \(studiedDays) days this year. Streak: \(streak.current) \(streak.current == 1 ? "day" : "days"), longest \(streak.longest).") {
            Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                ForEach(0..<7, id: \.self) { weekday in
                    GridRow {
                        ForEach(0..<weeks, id: \.self) { week in
                            let cell = cells.first { $0.week == week && $0.weekday == weekday }
                            RoundedRectangle(cornerRadius: 2)
                                .fill(cell.map { $0.count > 0 ? AnyShapeStyle(.tint.opacity(0.25 + 0.75 * Double($0.count) / Double(maxCount))) : AnyShapeStyle(Color.secondary.opacity(0.12)) } ?? AnyShapeStyle(.clear))
                                .aspectRatio(1, contentMode: .fit)
                                .accessibilityLabel(cell.map { "\($0.count) moves" } ?? "")
                        }
                    }
                }
            }
        }
    }
}

private enum ReviewKind: String, CaseIterable, Plottable {
    case learn = "Learn", relearn = "Relearn", young = "Young", mature = "Mature", filtered = "Filtered"
    var color: ThemeColor {
        switch self {
        case .learn: ThemeColor.wrong.opacity(0.5)
        case .relearn: ThemeColor.wrong
        case .young: ThemeColor.done.opacity(0.5)
        case .mature: ThemeColor.done
        case .filtered: ThemeColor.ahead
        }
    }

    func value(_ c: ReviewCounts) -> Int {
        switch self {
        case .learn: Int(c.learn)
        case .relearn: Int(c.relearn)
        case .young: Int(c.young)
        case .mature: Int(c.mature)
        case .filtered: Int(c.filtered)
        }
    }
}

private struct ReviewsCard: View {
    let graphs: Graphs
    let range: GraphRange
    @State private var showTime = false
    @State private var selected: Int?

    var body: some View {
        let data = graphs.reviews()
        let source: [Int: ReviewCounts] = (showTime ? data.time : data.count).intKeys
        let first: Int = range == .all ? (source.keys.min() ?? 0) : -(range.days - 1)
        let bars: [(day: Int, kind: ReviewKind, value: Int)] = source.filter { $0.key >= first }.flatMap { day, c in
            ReviewKind.allCases.map { (day: day, kind: $0, value: $0.value(c)) }.filter { $0.value > 0 }
        }
        let totals: [ReviewKind: Int] = Dictionary(grouping: bars, by: \.kind).mapValues { $0.reduce(0) { $0 + $1.value } }
        let studied = Set(bars.map(\.day)).count
        StatCard(title: "Reviews", subtitle: "Answers per day by kind.") {
            Picker("Show", selection: $showTime) {
                Text("Count").tag(false)
                Text("Time").tag(true)
            }
            .pickerStyle(.segmented)
            Chart {
                ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                    BarMark(x: .value("Day", bar.day), y: .value(showTime ? "Minutes" : "Answers", showTime ? Double(bar.value) / 60_000 : Double(bar.value)))
                        .foregroundStyle(by: .value("Kind", bar.kind.rawValue))
                }
                if let selected {
                    RuleMark(x: .value("Day", selected))
                        .foregroundStyle(.secondary.opacity(0.3))
                        .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                            let c = source[selected] ?? ReviewCounts()
                            Tooltip(title: selected == 0 ? "Today" : "\(-selected) days ago",
                                    value: showTime ? duration(c.total) : "\(c.total) answers")
                        }
                }
            }
            .chartForegroundStyleScale(domain: ReviewKind.allCases.map(\.rawValue),
                                       range: ReviewKind.allCases.map(\.color))
            .chartXScale(domain: (first - 1)...1)
            .chartXSelection(value: $selected)
            .chartLegend(.hidden)
            .frame(height: 180)
            LegendRow(items: ReviewKind.allCases.map { ($0.rawValue, $0.color,
                                                         showTime ? duration(totals[$0] ?? 0) : "\(totals[$0] ?? 0)") })
            Text("Days studied: \(studied). Total: \(showTime ? duration(totals.values.reduce(0, +)) : "\(totals.values.reduce(0, +)) answers").")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// A legend with the value of each series, so color is never the only cue.
private struct LegendRow: View {
    let items: [(String, ThemeColor, String)]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 4) {
            ForEach(items, id: \.0) { name, color, value in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
                    Text(name).foregroundStyle(.secondary)
                    Text(value).monospacedDigit()
                }
                .font(.caption)
            }
        }
    }
}

private struct CardCountsCard: View {
    let graphs: Graphs

    var body: some View {
        let c = graphs.cardCounts()
        let items: [(String, Int, ThemeColor)] = [
            ("New", Int(c.new), ThemeColor.new), ("Learning", Int(c.learn), ThemeColor.wrong.opacity(0.5)),
            ("Relearning", Int(c.relearn), ThemeColor.wrong), ("Young", Int(c.young), ThemeColor.done.opacity(0.5)),
            ("Mature", Int(c.mature), ThemeColor.done), ("Suspended", Int(c.suspended), ThemeColor.inactive),
        ]
        let suspended = c.suspended > 0
            ? " Suspended: your moves below alternative moves. They keep their progress and are studied again if their line becomes the main line."
            : ""
        StatCard(title: "Move Counts", subtitle: "\(c.total) moves. Mature: shown again in 21 days or more.\(suspended)") {
            HStack(spacing: 16) {
                Chart(Array(items.enumerated()), id: \.offset) { _, item in
                    SectorMark(angle: .value("Moves", item.1), innerRadius: .ratio(0.6), angularInset: 1)
                        .foregroundStyle(item.2)
                }
                .frame(width: 120, height: 120)
                LegendRow(items: items.map { ($0.0, $0.2, "\($0.1)") })
            }
        }
    }
}

private struct HistogramCard: View {
    let title: String
    let unit: String
    let values: [Int: Int]
    var maxBin: Int?
    let footer: String
    var showsAverage = true

    var body: some View {
        let bins = binned
        StatCard(title: title, subtitle: footer) {
            if bins.isEmpty {
                Text("No data yet.").foregroundStyle(.secondary)
            } else {
                Chart(bins, id: \.start) { bin in
                    BarMark(x: .value(unit, bin.start), y: .value("Moves", bin.count))
                        .foregroundStyle(.tint)
                        .cornerRadius(4)
                }
                .chartXAxisLabel(unit)
                .frame(height: 140)
                if showsAverage {
                    let total = values.values.reduce(0, +)
                    let mean = total > 0 ? Double(values.reduce(0) { $0 + $1.key * $1.value }) / Double(total) : 0
                    Text("Average: \(String(format: "%.1f", mean)) \(unit) · \(moves(total))")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// About 20 bins up to the 95th percentile (or `maxBin`).
    private var binned: [(start: Int, count: Int)] {
        guard !values.isEmpty else { return [] }
        let sorted = values.flatMap { Array(repeating: $0.key, count: $0.value) }.sorted()
        let upper = maxBin ?? max(sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))], 1)
        let width = max(1, Int((Double(upper) / 20).rounded(.up)))
        var bins: [Int: Int] = [:]
        for value in sorted where value <= upper { bins[value / width * width, default: 0] += 1 }
        return bins.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}

private struct RetrievabilityCard: View {
    let graphs: Graphs

    var body: some View {
        let r = graphs.retrievability()
        HistogramCard(title: "Retrievability", unit: "%", values: r.bins.ints, maxBin: 100,
                      footer: "Chance of recalling each move now (FSRS). Average \(String(format: "%.1f", r.average))%, estimated total knowledge \(moves(Int(r.sum.rounded()))).",
                      showsAverage: false)
    }
}

private struct HourlyCard: View {
    let graphs: Graphs
    let range: GraphRange
    @State private var selected: Int?

    var body: some View {
        let hours = graphs.hours(range: range)
        StatCard(title: "Hourly Breakdown", subtitle: "Answers by hour of day; tap a bar for the share answered correctly.") {
            Chart(Array(hours.enumerated()), id: \.offset) { hour, h in
                BarMark(x: .value("Hour", hour), y: .value("Answers", h.total))
                    .foregroundStyle(.tint)
                    .cornerRadius(4)
                if selected == hour {
                    RuleMark(x: .value("Hour", hour))
                        .foregroundStyle(.secondary.opacity(0.3))
                        .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                            Tooltip(title: "\(hour):00–\(hour + 1):00",
                                    value: "\(h.total) answers, \(percent(h.total > 0 ? Double(h.correct) / Double(h.total) : nil)) correct")
                        }
                }
            }
            .chartXSelection(value: $selected)
            .chartXAxis { AxisMarks(values: [0, 6, 12, 18, 23]) }
            .frame(height: 140)
        }
    }
}

private struct AnswerButtonsCard: View {
    let graphs: Graphs
    let range: GraphRange

    var body: some View {
        let b = graphs.buttons(range: range)
        let groups = [("Learning", b.learning), ("Young", b.young), ("Mature", b.mature)]
        StatCard(title: "Answer Buttons", subtitle: "Again = wrong move, hint or browsing; Good = correct.") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("")
                    Text("Again").foregroundStyle(.secondary)
                    Text("Good").foregroundStyle(.secondary)
                    Text("Correct").foregroundStyle(.secondary)
                }
                ForEach(groups, id: \.0) { name, counts in
                    let total = counts.reduce(0, +)
                    GridRow {
                        Text(name)
                        Text("\(counts[0])").monospacedDigit()
                        Text("\(counts[2] + counts[1] + counts[3])").monospacedDigit()
                        Text(percent(total > 0 ? Double(total - counts[0]) / Double(total) : nil)).monospacedDigit()
                    }
                }
            }
            .font(.subheadline)
        }
    }
}

private struct TrueRetentionCard: View {
    let graphs: Graphs

    var body: some View {
        let table = graphs.retentionTable()
        StatCard(title: "True Retention", subtitle: "Moves answered correctly after a delay of a day or more.") {
            RetentionGrid(rows: RetentionPeriod.allCases.map { ($0.title, table[$0] ?? .init()) })
        }
    }
}

private struct RetentionGrid: View {
    let rows: [(String, TrueRetention)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Text("")
                Text("Young").foregroundStyle(.secondary)
                Text("Mature").foregroundStyle(.secondary)
                Text("Total").foregroundStyle(.secondary)
                Text("Count").foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.0) { title, r in
                GridRow {
                    Text(title).lineLimit(1)
                    Text(percent(r.young)).monospacedDigit()
                    Text(percent(r.mature)).monospacedDigit()
                    Text(percent(r.total)).monospacedDigit()
                    Text("\(r.count)").monospacedDigit()
                }
            }
        }
        .font(.subheadline)
    }
}

private struct WeakestMovesCard: View {
    @Environment(\.openScreen) private var openScreen
    let model: StatisticsModel

    var body: some View {
        let moves = model.weakestMoves
        StatCard(title: "Weakest Moves", subtitle: "Leeches and the moves you forget most. Tap one to open it.") {
            if moves.isEmpty {
                Text("Nothing forgotten yet.").foregroundStyle(.secondary)
            } else if let document = model.document {
                ForEach(moves) { move in
                    if let node = model.node(for: move.epd) {
                        link(document: document, node: node) {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(model.lineText(move.epd)).lineLimit(2).multilineTextAlignment(.leading)
                                    Text("\(move.lapses) lapses · recall \(percent(move.retrievability))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if move.leech { Label("Leech", systemImage: "ant.fill").labelStyle(.iconOnly).foregroundStyle(.attention) }
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .font(.subheadline)
                        }
                        .tint(.primary)
                    }
                }
            }
        }
    }

    /// Opens Browse at the move: in the library's middle column (split view), else pushed here.
    @ViewBuilder
    private func link<Label: View>(document: RepertoireDocument, node: NodeID,
                                   @ViewBuilder label: () -> Label) -> some View {
        if let openScreen {
            Button { openScreen(.browse(document.entryID, node)) } label: { label() }
        } else {
            NavigationLink { BuilderScreen(document: document, start: node) } label: { label() }
        }
    }
}

private struct BranchRetentionCard: View {
    let model: StatisticsModel

    var body: some View {
        let rows = model.retentionByBranch()
        StatCard(title: "Retention by Opening", subtitle: "True retention for each reply to your first move, all time.") {
            if rows.isEmpty {
                Text("No reviews after a delay of a day yet.").foregroundStyle(.secondary)
            } else {
                RetentionGrid(rows: rows.map { (model.document?.tree.lineText(to: $0.0) ?? "", $0.1) })
            }
        }
    }
}
