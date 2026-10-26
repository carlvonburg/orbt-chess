import Foundation
import OpeningCoreRust

/// The default daily-practice preset (Anki's "Default" preset), edited in Settings. A
/// repertoire can override the limits and the practice mode.
enum TrainingDefaults {
    static let newPerDayKey = "training.newPerDay"
    static let reviewsPerDayKey = "training.reviewsPerDay"
    static let practiceModeKey = "training.practiceMode"
    /// New moves added to today's limit by "Learn N New Moves" (Anki's custom study).
    static let learnMoreCount = 5

    /// Anki's preset values (steps, retention), from the core.
    static let preset = ankiPreset()

    static var newPerDay: Int { UserDefaults.standard.object(forKey: newPerDayKey) as? Int ?? Int(preset.newPerDay) }
    static var reviewsPerDay: Int { UserDefaults.standard.object(forKey: reviewsPerDayKey) as? Int ?? Int(preset.reviewsPerDay) }
    static var practiceMode: PracticeMode {
        UserDefaults.standard.string(forKey: practiceModeKey).flatMap(PracticeMode.init(rawValue:)) ?? .default
    }

    static var studyDefaults: StudyDefaults {
        StudyDefaults(newPerDay: Int64(newPerDay), reviewsPerDay: Int64(reviewsPerDay), practiceMode: practiceMode)
    }
}
