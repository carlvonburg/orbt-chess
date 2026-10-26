import Charts
import OpeningCoreRust
import SwiftUI

// The building blocks of the Statistics screens, after Apple's Health and Fitness: a card
// names its subject with a symbol, leads with one number and shows a small chart; its detail
// screen leads with the same number above the full chart, then a table.

/// A summary card's first line: its subject, and the period it covers.
struct CardHeader: View {
    let title: String
    let systemImage: String
    var color: ThemeColor?
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.tint))
            Spacer()
            if let trailing {
                Text(trailing).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

/// A number in Health's style: rounded and bold, its unit smaller and secondary.
struct StatValue: View {
    let value: String
    var unit: String?
    var font: Font = .title

    var body: some View {
        if let unit {
            Text("\(Text(value).font(font.weight(.semibold))) \(Text(unit).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary))")
                .fontDesign(.rounded)
                .monospacedDigit()
        } else {
            Text(value).font(font.weight(.semibold)).fontDesign(.rounded).monospacedDigit()
        }
    }
}

/// A detail screen's headline above its chart: what the number is, the number, and the days
/// it covers (or the selected bar's).
struct Headline: View {
    let label: String
    let value: String
    var unit: String?
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            StatValue(value: value, unit: unit, font: .largeTitle)
            if let caption {
                Text(caption).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A small metric in a row of several (Fitness's rings card).
struct Metric: View {
    let title: String
    let value: String
    var unit: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            StatValue(value: value, unit: unit, font: .title3)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A colored key with its name and value, so color is never the only cue.
struct LegendItem: View {
    let name: String
    let color: ThemeColor
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.fill").font(.system(size: 8)).foregroundStyle(color)
            Text(name).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}

/// The period of a detail screen, above its chart as Health does.
struct RangePicker: View {
    @Binding var range: GraphRange
    var ranges: [GraphRange] = GraphRange.allCases

    var body: some View {
        Picker("Period", selection: $range) {
            ForEach(ranges) { Text($0.shortTitle).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

extension GraphRange {
    /// Health's period names.
    var shortTitle: String {
        switch self {
        case .week: "W"
        case .month: "M"
        case .threeMonths: "3M"
        case .year: "Y"
        case .all: "All"
        }
    }

    var periodTitle: String {
        switch self {
        case .week: "Last 7 days"
        case .month: "Last 30 days"
        case .threeMonths: "Last 3 months"
        case .year: "Last year"
        case .all: "All time"
        }
    }

    var nextTitle: String {
        switch self {
        case .week: "Next 7 days"
        case .month: "Next 30 days"
        case .threeMonths: "Next 3 months"
        case .year: "Next year"
        case .all: "All due moves"
        }
    }

    /// The bars of a chart over this range: days, weeks for three months, months beyond.
    var binUnit: Calendar.Component {
        switch self {
        case .week, .month: .day
        case .threeMonths: .weekOfYear
        case .year, .all: .month
        }
    }
}

// MARK: Days

/// Anki's day numbers (0 = today, -1 = yesterday) as dates, for chart axes.
enum StatDay {
    static func date(_ day: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: day, to: Calendar.current.startOfDay(for: .now)) ?? .now
    }

    /// The start of the bar a day falls in.
    static func bin(_ day: Int, _ unit: Calendar.Component) -> Date {
        Calendar.current.dateInterval(of: unit, for: date(day))?.start ?? date(day)
    }

    static func title(_ date: Date, _ unit: Calendar.Component) -> String {
        switch unit {
        case .day:
            if Calendar.current.isDateInToday(date) { return "Today" }
            if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
            if Calendar.current.isDateInTomorrow(date) { return "Tomorrow" }
            return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        case .weekOfYear:
            return "Week of \(date.formatted(.dateTime.day().month(.abbreviated)))"
        default:
            return date.formatted(.dateTime.month(.wide).year())
        }
    }
}

// MARK: Formatting

func percent(_ value: Double?) -> String {
    value.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—"
}

func movesText(_ n: Int) -> String { n == 1 ? "1 move" : "\(n.formatted()) moves" }

func answersText(_ n: Int) -> String { n == 1 ? "1 answer" : "\(n.formatted()) answers" }

/// "8 min", "1 h 20 min", "40 s".
func durationText(millis: Int) -> String {
    let secs = Double(millis) / 1000
    let style: Duration.UnitsFormatStyle = secs < 60
        ? .units(allowed: [.seconds], width: .abbreviated)
        : .units(allowed: [.hours, .minutes], width: .abbreviated)
    return Duration.seconds(secs.rounded()).formatted(style)
}

// MARK: Histogram

/// About 20 bars up to the 95th percentile (or `maxBin`), for Anki's distributions.
struct HistogramChart: View {
    let unit: String
    let values: [Int: Int]
    var maxBin: Int?

    var body: some View {
        let (bins, width) = binned
        Chart(bins, id: \.start) { bin in
            BarMark(x: .value(unit, bin.start), y: .value("Moves", bin.count), width: .ratio(0.8))
                .foregroundStyle(.tint)
        }
        // Half a bar's room on each side, so the first and last bars are not cut off.
        .chartXScale(domain: Double(maxBin == nil ? bins.first?.start ?? 0 : 0) - Double(width) / 2
                       ... Double(maxBin ?? bins.last?.start ?? 0) + Double(width) / 2)
        .chartXAxisLabel(unit, alignment: .trailing)
        .frame(height: 160)
    }

    private var binned: (bins: [(start: Int, count: Int)], width: Int) {
        guard !values.isEmpty else { return ([], 1) }
        let sorted = values.flatMap { Array(repeating: $0.key, count: $0.value) }.sorted()
        let upper = maxBin ?? max(sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))], 1)
        let width = max(1, Int((Double(upper) / 20).rounded(.up)))
        var bins: [Int: Int] = [:]
        for value in sorted where value <= upper { bins[value / width * width, default: 0] += 1 }
        return (bins.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }, width)
    }
}

/// The mean of a distribution of values → counts.
func mean(_ values: [Int: Int]) -> Double? {
    let total = values.values.reduce(0, +)
    return total > 0 ? Double(values.reduce(0) { $0 + $1.key * $1.value }) / Double(total) : nil
}

// MARK: Review kinds

enum ReviewKind: String, CaseIterable, Plottable {
    case learn = "Learning", relearn = "Relearning", young = "Young", mature = "Mature", filtered = "Ahead"

    var color: ThemeColor {
        switch self {
        case .learn: ThemeColor.learning.lighter()
        case .relearn: ThemeColor.learning
        case .young: ThemeColor.learned.lighter()
        case .mature: ThemeColor.learned
        case .filtered: ThemeColor.ahead
        }
    }

    var explanation: String {
        switch self {
        case .learn: "New moves in their first steps"
        case .relearn: "Forgotten moves, learned again"
        case .young: "Reviews of moves shown again within 3 weeks"
        case .mature: "Reviews of moves shown again in 3 weeks or more"
        case .filtered: "Moves played before they were due"
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

// MARK: Move groups

/// Anki's card-count groups, in the order of the studied bar.
enum MoveGroup: CaseIterable {
    case new, learning, relearning, young, mature, suspended

    var title: String {
        switch self {
        case .new: "New"
        case .learning: "Learning"
        case .relearning: "Relearning"
        case .young: "Young"
        case .mature: "Mature"
        case .suspended: "Suspended"
        }
    }

    var color: ThemeColor {
        switch self {
        case .new: ThemeColor.new
        case .learning: ThemeColor.learning.lighter()
        case .relearning: ThemeColor.learning
        case .young: ThemeColor.learned.lighter()
        case .mature: ThemeColor.learned
        case .suspended: ThemeColor.inactive
        }
    }

    var explanation: String {
        switch self {
        case .new: "Not studied yet"
        case .learning: "In their first learning steps"
        case .relearning: "Forgotten, being learned again"
        case .young: "Shown again within 3 weeks"
        case .mature: "Shown again in 3 weeks or more"
        case .suspended: "Below alternative moves; they keep their progress"
        }
    }

    func count(_ c: CardCounts) -> Int {
        switch self {
        case .new: Int(c.new)
        case .learning: Int(c.learn)
        case .relearning: Int(c.relearn)
        case .young: Int(c.young)
        case .mature: Int(c.mature)
        case .suspended: Int(c.suspended)
        }
    }
}

/// The moves by group as one bar, like the library's studied bar.
struct MoveGroupsBar: View {
    let counts: CardCounts

    var body: some View {
        Chart(MoveGroup.allCases.filter { $0.count(counts) > 0 }, id: \.self) { group in
            BarMark(x: .value("Moves", group.count(counts)), stacking: .normalized)
                .foregroundStyle(group.color)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartPlotStyle { $0.clipShape(.capsule) }
        .frame(height: 12)
        .accessibilityHidden(true)
    }
}
