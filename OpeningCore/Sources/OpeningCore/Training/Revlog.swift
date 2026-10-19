import Foundation

/// The review log file `<Name>.otlog.jsonl`: one JSON entry per line, append-only.
public enum RevlogFile {
    public static let fileExtension = "otlog.jsonl"

    /// Entries in id order; unreadable lines are skipped.
    public static func decode(_ data: Data) -> [RevlogEntry] {
        let decoder = JSONDecoder()
        var result: [RevlogEntry] = []
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            if let entry = try? decoder.decode(RevlogEntry.self, from: Data(line)) { result.append(entry) }
        }
        return result.sorted { $0.id < $1.id }
    }

    public static func encode(_ entries: [RevlogEntry]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for entry in entries {
            guard let line = try? encoder.encode(entry) else { continue }
            data.append(line)
            data.append(UInt8(ascii: "\n"))
        }
        return data
    }

    /// Union by id, for logs written on two devices.
    public static func merged(_ a: [RevlogEntry], _ b: [RevlogEntry]) -> [RevlogEntry] {
        var byID: [Int64: RevlogEntry] = [:]
        for entry in a + b { byID[entry.id] = entry }
        return byID.values.sorted { $0.id < $1.id }
    }
}

extension Sidecar {
    /// Progress without opening the PGN: the stored cards, out of the positions counted in the
    /// last summary.
    public var estimatedProgress: Trainer.Progress {
        let active = studyCards.values.filter { $0.queue != .suspended }
        var p = Trainer.Progress(cards: max(summary?.cardCount ?? 0, active.count))
        for card in active { p.add(card) }
        p.suspended = summary?.suspendedCount ?? (studyCards.count - active.count)
        return p
    }

    /// When the next card falls due after today's are done: a learning step later today, or
    /// the start of the day a review is due.
    public func nextDue(timing: SchedTiming) -> Date? {
        var next: Int64?
        for card in studyCards.values {
            let at: Int64
            switch card.queue {
            case .learn: at = card.due
            case .review, .dayLearn: at = timing.nextDayAt + (max(card.due, Int64(timing.daysElapsed) + 1) - Int64(timing.daysElapsed) - 1) * 86_400
            default: continue
            }
            guard at > timing.now else { continue }
            next = min(next ?? at, at)
        }
        return next.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    /// When the learning cards waiting for a later step are due, soonest first.
    public func laterLearningDues(timing: SchedTiming) -> [Date] {
        studyCards.values.filter { $0.queue == .learn && $0.due > timing.now }
            .map { Date(timeIntervalSince1970: TimeInterval($0.due)) }
            .sorted()
    }

    /// Reviews due tomorrow (Anki's "Due tomorrow" in today's statistics).
    public func dueTomorrow(timing: SchedTiming) -> Int {
        let tomorrow = Int64(timing.daysElapsed) + 1
        return studyCards.values.filter { ($0.queue == .review || $0.queue == .dayLearn) && $0.due == tomorrow }.count
    }

    /// New / learning / review counts without opening the PGN, as Anki's deck list computes
    /// them: learning within the learn-ahead limit, reviews and new cards within today's limits.
    public func estimatedStudyCounts(config: DeckConfig, timing: SchedTiming) -> CardQueues.Counts {
        let today = timing.daysElapsed
        let remaining = RemainingLimits(config: config, limits: limits ?? DeckLimits(), stats: studyStats ?? DeckStudyStats(), today: today)
        var intraday = 0, interday = 0, review = 0
        let cutoff = timing.now + Int64(config.learnAheadSecs)
        for card in studyCards.values {
            switch card.queue {
            case .learn where card.due <= cutoff: intraday += 1
            case .dayLearn where card.due <= Int64(today): interday += 1
            case .review where card.due <= Int64(today): review += 1
            default: break
            }
        }
        interday = min(interday, remaining.review)
        let reviewLeft = remaining.review - interday
        review = min(review, reviewLeft)
        let unseen = max(0, (summary?.cardCount ?? 0) - studyCards.values.filter { $0.queue != .suspended }.count)
        var new = min(unseen, remaining.new)
        if remaining.capNewToReview { new = min(new, reviewLeft - review) }
        return CardQueues.Counts(new: max(new, 0), learning: intraday + interday, review: review)
    }
}
