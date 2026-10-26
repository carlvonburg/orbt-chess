import Charts
import OpeningCoreRust
import SwiftUI

// The screens behind the summary cards: Anki's graphs, each with its headline number and the
// table Anki shows under it.

// MARK: Reviews

/// Anki's Reviews graph (answers or time per day by kind), its table, the hour of day and the
/// answer buttons, over the chosen period.
struct ReviewsDetail: View {
    let graphs: Graphs
    @State private var range = GraphRange.month
    @State private var showTime = false
    @State private var selected: Date?

    private struct Bar: Identifiable {
        let date: Date
        let kind: ReviewKind
        let value: Int
        var id: String { "\(date.timeIntervalSince1970)-\(kind.rawValue)" }
    }

    var body: some View {
        let reviews = graphs.reviews()
        let source = (showTime ? reviews.time : reviews.count).intKeys
        let summary = graphs.reviewsSummary(range: range)
        let first = 1 - Int(summary.periodDays)
        let unit = range.binUnit
        let inRange = source.filter { (first...0).contains($0.key) }
        let bars = bars(inRange, unit: unit)
        let totals = Dictionary(grouping: bars, by: \.kind).mapValues { $0.reduce(0) { $0 + $1.value } }
        let selectedBin = selected.flatMap { Calendar.current.dateInterval(of: unit, for: $0)?.start }
        List {
            Section {
                RangePicker(range: $range)
                if let selectedBin {
                    let total = bars.filter { $0.date == selectedBin }.reduce(0) { $0 + $1.value }
                    Headline(label: "Total", value: value(total), unit: showTime ? nil : "answers",
                             caption: StatDay.title(selectedBin, unit))
                } else {
                    let average = Int((Double(showTime ? summary.millis : summary.answers) / Double(max(summary.periodDays, 1))).rounded())
                    Headline(label: "Daily Average", value: value(average), unit: showTime ? nil : "answers",
                             caption: range.periodTitle)
                }
                Chart {
                    ForEach(bars) { bar in
                        BarMark(x: .value("Day", bar.date, unit: unit),
                                y: .value(showTime ? "Minutes" : "Answers", showTime ? Double(bar.value) / 60_000 : Double(bar.value)))
                            .foregroundStyle(by: .value("Kind", bar.kind))
                            .opacity(selectedBin == nil || selectedBin == bar.date ? 1 : 0.4)
                    }
                }
                .chartForegroundStyleScale(domain: ReviewKind.allCases, range: ReviewKind.allCases.map(\.color))
                .chartLegend(.hidden)
                .chartXScale(domain: StatDay.bin(first, unit)...(Calendar.current.dateInterval(of: unit, for: .now)?.end ?? .now))
                .chartXSelection(value: $selected)
                .frame(height: 220)
                Picker("Show", selection: $showTime) {
                    Text("Answers").tag(false)
                    Text("Time").tag(true)
                }
                .pickerStyle(.segmented)
            }
            Section {
                ForEach(ReviewKind.allCases, id: \.self) { kind in
                    LabeledContent {
                        Text(value(totals[kind] ?? 0)).monospacedDigit()
                    } label: {
                        Label {
                            Text(kind.rawValue)
                            Text(kind.explanation)
                        } icon: {
                            Image(systemName: "circle.fill").foregroundStyle(kind.color)
                        }
                    }
                }
            }
            Section("Summary") {
                LabeledContent("Days studied") {
                    Text("\(summary.daysStudied) of \(summary.periodDays) (\(percent(Double(summary.daysStudied) / Double(max(summary.periodDays, 1)))))")
                }
                LabeledContent("Total", value: showTime ? durationText(millis: Int(summary.millis)) : answersText(Int(summary.answers)))
                if summary.daysStudied > 0 {
                    LabeledContent("Average on days studied",
                                   value: perDay(showTime ? summary.millis : summary.answers, summary.daysStudied))
                }
                LabeledContent("Average over the period",
                               value: perDay(showTime ? summary.millis : summary.answers, summary.periodDays))
                if summary.answers > 0 {
                    LabeledContent("Average answer time",
                                   value: durationText(millis: Int(summary.millis / summary.answers)))
                }
            }
            .monospacedDigit()
            Section {
                HourlyChart(graphs: graphs, range: range)
            } header: {
                Text("Time of Day")
            }
            CorrectAnswersSection(graphs: graphs, range: range)
        }
        .navigationTitle("Reviews")
        .onChange(of: range) { selected = nil }
    }

    private func value(_ n: Int) -> String {
        showTime ? durationText(millis: n) : n.formatted()
    }

    private func perDay(_ total: Int64, _ days: Int64) -> String {
        let n = Double(total) / Double(max(days, 1))
        return showTime ? "\(durationText(millis: Int(n))) a day" : "\(n.formatted(.number.precision(.fractionLength(0...1)))) answers a day"
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

/// Anki's Hourly Breakdown: answers by hour of day, and the share answered correctly.
private struct HourlyChart: View {
    let graphs: Graphs
    let range: GraphRange
    @State private var selected: Int?

    var body: some View {
        let hours = graphs.hours(range: range)
        let busiest = hours.indices.max { hours[$0].total < hours[$1].total }
        VStack(alignment: .leading, spacing: 8) {
            if let hour = selected ?? busiest, hours[hour].total > 0 {
                let h = hours[hour]
                Text("\(selected == nil ? "Most answers" : "Answers") \(hourTitle(hour))–\(hourTitle(hour + 1)): \(Text(h.total.formatted()).bold()), \(Text(percent(Double(h.correct) / Double(h.total))).bold()) correct")
                    .font(.subheadline)
            } else {
                Text("No answers in this period.").font(.subheadline).foregroundStyle(.secondary)
            }
            Chart(Array(hours.enumerated()), id: \.offset) { hour, h in
                BarMark(x: .value("Hour", hour), y: .value("Answers", h.total))
                    .foregroundStyle(.tint)
                    .opacity(selected == nil || selected == hour ? 1 : 0.4)
            }
            .chartXScale(domain: -0.5...23.5)
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18]) { value in
                    AxisGridLine()
                    AxisValueLabel { if let hour = value.as(Int.self) { Text(hourTitle(hour)) } }
                }
            }
            .chartXSelection(value: $selected)
            .frame(height: 140)
        }
    }

    private func hourTitle(_ hour: Int) -> String {
        Calendar.current.date(bySettingHour: hour % 24, minute: 0, second: 0, of: .now)?
            .formatted(.dateTime.hour()) ?? "\(hour)"
    }
}

/// Anki's Answer Buttons, as correct answers (Good) by stage: Again is a wrong move, a hint or
/// browsing.
private struct CorrectAnswersSection: View {
    let graphs: Graphs
    let range: GraphRange

    var body: some View {
        let b = graphs.buttons(range: range)
        Section {
            ForEach([("Learning", b.learning), ("Young", b.young), ("Mature", b.mature)], id: \.0) { name, counts in
                let total = Int(counts.reduce(0, +))
                LabeledContent {
                    Text(total > 0 ? percent(Double(total - Int(counts[0])) / Double(total)) : "—").monospacedDigit()
                } label: {
                    Text(name)
                    Text("\(counts[0].formatted()) again of \(answersText(total))").monospacedDigit()
                }
            }
        } header: {
            Text("Correct Answers")
        } footer: {
            Text("Again: a wrong move, a hint or looking the move up.")
        }
    }
}

// MARK: Upcoming

/// Anki's Future Due graph and its table; overdue moves are part of today's bar.
struct UpcomingDetail: View {
    let graphs: Graphs
    @State private var range = GraphRange.month
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
        let bars = bars(graphs.futureDue().dueByDay.ints, last: Int(summary.periodDays), unit: unit)
        let selectedBin = selected.flatMap { Calendar.current.dateInterval(of: unit, for: $0)?.start }
        List {
            Section {
                RangePicker(range: $range)
                if let selectedBin {
                    Headline(label: "Due", value: bars.filter { $0.date == selectedBin }.reduce(0) { $0 + $1.count }.formatted(),
                             unit: "moves", caption: StatDay.title(selectedBin, unit))
                } else {
                    Headline(label: "Total", value: summary.total.formatted(), unit: "moves", caption: range.nextTitle)
                }
                Chart(bars) { bar in
                    BarMark(x: .value("Day", bar.date, unit: unit), y: .value("Moves", bar.count))
                        .foregroundStyle(by: .value("Due", bar.overdue ? "Overdue" : "Due"))
                        .opacity(selectedBin == nil || selectedBin == bar.date ? 1 : 0.4)
                }
                .chartForegroundStyleScale(domain: ["Overdue", "Due"], range: [AnyShapeStyle(.wrong), AnyShapeStyle(.tint)])
                .chartLegend(summary.overdue > 0 ? .visible : .hidden)
                .chartXScale(domain: StatDay.bin(0, unit)...(Calendar.current.dateInterval(of: unit, for: StatDay.date(Int(summary.periodDays) - 1))?.end ?? .now))
                .chartXSelection(value: $selected)
                .frame(height: 220)
            }
            Section {
                LabeledContent("Due tomorrow", value: movesText(Int(summary.dueTomorrow)))
                LabeledContent("Average", value: "\((Double(summary.total) / Double(max(summary.periodDays, 1))).formatted(.number.precision(.fractionLength(0...1)))) a day")
                if summary.overdue > 0 {
                    LabeledContent("Overdue", value: movesText(Int(summary.overdue)))
                }
                LabeledContent("Daily load", value: "\(summary.dailyLoad.formatted()) a day")
            } footer: {
                Text("Daily load: the reviews a day your studied moves add up to in the long run.")
            }
            .monospacedDigit()
        }
        .navigationTitle("Upcoming")
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

// MARK: Retention

/// Anki's True Retention table, then retention by opening (one repertoire).
struct RetentionDetail: View {
    let model: StatisticsModel
    let graphs: Graphs

    var body: some View {
        let table = graphs.retentionTable()
        let month = table[.month] ?? TrueRetention()
        List {
            Section {
                Headline(label: "Retention", value: percent(month.total), unit: month.count > 0 ? "remembered" : nil,
                         caption: RetentionPeriod.month.title)
            }
            Section {
                ForEach(RetentionPeriod.allCases) { period in
                    RetentionRow(title: period.title, retention: table[period] ?? TrueRetention())
                }
            } footer: {
                Text("Reviews a day or more after the last one that you answered correctly. Young moves are shown again within 3 weeks, mature ones later. FSRS schedules for 90% by default (desired retention, in the study options).")
            }
            if model.document != nil {
                let branches = model.retentionByBranch()
                Section {
                    if branches.isEmpty {
                        Text("No reviews after a delay of a day yet.").foregroundStyle(.secondary)
                    }
                    ForEach(branches, id: \.0) { id, retention in
                        RetentionRow(title: model.document?.tree.lineText(to: id) ?? "", retention: retention)
                    }
                } header: {
                    Text("By Opening")
                } footer: {
                    Text("All time, for each reply to your first move.")
                }
            }
        }
        .navigationTitle("Retention")
    }
}

private struct RetentionRow: View {
    let title: String
    let retention: TrueRetention

    var body: some View {
        LabeledContent {
            Text(percent(retention.total)).monospacedDigit()
        } label: {
            Text(title)
            if retention.count > 0 {
                Text("Young \(percent(retention.young)) · Mature \(percent(retention.mature)) · \(retention.count.formatted()) reviews")
                    .monospacedDigit()
            } else {
                Text("No reviews")
            }
        }
    }
}

// MARK: Moves

/// Anki's Card Counts (as the studied bar, a ring is mostly new moves) and Review Intervals.
struct MovesDetail: View {
    let graphs: Graphs

    var body: some View {
        let c = graphs.cardCounts()
        let groups = MoveGroup.allCases
        let intervals = graphs.intervals().ints
        List {
            Section {
                Headline(label: "Learned", value: Int(c.young + c.mature).formatted(),
                         unit: "of \(Int(c.total).formatted()) moves")
                MoveGroupsBar(counts: c)
                ForEach(groups, id: \.self) { group in
                    LabeledContent {
                        Text(group.count(c).formatted()).monospacedDigit()
                    } label: {
                        Label {
                            Text(group.title)
                            Text(group.explanation)
                        } icon: {
                            Image(systemName: "circle.fill").foregroundStyle(group.color)
                        }
                    }
                }
            }
            Section {
                if intervals.isEmpty {
                    Text("No moves reviewed yet.").foregroundStyle(.secondary)
                } else {
                    HistogramChart(unit: "days", values: intervals)
                    if let average = mean(intervals) {
                        LabeledContent("Average", value: "\(average.formatted(.number.precision(.fractionLength(0...1)))) days")
                    }
                }
            } header: {
                Text("Review Intervals")
            } footer: {
                Text("The days until each move is shown again.")
            }
        }
        .navigationTitle("Moves")
    }
}

// MARK: Memory

/// FSRS's view of your memory: Anki's Retrievability, Stability and Difficulty graphs.
struct MemoryDetail: View {
    let graphs: Graphs

    var body: some View {
        let r = graphs.retrievability()
        let stability = graphs.stability().ints
        let difficulty = graphs.difficulty().ints
        List {
            if r.bins.isEmpty {
                ContentUnavailableView("No Memory Data Yet", systemImage: "brain.head.profile",
                                       description: Text("Study some moves to see how well you remember them."))
            } else {
                Section {
                    Headline(label: "Average Recall", value: percent(r.average / 100))
                    HistogramChart(unit: "%", values: r.bins.ints, maxBin: 100)
                    LabeledContent("Moves you would recall now", value: Int(r.sum.rounded()).formatted())
                } header: {
                    Text("Retrievability")
                } footer: {
                    Text("The chance of recalling each move right now.")
                }
                Section {
                    HistogramChart(unit: "days", values: stability)
                    if let average = mean(stability) {
                        LabeledContent("Average", value: "\(average.formatted(.number.precision(.fractionLength(0...1)))) days")
                    }
                } header: {
                    Text("Stability")
                } footer: {
                    Text("The days until recall drops to 90%. It grows with each correct review.")
                }
                Section {
                    HistogramChart(unit: "%", values: difficulty, maxBin: 100)
                    if let average = mean(difficulty) {
                        LabeledContent("Average", value: percent(average / 100))
                    }
                } header: {
                    Text("Difficulty")
                } footer: {
                    Text("How hard each move is to remember: higher when you forget it, so its stability grows more slowly.")
                }
            }
        }
        .monospacedDigit()
        .navigationTitle("Memory")
    }
}

// MARK: Calendar

/// Anki's Calendar as months of days, ticked when studied (Fitness's history), with the streak.
struct CalendarDetail: View {
    let graphs: Graphs

    var body: some View {
        let streak = graphs.streak()
        let counts = graphs.reviews().count.intKeys.mapValues { Int($0.total) }.filter { $0.value > 0 }
        let first = counts.keys.min() ?? 0
        let months = monthStarts(from: StatDay.date(min(first, 0)))
        List {
            Section {
                Headline(label: "Current Streak", value: streak.current.formatted(), unit: streak.current == 1 ? "day" : "days",
                         caption: streak.studiedToday || streak.current == 0 ? nil : "Study today to keep it")
                LabeledContent("Longest streak", value: "\(streak.longest.formatted()) days")
                LabeledContent("Days studied in the last year", value: counts.keys.filter { $0 > -365 }.count.formatted())
            }
            .monospacedDigit()
            ForEach(months, id: \.self) { month in
                MonthSection(month: month, counts: counts, maxCount: counts.values.max() ?? 1)
            }
        }
        .navigationTitle("Calendar")
    }

    /// This month first, back to the month of the first answer (at least a year).
    private func monthStarts(from first: Date) -> [Date] {
        let calendar = Calendar.current
        guard let now = calendar.dateInterval(of: .month, for: .now)?.start else { return [] }
        let earliest = min(first, calendar.date(byAdding: .month, value: -11, to: now) ?? now)
        var months: [Date] = []
        var month = now
        while month >= (calendar.dateInterval(of: .month, for: earliest)?.start ?? earliest) {
            months.append(month)
            guard let previous = calendar.date(byAdding: .month, value: -1, to: month) else { break }
            month = previous
        }
        return months
    }
}

private struct MonthSection: View {
    let month: Date
    let counts: [Int: Int]
    let maxCount: Int

    var body: some View {
        let calendar = Calendar.current
        let days = calendar.range(of: .day, in: .month, for: month)?.count ?? 30
        let lead = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        let today = calendar.startOfDay(for: .now)
        let dayNumbers = (0..<days).map { calendar.dateComponents([.day], from: today, to: calendar.date(byAdding: .day, value: $0, to: month)!).day ?? 0 }
        let studied = dayNumbers.filter { counts[$0] != nil }.count
        Section {
            let cells: [Int?] = Array(repeating: nil, count: lead) + dayNumbers.map { $0 }
            let weeks = stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<min($0 + 7, cells.count)]) }
            Grid(horizontalSpacing: 4, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                        Text(symbol).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    GridRow {
                        ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                            if let day {
                                let number = (dayNumbers.firstIndex(of: day) ?? 0) + 1
                                DayCell(number: number, count: counts[day], maxCount: maxCount, isToday: day == 0, isFuture: day > 0)
                            } else {
                                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            HStack {
                Text(month.formatted(.dateTime.month(.wide).year()))
                Spacer()
                if studied > 0 { Text("\(studied) \(studied == 1 ? "day" : "days")").monospacedDigit() }
            }
        }
    }

    private var weekdaySymbols: [String] {
        let symbols = Calendar.current.veryShortStandaloneWeekdaySymbols
        let first = Calendar.current.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }
}

/// A day of the calendar: filled when studied, darker the more answers.
private struct DayCell: View {
    let number: Int
    let count: Int?
    let maxCount: Int
    let isToday: Bool
    let isFuture: Bool

    var body: some View {
        Text(number.formatted())
            .font(.footnote.weight(isToday ? .bold : .regular))
            .monospacedDigit()
            .foregroundStyle(count != nil ? AnyShapeStyle(.white) : isFuture ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity, minHeight: 32)
            .background {
                if let count {
                    Circle().fill(.todo.opacity(0.45 + 0.55 * Double(count) / Double(max(maxCount, 1))))
                } else if isToday {
                    Circle().strokeBorder(.todo, lineWidth: 1.5)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(count.map { "\(number), \(answersText($0))" } ?? "\(number)")
    }
}

// MARK: Weakest moves

struct WeakestMovesDetail: View {
    let model: StatisticsModel

    var body: some View {
        List {
            Section {
                ForEach(model.weakestMoves(limit: 50)) { WeakMoveRow(model: model, move: $0) }
            } footer: {
                Text("Leeches (the ant) are moves forgotten again and again; then the moves you forget most, and those you are least likely to recall now.")
            }
        }
        .navigationTitle("Weakest Moves")
    }
}

/// A weak move: its line, lapses and recall. Opens Browse at it: in the library's middle
/// column (split view), else pushed here.
struct WeakMoveRow: View {
    @Environment(\.openScreen) private var openScreen
    let model: StatisticsModel
    let move: WeakMove

    var body: some View {
        if let document = model.document, let node = model.node(for: move.epd) {
            if let openScreen {
                Button { openScreen(.browse(document.entryID, node)) } label: { label }
                    .tint(.primary)
            } else {
                NavigationLink { BuilderScreen(document: document, start: node) } label: { label }
            }
        }
    }

    private var label: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.lineText(move.epd)).lineLimit(2)
                Text("\(move.lapses) \(move.lapses == 1 ? "lapse" : "lapses") · recall \(percent(move.retrievability))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            if move.leech {
                Image(systemName: "ant.fill").foregroundStyle(.todo).accessibilityLabel("Leech")
            }
        }
        .font(.subheadline)
    }
}
