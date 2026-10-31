import OpeningCoreRust
import StoreKit
import SwiftUI

/// Asks for a rating once the user has studied on three different days: after saving in Browse,
/// or at the end of a line in Study. Once per app version and never during the tour; the system
/// decides whether its prompt shows (at most three times a year). Settings links to the review
/// page at any time.
enum ReviewPrompt {
    static let daysKey = "reviewPromptDays"
    static let askedVersionKey = "reviewPromptAskedVersion"
    static let daysNeeded = 3

    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private static var days: [Int] { UserDefaults.standard.array(forKey: daysKey) as? [Int] ?? [] }

    /// A move answered in Study: today counts as a day studied.
    static func studied(timing: SchedTiming = SchedTiming()) {
        let today = Int(timing.daysElapsed)
        guard days.count < daysNeeded, !days.contains(today) else { return }
        UserDefaults.standard.set(days + [today], forKey: daysKey)
    }

    static var isDue: Bool {
        days.count >= daysNeeded
            && UserDefaults.standard.string(forKey: askedVersionKey) != version
            // Offered and never started (`ready`) is not in the tour.
            && [.off, .ready].contains(Tour.current)
    }

    /// Asks for a rating when it is due.
    static func ask(_ requestReview: RequestReviewAction) {
        guard isDue else { return }
        UserDefaults.standard.set(version, forKey: askedVersionKey)
        requestReview()
    }
}
