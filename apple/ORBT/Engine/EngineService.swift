import Foundation
import Observation
import OpeningCoreRust

/// The analysis board's engine, one for the app: the core (`Engine`) decides when Stockfish
/// searches and which evaluation to show; this starts it, fetches the Lichess cloud eval,
/// runs the core's timer and re-reads its lines when they change.
@Observable
final class EngineService {
    private(set) var lines = EngineLines(lines: [], depth: 0, source: nil, searching: false, knps: nil)
    /// The position the lines are for: start FEN and moves.
    private(set) var analysed: Key?
    private(set) var name: String?
    private(set) var error: String?

    struct Key: Hashable {
        let startFen: String
        let moves: [String]
    }

    let network: EngineNetwork
    @ObservationIgnored private let core = Engine(kind: .stockfish)
    @ObservationIgnored private var wake: Task<Void, Never>?
    @ObservationIgnored private var refreshing = false

    init(network: EngineNetwork) {
        self.network = network
        core.setListener(listener: Listener(service: self))
    }

    private static var nowMs: UInt64 { UInt64(max(0, ExplorerService.millis(.now))) }

    /// Analyses the position after `moves` (UCI) from `startFen`.
    func analyse(_ key: Key, epd: EPD) {
        start()
        let settings = EngineDefaults.settings
        analysed = key
        schedule(core.analyse(startFen: key.startFen, moves: key.moves, settings: settings, nowMs: Self.nowMs))
        lines = core.lines()
        guard settings.cloud else { return }
        Task { [weak self] in
            let eval = await CloudEvalClient.fetch(epd)
            guard let self, analysed == key else { return }
            schedule(core.onCloud(epd: epd, eval: eval, nowMs: Self.nowMs))
            lines = core.lines()
        }
    }

    /// Stops analysing (leaving the board, or the engine turned off).
    func stop() {
        wake?.cancel()
        core.stop()
        analysed = nil
        lines = core.lines()
    }

    /// Starts Stockfish with the full network when it is downloaded and wanted, else the light
    /// one; a running engine with the same network is kept.
    private func start() {
        let full = EngineDefaults.fullNetwork ? network.path : nil
        do {
            try core.start(netPath: full)
            error = nil
        } catch {
            self.error = error.localizedDescription
            if full != nil { try? core.start(netPath: nil) }
        }
        name = core.name()
    }

    private func schedule(_ wakeAt: UInt64?) {
        wake?.cancel()
        guard let wakeAt else { return }
        wake = Task { [weak self] in
            let delay = Double(Int64(wakeAt) - Int64(Self.nowMs)) / 1000
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self else { return }
            schedule(core.poll(nowMs: Self.nowMs))
            lines = core.lines()
        }
    }

    /// The engine printed lines: re-read them at most ten times a second.
    fileprivate func changed() {
        guard !refreshing else { return }
        refreshing = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self else { return }
            refreshing = false
            lines = core.lines()
        }
    }

    /// Called on the engine's thread; hops to the main actor.
    private nonisolated final class Listener: EngineListener, @unchecked Sendable {
        weak var service: EngineService?
        init(service: EngineService) { self.service = service }
        func changed() {
            Task { @MainActor [weak self] in self?.service?.changed() }
        }
    }
}
