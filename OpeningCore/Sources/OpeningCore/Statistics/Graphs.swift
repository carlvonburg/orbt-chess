// Ported from Anki, rslib/src/stats/graphs/{today,card_counts,future_due,reviews,hours,buttons,
// intervals,eases,retrievability,retention}.rs (https://github.com/ankitects/anki).
// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

import Foundation

/// The cards and review log statistics are computed from (Anki's `GraphsContext`).
public struct GraphsContext: Sendable {
    public var cards: [Card]
    /// Cards never studied (Anki: cards of type New).
    public var newCount: Int
    public var revlog: [RevlogEntry]
    public var timing: SchedTiming
    public var localOffsetSecs: Int
    public var fsrs = FSRS6()

    public init(cards: [Card], newCount: Int, revlog: [RevlogEntry], timing: SchedTiming,
                localOffsetSecs: Int = TimeZone.current.secondsFromGMT()) {
        self.cards = cards
        self.newCount = newCount
        self.revlog = revlog.sorted { $0.id < $1.id }
        self.timing = timing
        self.localOffsetSecs = localOffsetSecs
    }

    var nextDayStart: Int64 { timing.nextDayAt }
    static let matureInterval = 21

    /// Time ranges of Anki's graphs.
    public enum Range: Int, CaseIterable, Identifiable, Sendable {
        case month = 30, threeMonths = 90, year = 365, all = 0
        public var id: Int { rawValue }
        public var title: String {
            switch self {
            case .month: "1 month"
            case .threeMonths: "3 months"
            case .year: "1 year"
            case .all: "All"
            }
        }
    }

    private func isScheduling(_ entry: RevlogEntry) -> Bool {
        entry.type != .manual && entry.type != .rescheduled
    }

    // MARK: Today

    public struct Today: Sendable, Equatable {
        public var answerCount = 0
        public var answerMillis = 0
        public var correctCount = 0
        public var matureCount = 0
        public var matureCorrect = 0
        public var learnCount = 0
        public var reviewCount = 0
        public var relearnCount = 0
        public var earlyReviewCount = 0
    }

    public func today() -> Today {
        var today = Today()
        let start = (nextDayStart - 86_400) * 1000
        for review in revlog where review.id >= start && isScheduling(review) {
            today.answerCount += 1
            today.answerMillis += review.time
            if review.ease > 1 { today.correctCount += 1 }
            if review.lastIvl >= Self.matureInterval {
                today.matureCount += 1
                if review.ease > 1 { today.matureCorrect += 1 }
            }
            switch review.type {
            case .learning: today.learnCount += 1
            case .review: today.reviewCount += 1
            case .relearning: today.relearnCount += 1
            case .filtered: today.earlyReviewCount += 1
            case .manual, .rescheduled: break
            }
        }
        return today
    }

    // MARK: Card counts

    public struct CardCounts: Sendable, Equatable {
        public var new = 0
        public var learn = 0
        public var relearn = 0
        public var young = 0
        public var mature = 0
        public var suspended = 0

        public var total: Int { new + learn + relearn + young + mature + suspended }
    }

    /// Excluding inactive cards: suspended ones are counted separately.
    public func cardCounts() -> CardCounts {
        var counts = CardCounts(new: newCount)
        for card in cards {
            if card.queue == .suspended {
                counts.suspended += 1
                continue
            }
            switch card.ctype {
            case .new: counts.new += 1
            case .learn: counts.learn += 1
            case .review: if card.interval < Self.matureInterval { counts.young += 1 } else { counts.mature += 1 }
            case .relearn: counts.relearn += 1
            }
        }
        return counts
    }

    // MARK: Future due

    public struct FutureDue: Sendable, Equatable {
        /// Days from today (0 = today, negative = overdue) → cards.
        public var dueByDay: [Int: Int] = [:]
        public var haveBacklog = false
        public var dailyLoad = 0
    }

    public func futureDue() -> FutureDue {
        var result = FutureDue()
        var load = 0.0
        for card in cards where card.ctype != .new && card.queue != .suspended {
            let day: Int
            if card.queue == .learn {
                day = Int((card.due - nextDayStart) / 86_400)
            } else {
                day = Int(card.due) - timing.daysElapsed
            }
            load += 1 / Double(max(card.interval, 1))
            result.haveBacklog = result.haveBacklog || day < 0
            result.dueByDay[day, default: 0] += 1
        }
        result.dailyLoad = Int(load)
        return result
    }

    // MARK: Reviews

    public struct ReviewCounts: Sendable, Equatable {
        public var learn = 0, relearn = 0, young = 0, mature = 0, filtered = 0
        public var total: Int { learn + relearn + young + mature + filtered }

        public init() {}
    }

    /// Per day (0 = today, -1 = yesterday): answer counts and milliseconds by kind.
    public func reviews() -> (count: [Int: ReviewCounts], time: [Int: ReviewCounts]) {
        var count: [Int: ReviewCounts] = [:], time: [Int: ReviewCounts] = [:]
        for review in revlog where isScheduling(review) {
            let day = Int((review.id / 1000 - nextDayStart) / 86_400)
            var c = count[day] ?? ReviewCounts(), t = time[day] ?? ReviewCounts()
            switch review.type {
            case .learning: c.learn += 1; t.learn += review.time
            case .relearning: c.relearn += 1; t.relearn += review.time
            case .review:
                if review.lastIvl < Self.matureInterval { c.young += 1; t.young += review.time }
                else { c.mature += 1; t.mature += review.time }
            case .filtered: c.filtered += 1; t.filtered += review.time
            case .manual, .rescheduled: break
            }
            count[day] = c
            time[day] = t
        }
        return (count, time)
    }

    // MARK: Hours

    public struct Hour: Sendable, Equatable {
        public var total = 0
        public var correct = 0
    }

    private func since(_ range: Range) -> Int64 {
        range == .all ? .min : (nextDayStart - 86_400 * Int64(range.rawValue)) * 1000
    }

    public func hours(_ range: Range) -> [Hour] {
        var hours = Array(repeating: Hour(), count: 24)
        let start = since(range)
        for review in revlog where review.id >= start
            && review.type != .filtered && isScheduling(review) {
            let secs = review.id / 1000 + Int64(localOffsetSecs)
            let hour = Int(((secs / 3600) % 24 + 24) % 24)
            hours[hour].total += 1
            if review.ease > 1 { hours[hour].correct += 1 }
        }
        return hours
    }

    // MARK: Answer buttons

    public struct ButtonCounts: Sendable, Equatable {
        /// Index 0 = Again ... 3 = Easy.
        public var learning = [0, 0, 0, 0]
        public var young = [0, 0, 0, 0]
        public var mature = [0, 0, 0, 0]
    }

    public func buttons(_ range: Range) -> ButtonCounts {
        var counts = ButtonCounts()
        let start = since(range)
        for review in revlog where review.id >= start && (1...4).contains(review.ease) {
            let i = review.ease - 1
            switch review.type {
            case .learning, .relearning, .filtered: counts.learning[i] += 1
            case .review:
                if review.lastIvl < Self.matureInterval { counts.young[i] += 1 } else { counts.mature[i] += 1 }
            case .manual, .rescheduled: break
            }
        }
        return counts
    }

    // MARK: Intervals, difficulty, stability, retrievability

    /// Interval in days → cards (review and relearning cards).
    public func intervals() -> [Int: Int] {
        var result: [Int: Int] = [:]
        for card in cards where card.ctype == .review || card.ctype == .relearn {
            result[card.interval, default: 0] += 1
        }
        return result
    }

    /// Rounded stability in days → cards.
    public func stability() -> [Int: Int] {
        var result: [Int: Int] = [:]
        for card in cards {
            guard let memory = card.memory else { continue }
            result[roundedInt(memory.stability), default: 0] += 1
        }
        return result
    }

    /// Difficulty as a percentage, (D - 1) / 9, in 1% bins → cards.
    public func difficulty() -> [Int: Int] {
        var result: [Int: Int] = [:]
        for card in cards {
            guard let memory = card.memory else { continue }
            result[Int(((memory.difficulty - 1) / 9 * 100).rounded(.down)), default: 0] += 1
        }
        return result
    }

    public struct Retrievability: Sendable, Equatable {
        /// Percent bin → cards.
        public var bins: [Int: Int] = [:]
        /// Average in percent over cards with a memory state.
        public var average = 0.0
        /// Estimated total knowledge: the sum of R over cards.
        public var sum = 0.0
    }

    public func retrievability() -> Retrievability {
        var result = Retrievability()
        var count = 0
        let now = Date(timeIntervalSince1970: TimeInterval(timing.now))
        for card in cards {
            guard let r = card.retrievability(at: now, fsrs: fsrs) else { continue }
            result.bins[Int((r * 100).rounded(.down)), default: 0] += 1
            result.sum += r
            count += 1
        }
        if count > 0 { result.average = result.sum * 100 / Double(count) }
        return result
    }

    // MARK: True retention

    public struct TrueRetention: Sendable, Equatable {
        public var youngPassed = 0, youngFailed = 0, maturePassed = 0, matureFailed = 0

        public init() {}

        public var young: Double? { rate(youngPassed, youngFailed) }
        public var mature: Double? { rate(maturePassed, matureFailed) }
        public var total: Double? { rate(youngPassed + maturePassed, youngFailed + matureFailed) }
        public var count: Int { youngPassed + youngFailed + maturePassed + matureFailed }

        private func rate(_ passed: Int, _ failed: Int) -> Double? {
            passed + failed > 0 ? Double(passed) / Double(passed + failed) : nil
        }
    }

    public enum RetentionPeriod: String, CaseIterable, Identifiable, Sendable {
        case today, yesterday, week, month, year, allTime
        public var id: Self { self }
        public var title: String {
            switch self {
            case .today: "Today"
            case .yesterday: "Yesterday"
            case .week: "Last week"
            case .month: "Last month"
            case .year: "Last year"
            case .allTime: "All time"
            }
        }
    }

    /// Reviews of cards with an interval of a day or more; Again fails, the rest pass.
    public func trueRetention(cardsMatching filter: ((EPD) -> Bool)? = nil) -> [RetentionPeriod: TrueRetention] {
        let day: Int64 = 86_400
        let periods: [(RetentionPeriod, Int64, Int64)] = [
            (.today, nextDayStart - day, nextDayStart),
            (.yesterday, nextDayStart - 2 * day, nextDayStart - day),
            (.week, nextDayStart - 7 * day, nextDayStart),
            (.month, nextDayStart - 30 * day, nextDayStart),
            (.year, nextDayStart - 365 * day, nextDayStart),
            (.allTime, 0, nextDayStart),
        ]
        var result = Dictionary(uniqueKeysWithValues: RetentionPeriod.allCases.map { ($0, TrueRetention()) })
        for review in revlog where review.hasRating && !review.isCramming
            && (review.type == .review || review.lastIvl <= -86_400 || review.lastIvl >= 1) {
            if let filter, !filter(review.cid) { continue }
            let secs = review.id / 1000
            for (period, start, end) in periods where secs >= start && secs < end {
                switch (review.lastIvl < Self.matureInterval, review.ease == 1) {
                case (true, true): result[period]!.youngFailed += 1
                case (true, false): result[period]!.youngPassed += 1
                case (false, true): result[period]!.matureFailed += 1
                case (false, false): result[period]!.maturePassed += 1
                }
            }
        }
        return result
    }

    // MARK: Card info

    public struct CardInfo: Sendable, Equatable {
        public var added: Date
        public var firstReview: Date?
        public var latestReview: Date?
        public var due: Date?
        public var interval: Int
        public var reps: Int
        public var lapses: Int
        public var averageMillis: Int
        public var totalMillis: Int
        public var retrievability: Double?
        public var memory: MemoryState?
        public var history: [RevlogEntry]
    }

    public func cardInfo(_ card: Card, epd: EPD) -> CardInfo {
        let history = revlog.filter { $0.cid == epd }
        let rated = history.filter(\.hasRating)
        let due: Date? = switch card.queue {
        case .learn: Date(timeIntervalSince1970: TimeInterval(card.due))
        case .review, .dayLearn: timing.date(ofDay: Int(card.due))
        case .new, .suspended: nil
        }
        let total = history.reduce(0) { $0 + $1.time }
        return CardInfo(
            added: Date(timeIntervalSince1970: TimeInterval(card.added)),
            firstReview: rated.first?.date, latestReview: rated.last?.date, due: due,
            interval: card.interval, reps: card.reps, lapses: card.lapses,
            averageMillis: rated.isEmpty ? 0 : total / rated.count, totalMillis: total,
            retrievability: card.retrievability(at: Date(timeIntervalSince1970: TimeInterval(timing.now)), fsrs: fsrs),
            memory: card.memory, history: history)
    }
}
