import Foundation
import Observation
import os
import OpeningCoreRust
import SwiftData

/// Cloud evaluations from lichess.org (no token needed). The request, the answer and the
/// session cache (a 404 is remembered, other failures are asked again) are in the core.
enum CloudEvalClient {
    private static let core = CloudEvals()

    static func fetch(_ epd: EPD) async -> CloudEval? {
        switch core.lookup(epd: epd) {
        case .cached(let eval):
            return eval
        case .fetch(let request):
            return core.onResponse(epd: epd, response: await HTTP.send(request))
        }
    }
}

@Model
final class ExplorerEntry {
    @Attribute(.unique) var key: String
    var database: String
    var payload: Data
    var fetchedAt: Date

    init(key: String, database: String, payload: Data, fetchedAt: Date) {
        self.key = key
        self.database = database
        self.payload = payload
        self.fetchedAt = fetchedAt
    }
}

/// Local, unsynced store of explorer stats keyed by (database, EPD), for the Rust core's
/// cache. It can always be re-fetched, so it is not stored in iCloud. The core loads a
/// database's entries once and keeps them in memory.
///
/// The core calls it from whichever thread called into the core (often while it holds a
/// document's lock), so it uses its own context behind a lock and never hops to another actor.
nonisolated final class ExplorerCacheStore: StatsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storedContext: ModelContext?

    /// Runs `body` with the context, one caller at a time.
    private func withContext<T>(_ body: (ModelContext) -> T) -> T {
        lock.withLock {
            if let storedContext { return body(storedContext) }
            let config = ModelConfiguration("ExplorerCache", cloudKitDatabase: .none)
            let container: ModelContainer
            do {
                container = try ModelContainer(for: ExplorerEntry.self, configurations: config)
            } catch {
                container = try! ModelContainer(for: ExplorerEntry.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            }
            let context = ModelContext(container)
            context.autosaveEnabled = false
            storedContext = context
            return body(context)
        }
    }

    static func key(_ epd: EPD, databaseKey: String) -> String { databaseKey + "|" + epd }

    func load(databaseKey: String) -> [StoredStats] {
        withContext { context in
            let descriptor = FetchDescriptor<ExplorerEntry>(predicate: #Predicate { $0.database == databaseKey })
            let prefix = databaseKey + "|"
            return ((try? context.fetch(descriptor)) ?? []).map { entry in
                StoredStats(epd: String(entry.key.dropFirst(prefix.count)), json: entry.payload)
            }
        }
    }

    func save(databaseKey: String, epd: Epd, json: Data) {
        withContext { context in
            let key = Self.key(epd, databaseKey: databaseKey)
            let descriptor = FetchDescriptor<ExplorerEntry>(predicate: #Predicate { $0.key == key })
            if let existing = try? context.fetch(descriptor).first {
                existing.payload = json
                existing.fetchedAt = .now
            } else {
                context.insert(ExplorerEntry(key: key, database: databaseKey, payload: json, fetchedAt: .now))
            }
            try? context.save()
        }
    }

    var entryCount: Int { withContext { (try? $0.fetchCount(FetchDescriptor<ExplorerEntry>())) ?? 0 } }

    func clear() {
        withContext { context in
            try? context.delete(model: ExplorerEntry.self)
            try? context.save()
        }
    }
}

/// Runs the core's explorer queue: sends the requests it hands out (the core adds the
/// Lichess token) and reports the answers. The rules (300 ms focus, one paced coverage request at a
/// time, the shared 429 pause, offline retry, 401) are in the core.
@Observable
final class ExplorerService {
    private(set) var state: QueueState = .idle

    let core: Explorer
    let store: ExplorerCacheStore
    let auth: LichessAuth
    @ObservationIgnored private var wake: Task<Void, Never>?

    /// The end of a ban, kept across launches: a relaunch must not restart Lichess's penalty.
    private static let bannedUntilKey = "explorerBannedUntil"
    private static let log = Logger(subsystem: "ch.cvb.openingTrainer", category: "explorer")

    init(store: ExplorerCacheStore, auth: LichessAuth) {
        self.store = store
        self.auth = auth
        let bannedUntil = (UserDefaults.standard.object(forKey: Self.bannedUntilKey) as? Date).map(Self.millis)
        // The launch argument `-explorerInterval <seconds>` overrides the pace for testing.
        let override = UserDefaults.standard.double(forKey: "explorerInterval")
        core = Explorer(store: store, bannedUntil: bannedUntil, baseIntervalMs: override > 0 ? Int64(override * 1000) : nil)
        core.setListener(listener: Listener(service: self))
    }

    var remaining: Int { Int(core.remaining()) }

    static func millis(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

    /// Call after signing in or when the network is back.
    func resume() { core.resume() }

    /// Sends what the queue hands out and sleeps until it wants to be asked again.
    func pump() {
        let poll = core.poll(nowMs: Self.millis(.now), token: auth.token)
        state = core.state()
        for fetch in poll.fetches {
            Task { await perform(fetch) }
        }
        wake?.cancel()
        if let wakeAt = poll.wakeAt {
            wake = Task { [weak self] in
                let delay = Double(wakeAt - Self.millis(.now)) / 1000
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard !Task.isCancelled else { return }
                self?.pump()
            }
        }
    }

    private func perform(_ fetch: Fetch) async {
        let started = ContinuousClock.now
        let response = await HTTP.send(fetch.request)
        Self.log.info("explorer \(fetch.database.cacheKey, privacy: .public) \(response.map { String($0.status) } ?? "offline", privacy: .public) in \(started.duration(to: .now).description, privacy: .public), \(self.remaining) queued")
        let outcome = core.onResponse(fetch: fetch, response: response, nowMs: Self.millis(.now))
        if outcome.unauthorized { auth.tokenRejected() }
        if let until = outcome.bannedUntil {
            UserDefaults.standard.set(Date(timeIntervalSince1970: TimeInterval(until) / 1000), forKey: Self.bannedUntilKey)
            Self.log.error("explorer 429, paused until \(until)")
        }
        state = core.state()
    }

    /// The core asks to be polled; hop to the main actor so it is not re-entered.
    private nonisolated final class Listener: ExplorerListener, @unchecked Sendable {
        weak var service: ExplorerService?
        init(service: ExplorerService) { self.service = service }
        func wake() {
            Task { @MainActor [weak self] in self?.service?.pump() }
        }
    }
}
