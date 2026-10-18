// Mirrors Anki's card scheduling fields (rslib/src/card/mod.rs) and revlog entry
// (rslib/src/revlog/mod.rs), https://github.com/ankitects/anki.
// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

import Foundation

/// The study state of one card: a position where it's your move. A card that was never
/// studied is New and has no stored `Card`.
public struct Card: Codable, Sendable, Hashable {
    public enum CardType: Int, Codable, Sendable {
        case new = 0, learn, review, relearn
    }

    public enum Queue: Int, Codable, Sendable {
        case suspended = -1, new = 0, learn = 1, review = 2, dayLearn = 3
    }

    public var id: Int64
    public var ctype: CardType
    public var queue: Queue
    /// Learn queue: unix seconds. Review and day-learn queues: day number. New: position.
    public var due: Int64
    /// Days.
    public var interval: Int
    /// Permille, 2500 = 2.5.
    public var easeFactor: Int
    public var reps: Int
    public var lapses: Int
    public var remainingSteps: Int
    public var memory: MemoryState?
    /// Unix seconds.
    public var lastReviewTime: Int64?
    /// New-queue position before the card was first studied.
    public var originalPosition: Int?
    /// Unix seconds when the card was first studied (Anki: card creation).
    public var added: Int64
    /// Anki's "leech" tag.
    public var leech: Bool?

    public init(id: Int64, position: Int, added: Int64) {
        self.id = id
        ctype = .new
        queue = .new
        due = Int64(position)
        interval = 0
        easeFactor = 0
        reps = 0
        lapses = 0
        remainingSteps = 0
        self.added = added
    }

    /// Stable id from the position, so every device agrees.
    public static func id(for epd: EPD) -> Int64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in epd.rawValue.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return Int64(bitPattern: hash & 0x7FFF_FFFF_FFFF_FFFF)
    }

    /// Anki: interval ≥ 21 days.
    public var isMature: Bool { (ctype == .review || ctype == .relearn) && interval >= 21 }
    public var isLearning: Bool { queue == .learn || queue == .dayLearn }

    /// Probability of recall now (FSRS).
    public func retrievability(at now: Date, fsrs: FSRS6 = FSRS6()) -> Double? {
        guard let memory, let lastReviewTime else { return nil }
        let days = max(0, now.timeIntervalSince1970 - TimeInterval(lastReviewTime)) / 86_400
        return fsrs.retrievability(daysElapsed: days, stability: memory.stability)
    }
}

/// One answer, as in Anki's revlog table.
public struct RevlogEntry: Codable, Sendable, Hashable {
    /// Milliseconds since 1970 when answered; the key.
    public var id: Int64
    /// The card's EPD.
    public var cid: EPD
    /// 1 again, 2 hard, 3 good, 4 easy; 0 for a manual change.
    public var ease: Int
    /// After the answer: positive days, negative seconds.
    public var ivl: Int
    public var lastIvl: Int
    /// FSRS difficulty shifted, ×1000; or the ease factor in permille.
    public var factor: Int
    /// Answer time in milliseconds, capped.
    public var time: Int
    public var type: RevlogReviewKind

    public init(id: Int64, cid: EPD, ease: Int, ivl: Int, lastIvl: Int, factor: Int, time: Int, type: RevlogReviewKind) {
        self.id = id
        self.cid = cid
        self.ease = ease
        self.ivl = ivl
        self.lastIvl = lastIvl
        self.factor = factor
        self.time = time
        self.type = type
    }

    public var date: Date { Date(timeIntervalSince1970: TimeInterval(id) / 1000) }
    public var hasRating: Bool { ease > 0 }
    /// Cramming entries don't affect scheduling.
    public var isCramming: Bool { type == .filtered && factor == 0 }
}
