import Foundation
import Observation
import os
import OpeningCore
import SwiftData

enum ExplorerError: Error, Equatable {
    case unauthorized
    /// Seconds from the Retry-After header, if Lichess sent one.
    case rateLimited(retryAfter: Double?)
    case offline
    case http(Int)
    case decoding
}

/// Lichess opening explorer. Requires a token since 2025.
enum ExplorerClient {
    static let host = URL(string: "https://explorer.lichess.org")!

    static func fetch(_ epd: EPD, database: ExplorerDatabase, token: String) async throws(ExplorerError) -> ExplorerStats {
        var components = URLComponents(url: host.appending(path: database.path), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "fen", value: epd.queryFEN),
            URLQueryItem(name: "moves", value: "30"),
            URLQueryItem(name: "topGames", value: "0"),
            URLQueryItem(name: "recentGames", value: "0"),
        ] + database.queryItems
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw .offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: break
        case 401: throw .unauthorized
        case 429:
            let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
            throw .rateLimited(retryAfter: header.flatMap(Double.init))
        default: throw .http(status)
        }
        guard let raw = try? JSONDecoder().decode(ExplorerStats.self, from: data) else { throw .decoding }
        guard let position = ChessPosition(fen: epd.queryFEN) else { return raw }
        return raw.normalized(for: position)
    }
}

/// Cloud evaluations from lichess.org (no token needed). 404 means no eval stored.
enum CloudEvalClient {
    struct Eval: Decodable, Sendable {
        struct PV: Decodable, Sendable {
            let moves: String
            let cp: Int?
            let mate: Int?
        }
        let depth: Int
        let pvs: [PV]
    }

    static func fetch(_ epd: EPD) async -> Eval? {
        var components = URLComponents(string: "https://lichess.org/api/cloud-eval")!
        components.queryItems = [URLQueryItem(name: "fen", value: epd.queryFEN), URLQueryItem(name: "multiPv", value: "5")]
        guard let (data, response) = try? await URLSession.shared.data(from: components.url!),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Eval.self, from: data)
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

/// Local, unsynced cache of explorer stats keyed by (database, EPD). It can always be
/// re-fetched, so it is not stored in iCloud. Entries of a database are loaded into
/// memory once, so lookups during coverage computation are synchronous dictionary reads.
@Observable
final class StatsStore {
    private let context: ModelContext
    @ObservationIgnored private var memory: [String: (stats: ExplorerStats, fetchedAt: Date)] = [:]
    @ObservationIgnored private var loaded: Set<String> = []

    init() {
        let config = ModelConfiguration("ExplorerCache", cloudKitDatabase: .none)
        let container: ModelContainer
        do {
            container = try ModelContainer(for: ExplorerEntry.self, configurations: config)
        } catch {
            container = try! ModelContainer(for: ExplorerEntry.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
        context = ModelContext(container)
    }

    static func key(_ epd: EPD, _ database: ExplorerDatabase) -> String {
        database.cacheKey + "|" + epd.rawValue
    }

    func load(_ database: ExplorerDatabase) {
        let db = database.cacheKey
        guard !loaded.contains(db) else { return }
        loaded.insert(db)
        let descriptor = FetchDescriptor<ExplorerEntry>(predicate: #Predicate { $0.database == db })
        let decoder = JSONDecoder()
        for entry in (try? context.fetch(descriptor)) ?? [] {
            if let stats = try? decoder.decode(ExplorerStats.self, from: entry.payload) {
                memory[entry.key] = (stats, entry.fetchedAt)
            }
        }
    }

    func stats(_ epd: EPD, _ database: ExplorerDatabase) -> ExplorerStats? {
        load(database)
        return memory[Self.key(epd, database)]?.stats
    }

    func isStale(_ epd: EPD, _ database: ExplorerDatabase) -> Bool {
        guard let entry = memory[Self.key(epd, database)] else { return true }
        return Date.now.timeIntervalSince(entry.fetchedAt) > database.maxAge
    }

    func save(_ stats: ExplorerStats, for epd: EPD, _ database: ExplorerDatabase) {
        let key = Self.key(epd, database)
        memory[key] = (stats, .now)
        guard let payload = try? JSONEncoder().encode(stats) else { return }
        let descriptor = FetchDescriptor<ExplorerEntry>(predicate: #Predicate { $0.key == key })
        if let existing = try? context.fetch(descriptor).first {
            existing.payload = payload
            existing.fetchedAt = .now
        } else {
            context.insert(ExplorerEntry(key: key, database: database.cacheKey, payload: payload, fetchedAt: .now))
        }
        try? context.save()
    }

    var entryCount: Int { (try? context.fetchCount(FetchDescriptor<ExplorerEntry>())) ?? 0 }

    func clear() {
        try? context.delete(model: ExplorerEntry.self)
        try? context.save()
        memory = [:]
        loaded = []
    }
}

/// Serial explorer fetch queue: one request in flight, deduplicated, highest priority first.
/// Pauses 60 s on HTTP 429, stops and asks for login on 401, retries later when offline.
@Observable
final class ExplorerQueue {
    enum State: Equatable {
        case idle
        case fetching(remaining: Int)
        case rateLimited(until: Date)
        case needsLogin
        case offline
    }

    private(set) var state: State = .idle

    private struct Request {
        let epd: EPD
        let database: ExplorerDatabase
        var priority: Double
    }

    @ObservationIgnored private var pending: [String: Request] = [:]
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var listeners: [UUID: (EPD, ExplorerDatabase) -> Void] = [:]

    let store: StatsStore
    let auth: LichessAuth

    init(store: StatsStore, auth: LichessAuth) {
        self.store = store
        self.auth = auth
    }

    var remaining: Int { pending.count }

    /// Requests stats unless they are cached and fresh. Higher priority is fetched first.
    func request(_ epd: EPD, _ database: ExplorerDatabase, priority: Double) {
        if store.stats(epd, database) != nil, !store.isStale(epd, database) { return }
        let key = StatsStore.key(epd, database)
        if var existing = pending[key] {
            existing.priority = max(existing.priority, priority)
            pending[key] = existing
        } else {
            pending[key] = Request(epd: epd, database: database, priority: priority)
        }
        startIfNeeded()
    }

    func cancelAll(for database: ExplorerDatabase) {
        pending = pending.filter { $0.value.database != database }
    }

    func subscribe(_ handler: @escaping (EPD, ExplorerDatabase) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = handler
        return id
    }

    func unsubscribe(_ id: UUID) {
        listeners[id] = nil
    }

    /// Call after signing in or when the network is back.
    func resume() {
        if state == .needsLogin || state == .offline { state = .idle }
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard worker == nil, !pending.isEmpty else { return }
        worker = Task { [weak self] in
            await self?.run()
            self?.worker = nil
        }
    }

    private static let minInterval = 0.6
    @ObservationIgnored private var interval = 0.8

    private static let log = Logger(subsystem: "ch.cvb.openingTrainer", category: "explorer")

    private func run() async {
        while let (key, request) = pending.max(by: { $0.value.priority < $1.value.priority }) {
            guard let token = auth.token else {
                state = .needsLogin
                return
            }
            state = .fetching(remaining: pending.count)
            let started = ContinuousClock.now
            do {
                let stats = try await ExplorerClient.fetch(request.epd, database: request.database, token: token)
                Self.log.info("explorer \(request.database.cacheKey, privacy: .public) priority \(request.priority, format: .fixed(precision: 4)) took \(started.duration(to: .now).description, privacy: .public), \(self.pending.count) queued")
                pending[key] = nil
                store.save(stats, for: request.epd, request.database)
                for listener in listeners.values { listener(request.epd, request.database) }
                // Pace requests: Lichess answers a fast burst with 429 and a one-minute ban.
                interval = max(interval * 0.95, Self.minInterval)
                if !pending.isEmpty { try? await Task.sleep(for: .seconds(interval)) }
            } catch .rateLimited(let retryAfter) {
                // Back off and slow down so the next burst does not hit the limit again.
                interval = min(interval * 2, 4)
                let wait = retryAfter ?? 60
                Self.log.error("explorer 429, waiting \(wait)s, interval now \(self.interval)s")
                state = .rateLimited(until: Date.now.addingTimeInterval(wait))
                try? await Task.sleep(for: .seconds(wait))
            } catch .unauthorized {
                auth.tokenRejected()
                state = .needsLogin
                return
            } catch .offline {
                state = .offline
                try? await Task.sleep(for: .seconds(30))
            } catch {
                // Unexpected answer for this position: drop it so the queue keeps moving.
                pending[key] = nil
            }
        }
        state = .idle
    }
}
