import Foundation

/// Why looking for an update failed.
public enum UpdateCheckError: LocalizedError, Equatable, Sendable {
    /// The server answered with something that isn't a release.
    case malformedRelease(String)
    /// The latest release's tag isn't a version number.
    case unsupportedTag(String)
    /// The repository has no published release yet (HTTP 404).
    case noPublishedRelease
    /// GitHub's limit for unauthenticated requests was reached (HTTP 403 or 429).
    case rateLimited
    /// Any other HTTP status.
    case httpStatus(Int)
    /// The request didn't get an HTTP answer (offline, timeout, …).
    case network(String)
    /// The app's own version couldn't be read.
    case unknownCurrentVersion

    public var errorDescription: String? {
        switch self {
        case .malformedRelease:
            return "The release information from GitHub couldn't be read."
        case .unsupportedTag(let tag):
            return "The latest release (“\(tag)”) isn't tagged with a version number."
        case .noPublishedRelease:
            return "No release has been published yet."
        case .rateLimited:
            return "GitHub is limiting requests right now. Try again in an hour."
        case .httpStatus(let status):
            return "GitHub answered with HTTP status \(status)."
        case .network(let reason):
            return "GitHub couldn't be reached: \(reason)"
        case .unknownCurrentVersion:
            return "This copy of the app has no version number, so it can't be compared."
        }
    }
}

/// The outcome of comparing the running app with the latest release.
public enum UpdateAvailability: Equatable, Sendable {
    /// Nothing newer: the latest release is this version or older (or isn't meant for this copy).
    case upToDate(current: SemanticVersion, latest: SemanticVersion)
    /// A newer release with a disk image to install from.
    case available(ReleaseInfo, asset: ReleaseAsset)
    /// A newer release without a universal disk image; it can only be downloaded by hand.
    case availableWithoutInstaller(ReleaseInfo)
}

public enum UpdateDecision {
    /// Compares `current` with `latest`. Drafts are never offered, and prereleases only to copies
    /// that run a prerelease themselves.
    public static func evaluate(current: SemanticVersion, latest: ReleaseInfo) -> UpdateAvailability {
        let offered = !latest.isDraft && (!latest.isPrerelease || current.isPrerelease)
        guard offered, latest.version > current else {
            return .upToDate(current: current, latest: latest.version)
        }
        if let asset = latest.installerAsset {
            return .available(latest, asset: asset)
        }
        return .availableWithoutInstaller(latest)
    }
}

/// When the automatic update checks run: at launch and every six hours after the last check.
public enum UpdateSchedule {
    public static let checkInterval: TimeInterval = 6 * 60 * 60
    /// How often the app looks whether a check is due. Timers don't run while the Mac sleeps, so a
    /// short tick (and a look after waking) keeps the six hours close to wall-clock time.
    public static let tickInterval: TimeInterval = 15 * 60

    /// Whether an automatic check is due: never checked, the interval has passed, or the clock was
    /// set back to before the last check.
    public static func isCheckDue(lastCheck: Date?, now: Date, interval: TimeInterval = checkInterval) -> Bool {
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed < 0 || elapsed >= interval
    }
}

/// Fixed addresses the updater and its windows link to.
public enum UpdateLinks {
    public static let repositoryOwner = "ercanatay"
    public static let repositoryName = "cybokron-dock-groups"
    public static let latestReleaseAPI = URL(string: "https://api.github.com/repos/ercanatay/cybokron-dock-groups/releases/latest")!
    public static let releasesPage = URL(string: "https://github.com/ercanatay/cybokron-dock-groups/releases")!
    /// The changelog as a plain text file on GitHub.
    public static let changelog = URL(string: "https://raw.githubusercontent.com/ercanatay/cybokron-dock-groups/main/CHANGELOG.md")!
}
