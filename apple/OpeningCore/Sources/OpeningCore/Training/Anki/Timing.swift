// Ported from Anki, rslib/src/scheduler/timing.rs (https://github.com/ankitects/anki).
// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// Difference: Anki counts days from the collection's creation; this counts from a fixed epoch
// (1 Jan 2020, local time), so every device and repertoire agrees on day numbers.

import Foundation

/// "Today" for scheduling: the day number and when the next day starts.
public struct SchedTiming: Sendable, Equatable {
    /// Days since the epoch, rolling over at `rolloverHour`.
    public let daysElapsed: Int
    /// Unix seconds when the next day starts.
    public let nextDayAt: Int64
    public let now: Int64

    public static let rolloverHour = 4

    public init(now: Date = .now, rolloverHour: Int = SchedTiming.rolloverHour, calendar: Calendar = .current) {
        let start = calendar.startOfDay(for: now)
        let rolloverToday = calendar.date(bySettingHour: rolloverHour, minute: 0, second: 0, of: start) ?? start
        let passed = rolloverToday <= now
        let nextDay = passed ? calendar.date(byAdding: .day, value: 1, to: rolloverToday) ?? rolloverToday : rolloverToday
        let epoch = calendar.date(from: DateComponents(year: 2020, month: 1, day: 1)) ?? Date(timeIntervalSince1970: 0)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: epoch), to: start).day ?? 0
        daysElapsed = max(0, passed ? days : days - 1)
        nextDayAt = Int64(nextDay.timeIntervalSince1970)
        self.now = Int64(now.timeIntervalSince1970)
    }

    public init(daysElapsed: Int, nextDayAt: Int64, now: Int64) {
        self.daysElapsed = daysElapsed
        self.nextDayAt = nextDayAt
        self.now = now
    }

    var secsUntilRollover: Int { max(0, Int(nextDayAt - now)) }

    /// Unix seconds when today started.
    var dayStart: Int64 { nextDayAt - Int64(secsPerDay) }

    /// Whole days from `secs` to the next day start (Anki `elapsed_days_since`).
    func daysSince(_ secs: Int64) -> Int { max(0, Int((nextDayAt - secs) / Int64(secsPerDay))) }

    /// The approximate date a day number starts.
    public func date(ofDay day: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(dayStart + Int64(day - daysElapsed) * Int64(secsPerDay)))
    }
}
