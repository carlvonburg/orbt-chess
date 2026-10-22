import Foundation
import Observation
import OpeningCoreRust

/// Stockfish 19's full network (94 MB), downloaded on request into Application Support. The
/// app ships with the 1 MB light network built in; with this one the engine is stronger.
/// Checked against the SHA-256 in its name before use: Stockfish ends the process when a
/// network fails to load.
@Observable
final class EngineNetwork {
    enum State: Equatable {
        case absent
        case downloading(Double)
        case ready
        case failed(String)
    }

    nonisolated static let fileName = "nn-1a298aa575a0.nnue"
    nonisolated static let byteCount: Int64 = 98_511_183
    /// Where Stockfish's own builds download it.
    nonisolated static let source = URL(string: "https://tests.stockfishchess.org/api/nn/\(fileName)")!

    private(set) var state = State.absent
    @ObservationIgnored private var download: Task<Void, Never>?

    private nonisolated static var folder: URL {
        URL.applicationSupportDirectory.appending(path: "Engine", directoryHint: .isDirectory)
    }

    nonisolated static var file: URL { folder.appending(path: fileName) }

    init() {
        if FileManager.default.fileExists(atPath: Self.file.path) { state = .ready }
    }

    /// The network's path while it is downloaded.
    var path: String? { state == .ready ? Self.file.path : nil }

    func start() {
        guard download == nil else { return }
        state = .downloading(0)
        download = Task { [weak self] in
            let result = await Self.fetch { fraction in
                Task { @MainActor in
                    if case .downloading = self?.state { self?.state = .downloading(fraction) }
                }
            }
            self?.download = nil
            self?.state = result
        }
    }

    func cancel() {
        download?.cancel()
        download = nil
        state = .absent
    }

    func remove() {
        try? FileManager.default.removeItem(at: Self.file)
        state = .absent
    }

    private nonisolated static func fetch(progress: @escaping @Sendable (Double) -> Void) async -> State {
        let delegate = ProgressDelegate(progress: progress)
        do {
            let (temporary, response) = try await URLSession.shared.download(from: source, delegate: delegate)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return .failed("The server did not send the network.")
            }
            // The check reads the whole file: named after its hash, so a partial or wrong file
            // never reaches the engine.
            let named = temporary.deletingLastPathComponent().appending(path: fileName)
            try? FileManager.default.removeItem(at: named)
            try FileManager.default.moveItem(at: temporary, to: named)
            guard engineNetworkIsValid(path: named.path) else {
                try? FileManager.default.removeItem(at: named)
                return .failed("The downloaded network is damaged.")
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: named, to: file)
            return .ready
        } catch is CancellationError {
            return .absent
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Reports the download's progress (the server compresses it, so it counts the file's size).
    private nonisolated final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let progress: @Sendable (Double) -> Void

        init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            progress(min(1, Double(totalBytesWritten) / Double(EngineNetwork.byteCount)))
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }
}
