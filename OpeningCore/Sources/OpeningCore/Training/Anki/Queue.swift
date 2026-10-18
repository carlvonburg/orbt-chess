// Ported from Anki, rslib/src/scheduler/queue/{mod,main,learning}.rs and
// rslib/src/scheduler/queue/builder/{mod,gathering,sorting,intersperser}.rs
// (https://github.com/ankitects/anki).
// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// Differences: one deck, no burying, Anki's default orders only. Reviews due the same day are
// ordered by a priority (how often the position is reached) instead of a random hash, and a
// card may be removed from anywhere in the queue, because one chess line answers several cards.

import Foundation

public struct CardQueues: Sendable {
    public struct Counts: Sendable, Equatable {
        public var new = 0
        public var learning = 0
        public var review = 0

        public var total: Int { new + learning + review }

        public init(new: Int = 0, learning: Int = 0, review: Int = 0) {
            self.new = new
            self.learning = learning
            self.review = review
        }
    }

    public enum Kind: Sendable, Equatable {
        case new, learning, review
    }

    enum MainKind: Sendable, Equatable {
        case new, review, interdayLearning
    }

    struct MainEntry: Sendable, Equatable {
        var epd: EPD
        var kind: MainKind
    }

    struct LearningEntry: Sendable, Equatable {
        var due: Int64
        var epd: EPD
        var reps: Int

        /// Previously attempted cards first, then by due.
        func precedes(_ other: LearningEntry) -> Bool {
            let a = (reps == 0 ? 1 : 0), b = (other.reps == 0 ? 1 : 0)
            return a != b ? a < b : due < other.due
        }
    }

    public private(set) var counts = Counts()
    var main: [MainEntry] = []
    var intradayLearning: [LearningEntry] = []
    public let currentDay: Int
    let learnAheadSecs: Int64
    var currentLearningCutoff: Int64

    var learnAheadCutoff: Int64 { currentLearningCutoff + learnAheadSecs }

    /// Builds the queue for today.
    /// - cards: studied cards by position.
    /// - newCards: positions not studied yet, in new-card order (Anki's "position").
    /// - priority: higher first among reviews due the same day.
    public init(cards: [EPD: Card], newCards: [EPD], limits: RemainingLimits, timing: SchedTiming,
                learnAheadSecs: Int = 1200, priority: (EPD) -> Double = { _ in 0 }) {
        currentDay = timing.daysElapsed
        self.learnAheadSecs = Int64(learnAheadSecs)
        currentLearningCutoff = timing.now
        var limits = limits

        // 1. intraday learning: no limit
        var intraday: [LearningEntry] = []
        var dayLearning: [(EPD, Card)] = []
        var reviews: [(EPD, Card)] = []
        for (epd, card) in cards {
            switch card.queue {
            case .learn where card.due <= timing.nextDayAt:
                intraday.append(LearningEntry(due: card.due, epd: epd, reps: card.reps))
            case .dayLearn where card.due <= Int64(timing.daysElapsed):
                dayLearning.append((epd, card))
            case .review where card.due <= Int64(timing.daysElapsed):
                reviews.append((epd, card))
            default:
                break
            }
        }
        intraday.sort { $0.precedes($1) }

        // 2. interday learning, then 3. reviews: "due date" order, sharing the review limit
        func dueOrder(_ a: (EPD, Card), _ b: (EPD, Card)) -> Bool {
            if a.1.due != b.1.due { return a.1.due < b.1.due }
            let pa = priority(a.0), pb = priority(b.0)
            if pa != pb { return pa > pb }
            return a.1.id < b.1.id
        }
        var gatheredDayLearning: [MainEntry] = []
        for (epd, _) in dayLearning.sorted(by: dueOrder) where limits.review > 0 {
            gatheredDayLearning.append(MainEntry(epd: epd, kind: .interdayLearning))
            limits.decrementReview()
        }
        var gatheredReviews: [MainEntry] = []
        for (epd, _) in reviews.sorted(by: dueOrder) where limits.review > 0 {
            gatheredReviews.append(MainEntry(epd: epd, kind: .review))
            limits.decrementReview()
        }

        // 4. new cards in position order
        var gatheredNew: [MainEntry] = []
        for epd in newCards where limits.new > 0 && cards[epd] == nil {
            gatheredNew.append(MainEntry(epd: epd, kind: .new))
            limits.decrementNew()
        }

        let cutoff = timing.now + Int64(learnAheadSecs)
        counts = Counts(new: gatheredNew.count,
                        learning: intraday.filter { $0.due <= cutoff }.count + gatheredDayLearning.count,
                        review: gatheredReviews.count)
        // Anki defaults: interday learning and new cards both "mix with reviews"
        let withInterday = Self.intersperse(gatheredReviews, gatheredDayLearning)
        main = Self.intersperse(withInterday, gatheredNew)
        intradayLearning = intraday
    }

    /// A filtered deck with rescheduling (Anki's custom study): every card in `epds`, due or
    /// not, in random order and without limits. Learning cards are shown first.
    public init(filtered epds: [EPD], cards: [EPD: Card], timing: SchedTiming, learnAheadSecs: Int = 1200) {
        currentDay = timing.daysElapsed
        self.learnAheadSecs = Int64(learnAheadSecs)
        currentLearningCutoff = timing.now
        var rng = SplitMix64(seed: UInt64(timing.daysElapsed) &* 2_654_435_761)
        var learning: [LearningEntry] = []
        var mainEntries: [MainEntry] = []
        for epd in epds {
            guard let card = cards[epd] else {
                mainEntries.append(MainEntry(epd: epd, kind: .new))
                continue
            }
            switch card.queue {
            case .suspended: continue
            case .learn: learning.append(LearningEntry(due: timing.now, epd: epd, reps: card.reps))
            case .dayLearn: mainEntries.append(MainEntry(epd: epd, kind: .interdayLearning))
            case .new: mainEntries.append(MainEntry(epd: epd, kind: .new))
            case .review: mainEntries.append(MainEntry(epd: epd, kind: .review))
            }
        }
        mainEntries.shuffle(using: &rng)
        main = mainEntries
        intradayLearning = learning
        counts = Counts(new: mainEntries.filter { $0.kind == .new }.count,
                        learning: learning.count + mainEntries.filter { $0.kind == .interdayLearning }.count,
                        review: mainEntries.filter { $0.kind == .review }.count)
    }

    /// Evenly mixes `two` into `one`.
    static func intersperse<T>(_ one: [T], _ two: [T]) -> [T] {
        let ratio = Double(one.count + 1) / Double(two.count + 1)
        var result: [T] = []
        result.reserveCapacity(one.count + two.count)
        var i1 = 0, i2 = 0
        while i1 < one.count || i2 < two.count {
            if i1 < one.count && i2 < two.count {
                if Double(i2 + 1) * ratio < Double(i1 + 1) {
                    result.append(two[i2]); i2 += 1
                } else {
                    result.append(one[i1]); i1 += 1
                }
            } else if i1 < one.count {
                result.append(one[i1]); i1 += 1
            } else {
                result.append(two[i2]); i2 += 1
            }
        }
        return result
    }

    // MARK: Iterating

    /// The cards in the order they will be shown: intraday learning due now, the main queue,
    /// then learning cards due within the learn-ahead limit.
    public var ordered: [(EPD, Kind)] {
        let now = intradayLearning.filter { $0.due <= currentLearningCutoff }.map { ($0.epd, Kind.learning) }
        let mainItems = main.map { entry -> (EPD, Kind) in
            switch entry.kind {
            case .new: (entry.epd, .new)
            case .review: (entry.epd, .review)
            case .interdayLearning: (entry.epd, .learning)
            }
        }
        let ahead = intradayLearning.filter { $0.due > currentLearningCutoff && $0.due <= learnAheadCutoff }
            .map { ($0.epd, Kind.learning) }
        return now + mainItems + ahead
    }

    public var next: (EPD, Kind)? { ordered.first }

    public func contains(_ epd: EPD) -> Bool { ordered.contains { $0.0 == epd } }

    public func kind(of epd: EPD) -> Kind? { ordered.first { $0.0 == epd }?.1 }

    /// The earliest learning card due later today, beyond the learn-ahead limit.
    public var nextLearningDue: Date? {
        intradayLearning.map(\.due).filter { $0 > learnAheadCutoff }.min()
            .map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    // MARK: Updating

    /// Removes a card that is about to be answered, wherever it is.
    public mutating func remove(_ epd: EPD) {
        if let i = intradayLearning.firstIndex(where: { $0.epd == epd }) {
            let entry = intradayLearning.remove(at: i)
            if entry.due <= learnAheadCutoff { counts.learning = max(counts.learning - 1, 0) }
        } else if let i = main.firstIndex(where: { $0.epd == epd }) {
            switch main.remove(at: i).kind {
            case .new: counts.new -= 1
            case .review: counts.review -= 1
            case .interdayLearning: counts.learning = max(counts.learning - 1, 0)
            }
        }
    }

    /// After answering: puts a learning card due later today back, not right in front.
    public mutating func answered(_ card: Card, epd: EPD, timing: SchedTiming) {
        if card.queue == .learn, card.due < timing.nextDayAt {
            var entry = LearningEntry(due: card.due, epd: epd, reps: card.reps)
            let cutoff = learnAheadCutoff
            // shown again immediately? place it after the next learning card instead
            if entry.due <= cutoff && main.isEmpty, let next = intradayLearning.first,
               next.due >= entry.due && next.due + 1 < cutoff {
                entry.due = next.due + 1
            }
            insertIntradayLearning(entry)
        }
        updateLearningCutoff(now: timing.now)
    }

    private mutating func insertIntradayLearning(_ entry: LearningEntry) {
        if entry.due <= learnAheadCutoff { counts.learning += 1 }
        let index = intradayLearning.firstIndex { entry.precedes($0) } ?? intradayLearning.endIndex
        intradayLearning.insert(entry, at: index)
    }

    /// Moves the cutoff to now and counts learning cards that came within learn-ahead.
    public mutating func updateLearningCutoff(now: Int64) {
        let lastAhead = learnAheadCutoff
        currentLearningCutoff = max(currentLearningCutoff, now)
        let newAhead = learnAheadCutoff
        counts.learning += intradayLearning.filter { $0.due > lastAhead && $0.due <= newAhead }.count
    }
}
