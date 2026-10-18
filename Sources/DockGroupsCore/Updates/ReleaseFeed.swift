import Foundation

/// Fetches the latest published release.
public protocol ReleaseFetching: Sendable {
    func latestRelease() async throws -> ReleaseInfo
}

/// Fetches every published release, for "Other Versions…".
public protocol ReleaseListFetching: Sendable {
    /// The releases as the server lists them (drafts and prereleases included, if it sends any);
    /// `ReleaseHistory.installable` picks the ones to offer.
    func releases() async throws -> [ReleaseInfo]
}

/// `ReleaseFetching` with GitHub's REST API (`GET /repos/{owner}/{repo}/releases/latest`), which
/// returns the newest release that is neither a draft nor a prerelease, and `ReleaseListFetching`
/// with `GET /repos/{owner}/{repo}/releases` (the newest 100, more than the project has). No token is
/// sent; GitHub allows 60 such requests an hour per IP address, far more than the checks need. These
/// are the only requests the app makes besides downloading a release's disk image.
public struct GitHubReleaseFeed: ReleaseFetching, ReleaseListFetching {
    /// Environment variable that points the updater at another release JSON, e.g. a local test
    /// server: `CYBOKRON_UPDATE_FEED_URL=http://127.0.0.1:8765/latest.json`.
    public static let urlOverrideVariable = "CYBOKRON_UPDATE_FEED_URL"

    /// `UpdateLinks.latestReleaseAPI`, unless `urlOverrideVariable` holds an http(s) URL.
    public static func resolvedURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let value = environment[urlOverrideVariable]?.trimmingCharacters(in: .whitespaces),
           let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
            return url
        }
        return UpdateLinks.latestReleaseAPI
    }

    /// Environment variable that points "Other Versions…" at another release list JSON:
    /// `CYBOKRON_RELEASES_FEED_URL=http://127.0.0.1:8765/releases.json`.
    public static let listURLOverrideVariable = "CYBOKRON_RELEASES_FEED_URL"

    /// `UpdateLinks.releasesAPI`, unless `listURLOverrideVariable` holds an http(s) URL.
    public static func resolvedListURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let value = environment[listURLOverrideVariable]?.trimmingCharacters(in: .whitespaces),
           let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
            return url
        }
        return UpdateLinks.releasesAPI
    }

    public let url: URL
    public let listURL: URL
    private let session: URLSession
    private let userAgent: String

    /// - Parameters:
    ///   - appVersion: Sent in the User-Agent header, which GitHub requires.
    ///   - session: Tests pass a session whose protocol classes answer without a network.
    public init(
        url: URL = GitHubReleaseFeed.resolvedURL(),
        listURL: URL = GitHubReleaseFeed.resolvedListURL(),
        appVersion: String,
        session: URLSession = .shared
    ) {
        self.url = url
        self.listURL = listURL
        self.session = session
        userAgent = "CybokronDockGroups/\(appVersion)"
    }

    public func latestRelease() async throws -> ReleaseInfo {
        try ReleaseInfo.decode(from: await fetch(url))
    }

    public func releases() async throws -> [ReleaseInfo] {
        try ReleaseInfo.decodeList(from: await fetch(listURL))
    }

    /// GETs `url` from GitHub's API; HTTP errors become `UpdateCheckError`s.
    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw UpdateCheckError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw UpdateCheckError.network("The answer wasn't HTTP.")
        }
        switch http.statusCode {
        case 200:
            return data
        case 404:
            throw UpdateCheckError.noPublishedRelease
        case 403, 429:
            throw UpdateCheckError.rateLimited
        default:
            throw UpdateCheckError.httpStatus(http.statusCode)
        }
    }
}
