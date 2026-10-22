import Foundation
import OpeningCoreRust

/// The analysis engine's settings, edited in Settings (as Lichess's "Search time" and
/// "Multiple lines").
enum EngineDefaults {
    static let searchTimeKey = "engine.searchTime"
    static let linesKey = "engine.lines"
    static let cloudKey = "engine.cloud"
    static let fullNetworkKey = "engine.fullNetwork"

    static let searchTimes = 1...30
    static let lineCounts = 1...Int(maxEngineLines())

    /// Seconds per position.
    static var searchTime: Int { UserDefaults.standard.object(forKey: searchTimeKey) as? Int ?? 6 }
    static var lines: Int { UserDefaults.standard.object(forKey: linesKey) as? Int ?? 3 }
    /// Show Lichess's cloud eval first, and skip the engine where it is deep.
    static var cloud: Bool { UserDefaults.standard.object(forKey: cloudKey) as? Bool ?? true }
    /// Use the full network once it is downloaded.
    static var fullNetwork: Bool { UserDefaults.standard.object(forKey: fullNetworkKey) as? Bool ?? true }

    /// Half the cores, at most four: fast, without draining a phone's battery.
    static var threads: Int { min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2)) }

    static var settings: EngineSettings {
        var settings = defaultEngineSettings()
        settings.lines = UInt32(lines.clamped(to: lineCounts))
        settings.movetimeMs = UInt32(searchTime.clamped(to: searchTimes) * 1000)
        settings.threads = UInt32(threads)
        settings.cloud = cloud
        return settings
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
