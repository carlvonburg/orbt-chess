#if DEBUG
import Foundation

/// DEBUG builds only, for seeing the launch while iCloud Drive is slow on a device that is not
/// signed in to iCloud: `-ORBTSimulateSlowICloud <seconds>` as a launch argument. The device's
/// folder is used as if it were iCloud Drive's: finding it takes that long (as
/// `url(forUbiquityContainerIdentifier:)` after an install or update), and its repertoires are
/// listed that much later again (as iCloud Drive's files arriving), when the listing is complete.
/// Sync does not start, and the library is not remembered for the next launch.
///
/// With `-ORBTSimulateLaunch returning|updating|new` as well (a Mac whose own repertoires must
/// stay untouched), the folder is a scratch one in the app's temporary folder, with one sample
/// repertoire, and the launch is the one named: the sample remembered from the last launch, a
/// repertoire set up before without the library remembered (an update from 1.0.2), or nothing.
nonisolated enum SlowICloudSimulation {
    enum Launch: String {
        case returning, updating, new
    }

    static let seconds: Double? = {
        let value = UserDefaults.standard.double(forKey: "ORBTSimulateSlowICloud")
        return value > 0 ? value : nil
    }()

    static let launch: Launch? = seconds == nil ? nil
        : UserDefaults.standard.string(forKey: "ORBTSimulateLaunch").flatMap(Launch.init)

    /// The scratch folder of `launch`.
    static var scratchFolder: URL {
        URL.temporaryDirectory.appending(path: "SlowICloudSimulation", directoryHint: .isDirectory)
    }

    static let sampleName = "Sample"
}
#endif
