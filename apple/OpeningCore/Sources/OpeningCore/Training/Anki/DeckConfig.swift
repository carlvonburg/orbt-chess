// Defaults from Anki, rslib/src/deckconfig/mod.rs (https://github.com/ankitects/anki).
// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

import Foundation

/// A deck options preset. Anki's defaults, with FSRS enabled.
public struct DeckConfig: Sendable, Equatable {
    public enum LeechAction: Sendable { case suspend, tagOnly }

    public var newPerDay = 20
    public var reviewsPerDay = 200
    public var newCardsIgnoreReviewLimit = false
    public var learnSteps: [Double] = [1, 10]
    public var relearnSteps: [Double] = [10]
    public var graduatingIntervalGood = 1
    public var graduatingIntervalEasy = 4
    public var initialEase = 2.5
    public var easyMultiplier = 1.3
    public var hardMultiplier = 1.2
    public var lapseMultiplier = 0.0
    public var intervalMultiplier = 1.0
    public var maximumReviewInterval = 36500
    public var minimumLapseInterval = 1
    public var leechThreshold = 8
    public var leechAction = LeechAction.tagOnly
    public var desiredRetention = 0.9
    public var capAnswerTimeToSecs = 60
    /// Collection settings.
    public var learnAheadSecs = 1200
    public var fsrsShortTermWithStepsEnabled = false

    public init() {}
}
