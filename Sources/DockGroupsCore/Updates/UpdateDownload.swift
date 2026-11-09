import Foundation

/// Fetches one address for `UpdateInstaller.download`. The default is `URLSessionUpdateTransport`;
/// tests answer without a network.
public protocol UpdateDownloadTransport: Sendable {
    /// Downloads `request` (following redirects) and moves the body to `destination`, whatever the
    /// HTTP status; returns the final response. Network failures throw `URLError`; a cancelled
    /// task throws `CancellationError`.
    func download(
        _ request: URLRequest,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> HTTPURLResponse
}

/// `UpdateDownloadTransport` with a `URLSession` download task, cancelled with the calling task.
public struct URLSessionUpdateTransport: UpdateDownloadTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func download(
        _ request: URLRequest,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> HTTPURLResponse {
        let box = DownloadTaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPURLResponse, Error>) in
                let task = session.downloadTask(with: request) { location, response, error in
                    if let error {
                        let urlError = error as? URLError
                        if urlError?.code == .cancelled {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(throwing: urlError ?? UpdateInstallError.downloadFailed(error.localizedDescription))
                        }
                        return
                    }
                    guard let http = response as? HTTPURLResponse, let location else {
                        continuation.resume(throwing: UpdateInstallError.downloadFailed(Localization.string("core.update.install.noFile", "The server sent no file.")))
                        return
                    }
                    do {
                        // The temporary file is deleted once this handler returns.
                        try FileManager.default.moveItem(at: location, to: destination)
                        continuation.resume(returning: http)
                    } catch {
                        continuation.resume(throwing: UpdateInstallError.downloadFailed(error.localizedDescription))
                    }
                }
                box.start(task, progress: progress)
            }
        } onCancel: {
            box.cancel()
        }
    }
}

/// When a download is tried again: after an HTTP 5xx, 408 or 429 answer, or a network timeout or
/// lost connection, up to `maximumAttempts` times per address, waiting `delays` in between
/// (2 s, then 6 s). Other answers (403, 404, …) fail right away. The wait ends early, with
/// `CancellationError`, when the download is cancelled.
public struct UpdateDownloadRetry: Sendable {
    public static let standard = UpdateDownloadRetry(delays: [.seconds(2), .seconds(6)])

    /// The waits before the second, third, … attempt.
    public let delays: [Duration]
    let sleep: @Sendable (Duration) async throws -> Void

    public init(delays: [Duration], sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.delays = delays
        self.sleep = sleep
    }

    public var maximumAttempts: Int { delays.count + 1 }

    /// A server error, or the server timing out or limiting requests: another try may work.
    public static func isRetryable(status: Int) -> Bool {
        status == 408 || status == 429 || (500...599).contains(status)
    }

    /// The network timed out or dropped the connection: another try may work.
    public static func isRetryable(_ error: URLError) -> Bool {
        [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(error.code)
    }
}

/// An address that still failed after every retry with an answer worth retrying.
struct TransientDownloadFailure: Error, CustomStringConvertible {
    /// The last HTTP status, `nil` for a network failure.
    let status: Int?
    let networkError: URLError?

    /// What the user is told: GitHub's server error for 5xx, the status or network error otherwise.
    var installError: UpdateInstallError {
        if let status, (500...599).contains(status) {
            return .serverUnavailable(status: status)
        }
        if let status {
            return .downloadFailed(Localization.format("core.update.install.httpStatus", "HTTP status %ld.", status))
        }
        return .downloadFailed(networkError?.localizedDescription ?? "")
    }

    var description: String {
        if let status { return "HTTP \(status)" }
        return "URLError \(networkError?.code.rawValue ?? 0)"
    }
}

/// Holds a download task for cancellation and reports its progress.
final class DownloadTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?
    private var isCancelled = false

    func start(_ task: URLSessionDownloadTask, progress: @escaping @Sendable (Double) -> Void) {
        let cancelled = lock.withLock { () -> Bool in
            self.task = task
            observation = task.progress.observe(\.fractionCompleted, options: [.new]) { observed, _ in
                progress(observed.fractionCompleted)
            }
            return isCancelled
        }
        task.resume()
        if cancelled { task.cancel() }
    }

    func cancel() {
        let task = lock.withLock { () -> URLSessionDownloadTask? in
            isCancelled = true
            return self.task
        }
        task?.cancel()
    }
}
