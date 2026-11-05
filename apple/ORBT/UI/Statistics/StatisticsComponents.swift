import Charts
import OpeningCoreRust
import SwiftUI

// The building blocks of the Statistics screen, after Apple's Health and Fitness: a card names
// its subject with a symbol, leads with one number and shows the chart that answers it.

/// The statistics' cards in columns, as many as fit at `minColumnWidth`, each card under the
/// shortest column so far at its own height (Android's staggered grid; SwiftUI's grids align
/// cards in rows as tall as the tallest). In order, so the first cards stay at the top.
struct MasonryLayout: Layout {
    var minColumnWidth: CGFloat = 320
    var spacing: CGFloat = 16

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minColumnWidth
        let columns = arrange(width: width, subviews: subviews)
        return CGSize(width: width, height: columns.heights.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = arrange(width: bounds.width, subviews: subviews)
        for (index, frame) in columns.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                  proposal: ProposedViewSize(frame.size))
        }
    }

    /// Each card's frame, and the height of each column.
    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], heights: [CGFloat]) {
        let count = max(1, Int((width + spacing) / (minColumnWidth + spacing)))
        let columnWidth = (width - spacing * CGFloat(count - 1)) / CGFloat(count)
        var heights = Array(repeating: CGFloat(0), count: count)
        var frames: [CGRect] = []
        for subview in subviews {
            let column = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            let height = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            let y = heights[column] == 0 ? 0 : heights[column] + spacing
            frames.append(CGRect(x: CGFloat(column) * (columnWidth + spacing), y: y, width: columnWidth, height: height))
            heights[column] = y + height
        }
        return (frames, heights)
    }
}

/// A card of the Statistics grid: a group box titled with its subject.
struct StatCard<Content: View>: View {
    let title: String
    let systemImage: String
    var color: ThemeColor?
    @ViewBuilder let content: Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) { content }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 4)
        } label: {
            Label(title, systemImage: systemImage)
                .foregroundStyle(color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.tint))
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

/// A small metric in a row of several.
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

/// A line of facts under a chart.
struct Footnote: View {
    let text: String

    var body: some View {
        Text(text).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
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
        case .all: "Everything due"
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

    /// The end of the bar a day falls in.
    static func binEnd(_ day: Int, _ unit: Calendar.Component) -> Date {
        Calendar.current.dateInterval(of: unit, for: date(day))?.end ?? date(day + 1)
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

/// "8 min", "1 hr, 20 min", "40 sec".
func durationText(millis: Int) -> String {
    let secs = Double(millis) / 1000
    let style: Duration.UnitsFormatStyle = secs < 60
        ? .units(allowed: [.seconds], width: .abbreviated)
        : .units(allowed: [.hours, .minutes], width: .abbreviated)
    return Duration.seconds(secs.rounded()).formatted(style)
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
        .frame(height: 10)
        .accessibilityHidden(true)
    }
}
