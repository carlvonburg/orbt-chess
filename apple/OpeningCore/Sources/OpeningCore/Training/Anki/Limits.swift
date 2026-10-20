// Ported from Anki, rslib/src/decks/limits.rs and rslib/src/decks/stats.rs
// (https://github.com/ankitects/anki).
// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// A repertoire is one deck without subdecks, so the limit tree is a single node.

import Foundation

/// A limit that applies on one day only ("Today only" in Anki's deck options).
public struct DayLimit: Codable, Sendable, Hashable {
    public var limit: Int
    public var today: Int

    public init(limit: Int, today: Int) {
        self.limit = limit
        self.today = today
    }
}

/// Per-deck overrides ("This deck" and "Today only").
public struct DeckLimits: Codable, Sendable, Hashable {
    public var newLimit: Int?
    public var reviewLimit: Int?
    public var newLimitToday: DayLimit?
    public var reviewLimitToday: DayLimit?

    public init() {}

    public var isEmpty: Bool { self == DeckLimits() }

    func currentNewLimit(today: Int) -> Int? {
        if let t = newLimitToday, t.today == today { return t.limit }
        return newLimit
    }

    func currentReviewLimit(today: Int) -> Int? {
        if let t = reviewLimitToday, t.today == today { return t.limit }
        return reviewLimit
    }
}

/// Cards studied today; reset lazily when the day changes.
public struct DeckStudyStats: Codable, Sendable, Hashable {
    public var lastDayStudied = 0
    public var newStudied = 0
    public var reviewStudied = 0
    public var millisecondsStudied = 0

    public init() {}

    /// (new, review) studied today.
    public func counts(today: Int) -> (new: Int, review: Int) {
        lastDayStudied == today ? (newStudied, reviewStudied) : (0, 0)
    }

    mutating func resetIfDayChanged(today: Int) {
        if lastDayStudied != today {
            self = DeckStudyStats()
            lastDayStudied = today
        }
    }

    /// Anki counts by the card's queue before answering: new → new, review/day-learn →
    /// review, intraday learning → nothing.
    public mutating func recordAnswer(fromQueue: Card.Queue, millis: Int, today: Int) {
        resetIfDayChanged(today: today)
        switch fromQueue {
        case .new: newStudied += 1
        case .review, .dayLearn: reviewStudied += 1
        default: break
        }
        millisecondsStudied += millis
    }

    /// Custom study "increase today's limit": studied counts may go negative.
    public mutating func extendLimits(today: Int, new: Int, review: Int) {
        resetIfDayChanged(today: today)
        newStudied -= new
        reviewStudied -= review
    }

    /// Two devices studied the same day: keep the larger counts.
    func merged(with other: DeckStudyStats) -> DeckStudyStats {
        if lastDayStudied != other.lastDayStudied { return lastDayStudied > other.lastDayStudied ? self : other }
        var result = self
        result.newStudied = max(newStudied, other.newStudied)
        result.reviewStudied = max(reviewStudied, other.reviewStudied)
        result.millisecondsStudied = max(millisecondsStudied, other.millisecondsStudied)
        return result
    }
}

/// How many more new and review cards may be shown today.
public struct RemainingLimits: Sendable, Equatable {
    public var review: Int
    public var new: Int
    public var capNewToReview: Bool

    public init(review: Int, new: Int, capNewToReview: Bool) {
        self.review = review
        self.new = new
        self.capNewToReview = capNewToReview
    }

    /// Filtered decks have no limits.
    public static let unlimited = RemainingLimits(review: 9999, new: 9999, capNewToReview: false)

    public init(config: DeckConfig, limits: DeckLimits, stats: DeckStudyStats, today: Int) {
        var reviewLimit = limits.currentReviewLimit(today: today) ?? config.reviewsPerDay
        var newLimit = limits.currentNewLimit(today: today) ?? config.newPerDay
        let (newToday, reviewToday) = stats.counts(today: today)
        reviewLimit -= reviewToday
        newLimit -= newToday
        if !config.newCardsIgnoreReviewLimit {
            reviewLimit -= newToday
            newLimit = min(newLimit, reviewLimit)
        }
        review = max(reviewLimit, 0)
        new = max(newLimit, 0)
        capNewToReview = !config.newCardsIgnoreReviewLimit
    }

    mutating func decrementReview() {
        review = max(review - 1, 0)
        if capNewToReview { new = min(new, review) }
    }

    mutating func decrementNew() { new = max(new - 1, 0) }
}
