import Charts
import OpeningCoreRust
import SwiftUI

/// The Statistics tab: one screen of charts, after Apple's Health and Fitness, over one period.
/// Each card answers one question with the chart that suits it: how well you know the
/// repertoire (expected recall), whether you keep at it (streak and calendar), how much you
/// study (reviews), how the repertoire grows into memory (moves studied over time), what is
/// coming (future due), how much you remember (true retention, by opening), when you study
/// best (time of day), how sure you are now (recall and correct answers) and the moves to
/// work on. Anki's graphs underneath; FSRS's internals (stability, difficulty) are left out.
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
/// cards with the repertoire filter set to what the overview shows.
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

/// The period, then the cards: one column on a phone, as many as fit on iPad and Mac.
struct StatisticsSummary: View {
    @Bindable var model: StatisticsModel

    var body: some View {
        if let graphs = model.graphs, graphs.cardCounts().total > 0 || graphs.reviewsSummary(range: .all).answers > 0 {
            ScrollView {
                VStack(spacing: 16) {
                    Picker("Period", selection: $model.range) {
                        ForEach(GraphRange.allCases) { Text($0.shortTitle).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16, alignment: .top)], spacing: 16) {
                        cards(graphs)
                    }
                }
                .scenePadding()
            }
        } else if model.graphs == nil {
            ProgressView()
        } else {
            ContentUnavailableView("No Statistics Yet", systemImage: "chart.bar",
                                   description: Text("Study a repertoire to see your progress here."))
        }
    }

    @ViewBuilder
    private func cards(_ graphs: Graphs) -> some View {
        let range = model.range
        if let recall = model.expectedRecall { ExpectedRecallCard(recall: recall) }
        StreakCard(graphs: graphs)
        ReviewsCard(graphs: graphs, range: range)
        MovesCard(graphs: graphs, range: range)
        UpcomingCard(graphs: graphs, range: range)
        RetentionCard(graphs: graphs)
        if model.document != nil {
            let branches = model.retentionByBranch()
            if !branches.isEmpty { BranchRetentionCard(model: model, branches: branches) }
        }
        TimeOfDayCard(graphs: graphs, range: range)
        RecallCard(graphs: graphs, range: range)
        if model.document != nil { WeakestMovesCard(model: model) }
    }
}

// MARK: Cards

private struct ExpectedRecallCard: View {
    let recall: Double

    var body: some View {
        StatCard(title: "Expected Recall", systemImage: "brain", color: .learned) {
            StatValue(value: percent(recall), unit: "in your games")
            Gauge(value: recall) { Text("Expected recall") }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(ThemeColor.learned)
                .labelsHidden()
            Footnote(text: "The chance you know your move in the positions you will meet, weighted by how often they come up. Moves not studied yet count as forgotten.")
        }
    }
}

/// The streak and Anki's calendar: the last 26 weeks, a square a day, darker the more answers.
private struct StreakCard: View {
    let graphs: Graphs
    private static let weeks = 26

    private struct Cell: Identifiable {
        let week: Int
        let weekday: Int
        let date: Date
        let count: Int
        var id: Int { week * 7 + weekday }
    }

    var body: some View {
        let streak = graphs.streak()
        let counts = graphs.reviews().count.intKeys.mapValues { Int($0.total) }
        let cells = cells(counts)
        let maxCount = max(cells.map(\.count).max() ?? 1, 1)
        let studied = cells.filter { $0.count > 0 }.count
        let months = cells.filter { Calendar.current.component(.day, from: $0.date) == 1 }
        StatCard(title: "Streak", systemImage: "flame.fill", color: .todo) {
            HStack(alignment: .firstTextBaseline) {
                StatValue(value: streak.current.formatted(), unit: streak.current == 1 ? "day" : "days")
                Spacer()
                if !streak.studiedToday && streak.current > 0 {
                    Text("Study today to keep it").font(.footnote).foregroundStyle(.todo)
                }
            }
            Chart(cells) { cell in
                RectangleMark(x: .value("Week", String(cell.week)), y: .value("Day", String(cell.weekday)),
                              width: .ratio(0.84), height: .ratio(0.84))
                    .cornerRadius(2)
                    .foregroundStyle(cell.count > 0
                                     ? AnyShapeStyle(ThemeColor.todo.opacity(0.3 + 0.7 * Double(cell.count) / Double(maxCount)))
                                     : AnyShapeStyle(Color.secondary.opacity(0.15)))
            }
            .chartXScale(domain: (0..<Self.weeks).map(String.init))
            .chartYScale(domain: (0..<7).map(String.init))
            .chartXAxis {
                AxisMarks(values: months.map { String($0.week) }) { value in
                    AxisValueLabel(anchor: .topLeading) {
                        if let week = value.as(String.self).flatMap(Int.init),
                           let cell = months.first(where: { $0.week == week }) {
                            Text(cell.date.formatted(.dateTime.month(.abbreviated)))
                        }
                    }
                }
            }
            .chartYAxis(.hidden)
            .aspectRatio(CGFloat(Self.weeks) / 7, contentMode: .fit)
            .accessibilityLabel("Studied on \(studied) of the last \(Self.weeks * 7) days")
            Footnote(text: "Longest streak \(streak.longest.formatted()) \(streak.longest == 1 ? "day" : "days") · studied on \(studied) days in 6 months")
        }
    }

    /// Up to today, the weeks starting on the locale's first weekday.
    private func cells(_ counts: [Int: Int]) -> [Cell] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start else { return [] }
        var cells: [Cell] = []
        for week in 0..<Self.weeks {
            for weekday in 0..<7 {
                guard let date = calendar.date(byAdding: .day, value: (week - Self.weeks + 1) * 7 + weekday, to: thisWeek),
                      date <= today else { continue }
                let day = calendar.dateComponents([.day], from: today, to: date).day ?? 0
                cells.append(Cell(week: week, weekday: weekday, date: date, count: counts[day] ?? 0))
            }
        }
        return cells
    }
}

/// Anki's Reviews graph: answers per day (or week, month) by kind, and its table in a line.
private struct ReviewsCard: View {
    let graphs: Graphs
    let range: GraphRange
    @State private var selected: Date?

    private struct Bar: Identifiable {
        let date: Date
        let kind: ReviewKind
        let value: Int
        var id: String { "\(date.timeIntervalSince1970)-\(kind.rawValue)" }
    }

    var body: some View {
        let summary = graphs.reviewsSummary(range: range)
        let first = 1 - Int(summary.periodDays)
        let unit = range.binUnit
        let bars = bars(graphs.reviews().count.intKeys.filter { (first...0).contains($0.key) }, unit: unit)
        let totals = Dictionary(grouping: bars, by: \.kind).mapValues { $0.reduce(0) { $0 + $1.value } }
        let selectedBin = selected.flatMap { Calendar.current.dateInterval(of: unit, for: $0)?.start }
        StatCard(title: "Reviews", systemImage: "chart.bar.fill") {
            HStack(alignment: .firstTextBaseline) {
                if let selectedBin {
                    StatValue(value: bars.filter { $0.date == selectedBin }.reduce(0) { $0 + $1.value }.formatted(), unit: "answers")
                    Spacer()
                    Text(StatDay.title(selectedBin, unit)).font(.footnote).foregroundStyle(.secondary)
                } else {
                    StatValue(value: (Double(summary.answers) / Double(max(summary.periodDays, 1))).formatted(.number.precision(.fractionLength(0))),
                              unit: "answers a day")
                    Spacer()
                    Text(range.periodTitle).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Chart(bars) { bar in
                BarMark(x: .value("Day", bar.date, unit: unit), y: .value("Answers", bar.value))
                    .foregroundStyle(by: .value("Kind", bar.kind))
                    .opacity(selectedBin == nil || selectedBin == bar.date ? 1 : 0.4)
            }
            .chartForegroundStyleScale(domain: ReviewKind.allCases, range: ReviewKind.allCases.map(\.color))
            .chartLegend(.hidden)
            .chartXScale(domain: StatDay.bin(first, unit)...StatDay.binEnd(0, unit))
            .chartXSelection(value: $selected)
            .frame(height: 160)
            FlowLayout(spacing: 12) {
                ForEach(ReviewKind.allCases.filter { (totals[$0] ?? 0) > 0 }, id: \.self) { kind in
                    LegendItem(name: kind.rawValue, color: kind.color, value: (totals[kind] ?? 0).formatted())
                }
            }
            Footnote(text: "Studied \(summary.daysStudied) of \(summary.periodDays) days · \(durationText(millis: Int(summary.millis))) in all"
                     + (summary.answers > 0 ? " · \(durationText(millis: Int(summary.millis / summary.answers))) an answer" : ""))
        }
        .onChange(of: range) { selected = nil }
    }

    private func bars(_ days: [Int: ReviewCounts], unit: Calendar.Component) -> [Bar] {
        var sums: [Date: [ReviewKind: Int]] = [:]
        for (day, counts) in days {
            let bin = StatDay.bin(day, unit)
            for kind in ReviewKind.allCases { sums[bin, default: [:]][kind, default: 0] += kind.value(counts) }
        }
        return sums.flatMap { date, kinds in
            kinds.filter { $0.value > 0 }.map { Bar(date: date, kind: $0.key, value: $0.value) }
        }
        .sorted { ($0.date, ReviewKind.allCases.firstIndex(of: $0.kind)!) < ($1.date, ReviewKind.allCases.firstIndex(of: $1.kind)!) }
    }
}

/// The repertoire growing into memory: moves studied so far over the period (Anki's Added
/// graph, by first answer), then where all of them stand now.
private struct MovesCard: View {
    let graphs: Graphs
    let range: GraphRange

    private struct Point: Identifiable {
        let date: Date
        let total: Int
        var id: Date { date }
    }

    var body: some View {
        let c = graphs.cardCounts()
        let firstStudied = graphs.firstStudied().ints
        let first = range == .all ? min(firstStudied.keys.min() ?? 0, 0) : 1 - Int(range.days)
        let before = firstStudied.filter { $0.key < first }.values.reduce(0, +)
        let points = points(firstStudied, from: first, before: before)
        let total = points.last?.total ?? before
        StatCard(title: "Moves", systemImage: "square.stack.3d.up.fill", color: .learned) {
            HStack(alignment: .firstTextBaseline) {
                StatValue(value: total.formatted(), unit: "studied")
                Spacer()
                Text("+\((total - before).formatted()), \(range.periodTitle.lowercased())").font(.footnote).foregroundStyle(.secondary)
            }
            Chart(points) { point in
                AreaMark(x: .value("Day", point.date, unit: .day), y: .value("Moves", point.total))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(ThemeColor.learned.opacity(0.25))
                LineMark(x: .value("Day", point.date, unit: .day), y: .value("Moves", point.total))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(ThemeColor.learned)
            }
            .frame(height: 140)
            MoveGroupsBar(counts: c)
            FlowLayout(spacing: 12) {
                ForEach(MoveGroup.allCases.filter { $0.count(c) > 0 }, id: \.self) { group in
                    LegendItem(name: group.title, color: group.color, value: group.count(c).formatted())
                }
            }
            Footnote(text: "Young moves are shown again within 3 weeks, mature ones later. Suspended: below alternative moves; they keep their progress.")
        }
    }

    /// Moves studied by the end of each day of the period.
    private func points(_ firstStudied: [Int: Int], from first: Int, before: Int) -> [Point] {
        var total = before
        return (first...0).map { day in
            total += firstStudied[day] ?? 0
            return Point(date: StatDay.date(day), total: total)
        }
    }
}

/// Anki's Future Due graph; overdue moves are part of today's bar.
private struct UpcomingCard: View {
    let graphs: Graphs
    let range: GraphRange
    @State private var selected: Date?

    private struct Bar: Identifiable {
        let date: Date
        let overdue: Bool
        let count: Int
        var id: String { "\(date.timeIntervalSince1970)-\(overdue)" }
    }

    var body: some View {
        let summary = graphs.futureDueSummary(range: range)
        let unit = range.binUnit
        let last = Int(summary.periodDays)
        let bars = bars(graphs.futureDue().dueByDay.ints, last: last, unit: unit)
        let selectedBin = selected.flatMap { Calendar.current.dateInterval(of: unit, for: $0)?.start }
        StatCard(title: "Upcoming", systemImage: "calendar") {
            HStack(alignment: .firstTextBaseline) {
                if let selectedBin {
                    StatValue(value: bars.filter { $0.date == selectedBin }.reduce(0) { $0 + $1.count }.formatted(), unit: "due")
                    Spacer()
                    Text(StatDay.title(selectedBin, unit)).font(.footnote).foregroundStyle(.secondary)
                } else {
                    StatValue(value: summary.dueTomorrow.formatted(), unit: "due tomorrow")
                    Spacer()
                    Text(range.nextTitle).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Chart(bars) { bar in
                BarMark(x: .value("Day", bar.date, unit: unit), y: .value("Moves", bar.count))
                    .foregroundStyle(by: .value("Due", bar.overdue ? "Overdue" : "Due"))
                    .opacity(selectedBin == nil || selectedBin == bar.date ? 1 : 0.4)
            }
            .chartForegroundStyleScale(domain: ["Overdue", "Due"], range: [AnyShapeStyle(.wrong), AnyShapeStyle(.tint)])
            .chartLegend(.hidden)
            .chartXScale(domain: StatDay.bin(0, unit)...StatDay.binEnd(last - 1, unit))
            .chartXSelection(value: $selected)
            .frame(height: 160)
            if summary.overdue > 0 {
                Label("\(movesText(Int(summary.overdue))) overdue", systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.wrong)
            }
            Footnote(text: "\(movesText(Int(summary.total))) · \((Double(summary.total) / Double(max(last, 1))).formatted(.number.precision(.fractionLength(0)))) a day · daily load \(summary.dailyLoad.formatted())")
        }
        .onChange(of: range) { selected = nil }
    }

    private func bars(_ due: [Int: Int], last: Int, unit: Calendar.Component) -> [Bar] {
        var sums: [Date: Int] = [:]
        for (day, count) in due where day >= 0 && day < last { sums[StatDay.bin(day, unit), default: 0] += count }
        let overdue = due.filter { $0.key < 0 }.values.reduce(0, +)
        return sums.map { Bar(date: $0.key, overdue: false, count: $0.value) }
            + (overdue > 0 ? [Bar(date: StatDay.bin(0, unit), overdue: true, count: overdue)] : [])
    }
}

/// Anki's True Retention table.
private struct RetentionCard: View {
    let graphs: Graphs

    var body: some View {
        let table = graphs.retentionTable()
        let month = table[.month] ?? TrueRetention()
        StatCard(title: "Retention", systemImage: "checkmark.seal.fill", color: .correct) {
            HStack(alignment: .firstTextBaseline) {
                StatValue(value: percent(month.total), unit: "remembered")
                Spacer()
                Text(RetentionPeriod.month.title).font(.footnote).foregroundStyle(.secondary)
            }
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    Text("Young")
                    Text("Mature")
                    Text("Total")
                    Text("Reviews")
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(RetentionPeriod.allCases) { period in
                    let r = table[period] ?? TrueRetention()
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        Text(period.title).frame(maxWidth: .infinity, alignment: .leading)
                        Text(percent(r.young)).foregroundStyle(.secondary)
                        Text(percent(r.mature)).foregroundStyle(.secondary)
                        Text(percent(r.total)).fontWeight(.semibold)
                        Text(r.count.formatted()).foregroundStyle(.secondary)
                    }
                }
            }
            .font(.subheadline)
            .monospacedDigit()
            Footnote(text: "Reviews a day or more after the last one, answered correctly. FSRS aims for your desired retention (90% by default).")
        }
    }
}

/// True retention for each reply to your first move, all time.
private struct BranchRetentionCard: View {
    let model: StatisticsModel
    let branches: [(NodeID, TrueRetention)]

    var body: some View {
        let rows = branches.map { (model.document?.tree.lineText(to: $0.0) ?? "", $0.1) }
        StatCard(title: "Retention by Opening", systemImage: "arrow.triangle.branch", color: .correct) {
            Chart(rows, id: \.0) { line, r in
                BarMark(x: .value("Retention", r.total ?? 0), y: .value("Opening", line))
                    .foregroundStyle(ThemeColor.correct)
                    .annotation(position: .trailing) {
                        Text("\(percent(r.total)) · \(r.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
            }
            .chartXScale(domain: 0...1.25)
            .chartXAxis(.hidden)
            .frame(height: CGFloat(rows.count) * 32 + 8)
            Footnote(text: "All time: the share of reviews after a day or more answered correctly, and how many.")
        }
    }
}

/// Anki's Hourly Breakdown: answers by hour of day, and the share answered correctly.
private struct TimeOfDayCard: View {
    let graphs: Graphs
    let range: GraphRange
    @State private var selected: Int?

    var body: some View {
        let hours = graphs.hours(range: range)
        let busiest = hours.indices.max { hours[$0].total < hours[$1].total }
        StatCard(title: "Time of Day", systemImage: "clock.fill") {
            if let hour = selected ?? busiest, hours[hour].total > 0 {
                let h = hours[hour]
                VStack(alignment: .leading, spacing: 2) {
                    StatValue(value: percent(Double(h.correct) / Double(h.total)), unit: "correct")
                    Footnote(text: "\(selected == nil ? "Most answers: " : "")\(hourTitle(hour))–\(hourTitle(hour + 1)), \(answersText(Int(h.total)))")
                }
            } else {
                Footnote(text: "No answers in this period.")
            }
            Chart(Array(hours.enumerated()), id: \.offset) { hour, h in
                AreaMark(x: .value("Hour", hour), y: .value("Answers", h.total))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.tint.opacity(0.25))
                LineMark(x: .value("Hour", hour), y: .value("Answers", h.total))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.tint)
                if selected == hour {
                    RuleMark(x: .value("Hour", hour)).foregroundStyle(.secondary)
                }
            }
            .chartXScale(domain: 0...23)
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                    AxisGridLine()
                    AxisValueLabel { if let hour = value.as(Int.self) { Text(hourTitle(hour)) } }
                }
            }
            .chartXSelection(value: $selected)
            .frame(height: 120)
        }
    }

    private func hourTitle(_ hour: Int) -> String {
        Calendar.current.date(bySettingHour: hour % 24, minute: 0, second: 0, of: .now)?
            .formatted(.dateTime.hour()) ?? "\(hour)"
    }
}

/// FSRS's average recall now, and Anki's Answer Buttons as correct answers by stage.
private struct RecallCard: View {
    let graphs: Graphs
    let range: GraphRange

    var body: some View {
        let r = graphs.retrievability()
        let b = graphs.buttons(range: range)
        StatCard(title: "Recall", systemImage: "brain.head.profile") {
            if r.bins.isEmpty {
                Footnote(text: "How likely you are to recall each move, once you have studied some.")
            } else {
                StatValue(value: percent(r.average / 100), unit: "average recall now")
                Gauge(value: r.average / 100) { Text("Average recall") }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .labelsHidden()
                Footnote(text: "You would recall about \(movesText(Int(r.sum.rounded()))) right now.")
            }
            Divider()
            Text("Correct answers, \(range.periodTitle.lowercased())").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 24) {
                ForEach([("Learning", b.learning), ("Young", b.young), ("Mature", b.mature)], id: \.0) { name, counts in
                    let total = Int(counts.reduce(0, +))
                    Metric(title: name, value: total > 0 ? percent(Double(total - Int(counts[0])) / Double(total)) : "—")
                }
            }
            Footnote(text: "Wrong: a wrong move, a hint or looking the move up.")
        }
    }
}

/// The moves you forget most, each opening Browse at it.
private struct WeakestMovesCard: View {
    let model: StatisticsModel

    var body: some View {
        let moves = model.weakestMoves(limit: 6)
        StatCard(title: "Weakest Moves", systemImage: "exclamationmark.triangle.fill", color: .wrong) {
            if moves.isEmpty {
                Footnote(text: "Nothing forgotten yet.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(moves.enumerated()), id: \.element.id) { index, move in
                        if index > 0 { Divider() }
                        WeakMoveRow(model: model, move: move)
                    }
                }
                Footnote(text: "Leeches (the ant) first, then the moves you forget most.")
            }
        }
    }
}

/// A weak move: its line, lapses and recall. Opens Browse at it: in the library's middle
/// column (split view), else pushed here.
private struct WeakMoveRow: View {
    @Environment(\.openScreen) private var openScreen
    let model: StatisticsModel
    let move: WeakMove

    var body: some View {
        if let document = model.document, let node = model.node(for: move.epd) {
            Group {
                if let openScreen {
                    Button { openScreen(.browse(document.entryID, node)) } label: { label }
                } else {
                    NavigationLink { BuilderScreen(document: document, start: node) } label: { label }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var label: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.lineText(move.epd)).lineLimit(2).multilineTextAlignment(.leading)
                Text("\(move.lapses) \(move.lapses == 1 ? "lapse" : "lapses") · recall \(percent(move.retrievability))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            if move.leech {
                Image(systemName: "ant.fill").foregroundStyle(.todo).accessibilityLabel("Leech")
            }
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .font(.subheadline)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
