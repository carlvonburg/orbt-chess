import Foundation

/// Consecutive days with answers, from the same days as the Calendar (Anki's days, starting at
/// 4 AM). Not part of Anki itself; the Review Heatmap add-on shows the same numbers.
public struct Streak: Sendable, Equatable {
    /// Days in a row up to today, or up to yesterday while today has no answers yet.
    public var current = 0
    public var longest = 0
    public var studiedToday = false

    public init(current: Int = 0, longest: Int = 0, studiedToday: Bool = false) {
        self.current = current
        self.longest = longest
        self.studiedToday = studiedToday
    }

    /// `days`: days with answers, 0 = today, -1 = yesterday.
    public init(days: Set<Int>) {
        studiedToday = days.contains(0)
        var day = studiedToday ? 0 : -1
        while days.contains(day) {
            current += 1
            day -= 1
        }
        var run = 0
        var previous: Int?
        for day in days.sorted() {
            run = previous == day - 1 ? run + 1 : 1
            longest = max(longest, run)
            previous = day
        }
    }
}

extension GraphsContext {
    public func streak() -> Streak {
        Streak(days: Set(reviews().count.filter { $0.value.total > 0 }.keys))
    }
}
