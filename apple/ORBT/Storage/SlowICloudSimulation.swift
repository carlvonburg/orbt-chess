#if DEBUG
import Foundation

/// DEBUG builds only, for seeing the launch while iCloud Drive is slow on a simulator that is not
/// signed in to iCloud: `-ORBTSimulateSlowICloud <seconds>` as a launch argument. The device's
/// folder is used as if it were iCloud Drive's: finding it takes that long (as
/// `url(forUbiquityContainerIdentifier:)` after an install or update), and its repertoires are
/// listed that much later again (as iCloud Drive's files arriving), when the listing is complete.
nonisolated enum SlowICloudSimulation {
    static let seconds: Double? = {
        let value = UserDefaults.standard.double(forKey: "ORBTSimulateSlowICloud")
        return value > 0 ? value : nil
    }()
}
#endif
