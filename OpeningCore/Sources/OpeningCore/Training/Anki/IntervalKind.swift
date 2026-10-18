// Ported from Anki, rslib/src/scheduler/states/interval_kind.rs (https://github.com/ankitects/anki).
// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

import Foundation

enum IntervalKind: Equatable, Sendable {
    case secs(Int)
    case days(Int)

    /// Converts second-based intervals that pass the day boundary into days.
    func maybeAsDays(secsUntilRollover: Int) -> IntervalKind {
        if case .secs(let secs) = self, secs >= secsUntilRollover {
            return .days((secs - secsUntilRollover) / secsPerDay + 1)
        }
        return self
    }

    var asSeconds: Int {
        switch self {
        case .secs(let secs): secs
        case .days(let days): days * secsPerDay
        }
    }

    /// Revlog encoding: positive days, negative seconds.
    var asRevlogInterval: Int {
        switch self {
        case .days(let days): days
        case .secs(let secs): -secs
        }
    }
}
