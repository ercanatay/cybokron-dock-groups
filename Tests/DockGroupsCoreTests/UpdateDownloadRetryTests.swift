import CryptoKit
import Foundation
import Testing
@testable import DockGroupsCore

/// Answers download requests from a script per address, in order; the last answer repeats.
/// Records every request.
final class ScriptedDownloadTransport: UpdateDownloadTransport, @unchecked Sendable {
    enum Answer {
        case status(Int, body: Data = Data(), finalURL: URL? = nil)
        case failure(URLError)
    }

    private let lock = NSLock()
    private var scripts: [URL: [Answer]]
    private var _requests: [URLRequest] = []

    init(_ scripts: [URL: [Answer]]) {
        self.scripts = scripts
    }

    var requests: [URLRequest] { lock.withLock { _requests } }

    func requestCount(for url: URL) -> Int {
        requests.filter { $0.url == url }.count
    }

    func download(_ request: URLRequest, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> HTTPURLResponse {
        try Task.checkCancellation()
        guard let url = request.url else { throw URLError(.badURL) }
        let answer = lock.withLock { () -> Answer? in
            _requests.append(request)
            guard var script = scripts[url], !script.isEmpty else { return nil }
            let next = script.count > 1 ? script.removeFirst() : script[0]
            scripts[url] = script
            return next
        }
        switch answer {
        case nil:
            throw URLError(.cannotFindHost)
        case .failure(let error):
            throw error
        case .status(let status, let body, let finalURL):
            try body.write(to: destination)
            progress(1)
            return HTTPURLResponse(url: finalURL ?? url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        }
    }
}

/// Records the waits between tries instead of waiting.
final class DownloadRetrySleeps: @unchecked Sendable {
    private let lock = NSLock()
    private var _durations: [Duration] = []

    var durations: [Duration] { lock.withLock { _durations } }

    var retry: UpdateDownloadRetry {
        UpdateDownloadRetry(delays: UpdateDownloadRetry.standard.delays) { [self] duration in
            lock.withLock { _durations.append(duration) }
        }
    }
}

@Suite("Update download: retries and the API address")
struct UpdateDownloadRetryTests {
    static let primary = URL(string: "https://github.com/ercanatay/cybokron-dock-groups/releases/download/v0.6.0/Cybokron-Dock-Groups-0.6.0-universal.dmg")!
    static let api = URL(string: "https://api.github.com/repos/ercanatay/cybokron-dock-groups/releases/assets/650531464")!
    static let body = Data(repeating: 0x5A, count: 4096)
    static let wrongBody = Data(repeating: 0x41, count: 4096)

    static var bodySHA: String {
        SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
    }

    static func asset(apiURL: URL? = api) -> ReleaseAsset {
        ReleaseAsset(
            name: "Cybokron-Dock-Groups-0.6.0-universal.dmg",
            downloadURL: primary,
            size: body.count,
            digest: "sha256:\(bodySHA)",
            apiURL: apiURL
        )
    }

    private func installer(_ temporary: TemporaryDirectory) -> UpdateInstaller {
        UpdateInstaller(directories: UpdateDirectories(root: temporary.url.appending(path: "updates")))
    }

    // MARK: - Retries at the download address

    @Test func aServerErrorIsTriedAgainAndThenSucceeds() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let transport = ScriptedDownloadTransport([Self.primary: [.status(504), .status(200, body: Self.body)]])
        let sleeps = DownloadRetrySleeps()

        let file = try await installer(temporary).download(Self.asset(), transport: transport, retry: sleeps.retry)

        #expect(try Data(contentsOf: file) == Self.body)
        #expect(transport.requestCount(for: Self.primary) == 2)
        #expect(transport.requestCount(for: Self.api) == 0)
        #expect(sleeps.durations == [.seconds(2)])
    }

    @Test func theThirdTryCanSucceedAfterWaitingTwoThenSixSeconds() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let transport = ScriptedDownloadTransport([Self.primary: [.status(502), .failure(URLError(.timedOut)), .status(200, body: Self.body)]])
        let sleeps = DownloadRetrySleeps()

        let file = try await installer(temporary).download(Self.asset(), transport: transport, retry: sleeps.retry)

        #expect(try UpdateInstaller.sha256(ofFileAt: file) == Self.bodySHA)
        #expect(transport.requestCount(for: Self.primary) == 3)
        #expect(transport.requestCount(for: Self.api) == 0)
        #expect(sleeps.durations == [.seconds(2), .seconds(6)])
    }

    @Test func standardRetryIsThreeTriesWaitingTwoThenSixSeconds() {
        #expect(UpdateDownloadRetry.standard.maximumAttempts == 3)
        #expect(UpdateDownloadRetry.standard.delays == [.seconds(2), .seconds(6)])
    }

    @Test func onlyServerErrorsTimeoutsAndRateLimitsAreRetried() {
        for status in [408, 429, 500, 502, 503, 504, 599] {
            #expect(UpdateDownloadRetry.isRetryable(status: status), "\(status)")
        }
        for status in [200, 301, 400, 401, 403, 404, 410, 499, 600] {
            #expect(!UpdateDownloadRetry.isRetryable(status: status), "\(status)")
        }
        #expect(UpdateDownloadRetry.isRetryable(URLError(.timedOut)))
        #expect(UpdateDownloadRetry.isRetryable(URLError(.networkConnectionLost)))
        #expect(!UpdateDownloadRetry.isRetryable(URLError(.cancelled)))
        #expect(!UpdateDownloadRetry.isRetryable(URLError(.serverCertificateUntrusted)))
    }

    @Test func notFoundIsNotTriedAgainNorAtTheAPIAddress() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let installer = installer(temporary)
        for status in [404, 403] {
            let transport = ScriptedDownloadTransport([Self.primary: [.status(status)], Self.api: [.status(200, body: Self.body)]])
            let sleeps = DownloadRetrySleeps()

            await #expect(throws: UpdateInstallError.downloadFailed("HTTP status \(status).")) {
                try await installer.download(Self.asset(), transport: transport, retry: sleeps.retry)
            }

            #expect(transport.requestCount(for: Self.primary) == 1)
            #expect(transport.requestCount(for: Self.api) == 0)
            #expect(sleeps.durations.isEmpty)
        }
        #expect(!FileManager.default.fileExists(atPath: installer.directories.downloads.appending(path: Self.asset().name).path))
    }

    // MARK: - The API address

    @Test func afterThreeServerErrorsTheAPIAddressServesTheFile() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let redirected = URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/1/abc?sig=secret")!
        let transport = ScriptedDownloadTransport([
            Self.primary: [.status(504)],
            Self.api: [.status(200, body: Self.body, finalURL: redirected)],
        ])
        let sleeps = DownloadRetrySleeps()

        let file = try await installer(temporary).download(
            Self.asset(),
            transport: transport,
            userAgent: "CybokronDockGroups/0.5.0",
            retry: sleeps.retry
        )

        #expect(try UpdateInstaller.sha256(ofFileAt: file) == Self.bodySHA)
        #expect(transport.requestCount(for: Self.primary) == 3)
        #expect(transport.requestCount(for: Self.api) == 1)
        #expect(sleeps.durations == [.seconds(2), .seconds(6)])
        let request = try #require(transport.requests.last)
        #expect(request.url == Self.api)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/octet-stream")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "CybokronDockGroups/0.5.0")
    }

    @Test func whenTheAPIAddressFailsTooTheServerErrorIsReported() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let installer = installer(temporary)
        let transport = ScriptedDownloadTransport([Self.primary: [.status(504)], Self.api: [.status(404)]])

        let error = await #expect(throws: UpdateInstallError.serverUnavailable(status: 504)) {
            try await installer.download(Self.asset(), transport: transport, retry: DownloadRetrySleeps().retry)
        }

        #expect(error?.errorDescription == "GitHub couldn't serve the download right now (HTTP 504). Check your connection and try again in a few minutes.")
        #expect(transport.requestCount(for: Self.primary) == 3)
        #expect(transport.requestCount(for: Self.api) == 1)
        // Nothing to install.
        #expect(!FileManager.default.fileExists(atPath: installer.directories.downloads.appending(path: Self.asset().name).path))
    }

    @Test func serverErrorsAtBothAddressesAreTriedThreeTimesEach() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let transport = ScriptedDownloadTransport([Self.primary: [.status(504)], Self.api: [.status(503)]])
        let sleeps = DownloadRetrySleeps()

        await #expect(throws: UpdateInstallError.serverUnavailable(status: 504)) {
            try await installer(temporary).download(Self.asset(), transport: transport, retry: sleeps.retry)
        }

        #expect(transport.requestCount(for: Self.primary) == 3)
        #expect(transport.requestCount(for: Self.api) == 3)
        #expect(sleeps.durations == [.seconds(2), .seconds(6), .seconds(2), .seconds(6)])
    }

    @Test func withoutAnAPIAddressTheServerErrorIsReportedAfterThreeTries() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let transport = ScriptedDownloadTransport([Self.primary: [.status(500)]])

        await #expect(throws: UpdateInstallError.serverUnavailable(status: 500)) {
            try await installer(temporary).download(Self.asset(apiURL: nil), transport: transport, retry: DownloadRetrySleeps().retry)
        }
        #expect(transport.requestCount(for: Self.primary) == 3)
    }

    @Test func otherRetriedFailuresKeepTheirOwnMessage() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let installer = installer(temporary)

        await #expect(throws: UpdateInstallError.downloadFailed("HTTP status 429.")) {
            try await installer.download(
                Self.asset(apiURL: nil),
                transport: ScriptedDownloadTransport([Self.primary: [.status(429)]]),
                retry: DownloadRetrySleeps().retry
            )
        }
        let timeout = URLError(.timedOut)
        await #expect(throws: UpdateInstallError.downloadFailed(timeout.localizedDescription)) {
            try await installer.download(
                Self.asset(apiURL: nil),
                transport: ScriptedDownloadTransport([Self.primary: [.failure(timeout)]]),
                retry: DownloadRetrySleeps().retry
            )
        }
    }

    @Test func anInsecureRedirectFromTheAPIAddressIsRefused() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let insecure = URL(string: "http://example.com/x.dmg")!
        let transport = ScriptedDownloadTransport([
            Self.primary: [.status(504)],
            Self.api: [.status(200, body: Self.body, finalURL: insecure)],
        ])

        await #expect(throws: UpdateInstallError.insecureDownloadURL(insecure.absoluteString)) {
            try await installer(temporary).download(Self.asset(), transport: transport, retry: DownloadRetrySleeps().retry)
        }
    }

    // MARK: - Checks on the file

    @Test func aChecksumMismatchIsRefusedFromEitherAddress() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let installer = installer(temporary)

        let fromPrimary = ScriptedDownloadTransport([Self.primary: [.status(200, body: Self.wrongBody)], Self.api: [.status(200, body: Self.body)]])
        await #expect(throws: UpdateInstallError.checksumMismatch) {
            try await installer.download(Self.asset(), transport: fromPrimary, retry: DownloadRetrySleeps().retry)
        }
        // A bad file isn't fetched again from the other address.
        #expect(fromPrimary.requestCount(for: Self.api) == 0)

        let fromAPI = ScriptedDownloadTransport([Self.primary: [.status(504)], Self.api: [.status(200, body: Self.wrongBody)]])
        await #expect(throws: UpdateInstallError.checksumMismatch) {
            try await installer.download(Self.asset(), transport: fromAPI, retry: DownloadRetrySleeps().retry)
        }
        #expect(fromAPI.requestCount(for: Self.api) == 1)

        let truncated = ScriptedDownloadTransport([Self.primary: [.status(504)], Self.api: [.status(200, body: Self.body.prefix(100))]])
        await #expect(throws: UpdateInstallError.sizeMismatch(expected: Self.body.count, actual: 100)) {
            try await installer.download(Self.asset(), transport: truncated, retry: DownloadRetrySleeps().retry)
        }
    }

    // MARK: - Cancelling

    @Test func cancellingDuringTheWaitEndsTheDownload() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let installer = installer(temporary)
        let transport = ScriptedDownloadTransport([Self.primary: [.status(504)], Self.api: [.status(200, body: Self.body)]])
        let (waiting, waitingContinuation) = AsyncStream.makeStream(of: Void.self)
        let retry = UpdateDownloadRetry(delays: [.seconds(2), .seconds(6)]) { _ in
            waitingContinuation.yield()
            try await Task.sleep(for: .seconds(600))
        }

        let download = Task { try await installer.download(Self.asset(), transport: transport, retry: retry) }
        var iterator = waiting.makeAsyncIterator()
        _ = await iterator.next()
        download.cancel()
        let result = await download.result

        #expect(throws: CancellationError.self) { try result.get() }
        #expect(transport.requestCount(for: Self.primary) == 1)
        #expect(transport.requestCount(for: Self.api) == 0)
    }

    @Test func aCancelledDownloadIsNotTriedAgain() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let transport = ScriptedDownloadTransport([Self.primary: [.failure(URLError(.cancelled))], Self.api: [.status(200, body: Self.body)]])
        let sleeps = DownloadRetrySleeps()

        await #expect(throws: CancellationError.self) {
            try await installer(temporary).download(Self.asset(), transport: transport, retry: sleeps.retry)
        }
        #expect(transport.requests.count == 1)
        #expect(sleeps.durations.isEmpty)
    }

    // MARK: - The asset's API address in the release information

    @Test func releaseInformationGivesTheAssetsAPIAddress() throws {
        let release = try ReleaseInfo.decode(from: ReleaseFixtures.data(ReleaseFixtures.v050))
        #expect(release.installerAsset?.apiURL == URL(string: "https://api.github.com/repos/ercanatay/cybokron-dock-groups/releases/assets/650531464"))
        // No `url` in the release information: no API address.
        let other = try ReleaseInfo.decode(from: ReleaseFixtures.data(ReleaseFixtures.v060WithDecoys))
        #expect(other.installerAsset?.apiURL == nil)
    }

    @Test func onlyGitHubAPIAssetAddressesAreTaken() {
        #expect(ReleaseAsset.apiURL(from: "https://api.github.com/repos/owner/repo.name/releases/assets/1") != nil)
        for text in [
            nil,
            "",
            "http://api.github.com/repos/o/r/releases/assets/1",
            "https://example.com/repos/o/r/releases/assets/1",
            "https://api.github.com.example.com/repos/o/r/releases/assets/1",
            "https://api.github.com:8443/repos/o/r/releases/assets/1",
            "https://user@api.github.com/repos/o/r/releases/assets/1",
            "https://api.github.com/repos/o/r/releases/assets/1?access_token=x",
            "https://api.github.com/repos/o/r/releases/assets/1#x",
            "https://api.github.com/repos/o/r/releases/assets/abc",
            "https://api.github.com/repos/o/r/releases/assets/1/../2",
            "https://api.github.com/repos/o/r/releases/1",
        ] {
            #expect(ReleaseAsset.apiURL(from: text) == nil, "\(text ?? "nil")")
        }
    }
}
