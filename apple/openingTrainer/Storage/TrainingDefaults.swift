import Foundation
import OpeningCore

/// The default daily-practice preset (Anki's "Default" preset), edited in a repertoire's options. A
/// repertoire can override the limits and the practice mode.
enum TrainingDefaults {
    static let newPerDayKey = "training.newPerDay"
    static let reviewsPerDayKey = "training.reviewsPerDay"
    static let practiceModeKey = "training.practiceMode"
    /// New moves added to today's limit by "Learn N New Moves" (Anki's custom study).
    static let learnMoreCount = 5

    static var newPerDay: Int { UserDefaults.standard.object(forKey: newPerDayKey) as? Int ?? DeckConfig().newPerDay }
    static var reviewsPerDay: Int { UserDefaults.standard.object(forKey: reviewsPerDayKey) as? Int ?? DeckConfig().reviewsPerDay }
    static var practiceMode: PracticeMode {
        UserDefaults.standard.string(forKey: practiceModeKey).flatMap(PracticeMode.init(rawValue:)) ?? .default
    }

    static var config: DeckConfig {
        var config = DeckConfig()
        config.newPerDay = newPerDay
        config.reviewsPerDay = reviewsPerDay
        return config
    }
}
