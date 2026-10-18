import Foundation

/// Statistics that combine Anki's memory model with the repertoire tree (not in Anki).
public enum ChessStats {
    /// Expected recall in games: the chance you know your move in the positions you will
    /// actually meet. Σ reach × R over your card positions, divided by Σ reach; a card never
    /// studied counts as R = 0.
    public static func expectedRecall(cards: [EPD: Card], reach: [EPD: Double], now: Date, fsrs: FSRS6 = FSRS6()) -> Double? {
        var weighted = 0.0, total = 0.0
        for (epd, r) in reach where r > 0 {
            total += r
            weighted += r * (cards[epd]?.retrievability(at: now, fsrs: fsrs) ?? 0)
        }
        return total > 0 ? weighted / total : nil
    }

    public struct WeakMove: Sendable, Identifiable, Equatable {
        public var epd: EPD
        public var lapses: Int
        public var retrievability: Double?
        public var leech: Bool
        public var id: EPD { epd }
    }

    /// Moves you forget most: leeches and most lapses first, then lowest recall.
    public static func weakestMoves(cards: [EPD: Card], now: Date, limit: Int = 10, fsrs: FSRS6 = FSRS6()) -> [WeakMove] {
        cards.compactMap { epd, card -> WeakMove? in
            let r = card.retrievability(at: now, fsrs: fsrs)
            guard card.lapses > 0 || (r ?? 1) < 0.85 else { return nil }
            return WeakMove(epd: epd, lapses: card.lapses, retrievability: r, leech: card.leech == true)
        }
        .sorted { a, b in
            if a.leech != b.leech { return a.leech }
            if a.lapses != b.lapses { return a.lapses > b.lapses }
            return (a.retrievability ?? 1) < (b.retrievability ?? 1)
        }
        .prefix(limit).map { $0 }
    }
}

extension Trainer {
    /// The opening branches for per-branch statistics: the positions after the opponent's
    /// first move (for White, after your first move and their reply).
    public func openingBranches() -> [NodeID] {
        var result: [NodeID] = []
        var stack = [RepertoireTree.rootID]
        while let id = stack.popLast() {
            guard let node = tree[id] else { continue }
            if node.move != nil && node.sideToMove == color {
                result.append(id)
                continue
            }
            stack.append(contentsOf: next(after: id).filter(trainable.contains))
        }
        return result
    }
}
