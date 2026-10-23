import AppKit

/// The parts of the system workspace that launching a group needs.
@MainActor
public protocol ApplicationWorkspace: AnyObject {
    /// Brings a running instance of the app to the front. Returns `false` when it isn't running.
    /// `bundleIdentifier` is the app's `AppReference.bundleIdentifier`: its location for apps
    /// identified by path.
    func activateRunningApplication(bundleIdentifier: String) -> Bool
    /// Brings a running instance of the app back as clicking its Dock icon does: un-hides it,
    /// restores its windows from the Dock when all of them are minimized, and otherwise asks it to
    /// reopen. Returns `false` when it isn't running. By default it's only brought to the front.
    func reopenRunningApplication(bundleIdentifier: String) -> Bool
    /// Where the app lives on this Mac, or `nil` when it isn't installed.
    func locateApplication(_ app: AppReference) -> URL?
    /// Launches the app at `url`, finishing once it has started.
    func launchApplication(at url: URL) async throws
    /// Opens web addresses in the default browser, all in one request so they arrive together
    /// (as tabs of one window, in browsers that do so), and brings the browser to the front.
    func openWebsites(_ urls: [URL]) async throws
    /// Opens files and folders (already checked, `GroupLauncher`) with their default apps — a
    /// folder in the default file viewer — in one request per app, and brings that app to the
    /// front. A file whose default app would run it (`FileItemPolicy.refusesHandler`) isn't opened.
    /// - Returns: Why each location that couldn't be opened wasn't; the others were opened.
    func openFileItems(_ urls: [URL]) async -> [URL: any Error]
    /// Shows the files and folders selected in Finder windows (Show in Finder).
    func revealFileItems(_ urls: [URL])
}

extension ApplicationWorkspace {
    public func reopenRunningApplication(bundleIdentifier: String) -> Bool {
        activateRunningApplication(bundleIdentifier: bundleIdentifier)
    }
}

/// `ApplicationWorkspace` backed by `NSWorkspace` and `NSRunningApplication`.
@MainActor
public final class SystemApplicationWorkspace: ApplicationWorkspace {
    private let workspace: NSWorkspace
    private lazy var restorer = WindowRestorer()

    public init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    public func activateRunningApplication(bundleIdentifier: String) -> Bool {
        guard let app = runningApplication(bundleIdentifier: bundleIdentifier) else { return false }
        activate(app)
        return true
    }

    public func reopenRunningApplication(bundleIdentifier: String) -> Bool {
        guard let app = runningApplication(bundleIdentifier: bundleIdentifier) else { return false }
        let outcome = restorer.restore(app)
        if outcome.restoredWindowCount == 0, let bundleURL = app.bundleURL {
            // What a Dock click does: LaunchServices brings the running app forward and asks it to
            // reopen, so an app without a visible window shows one again — AppKit apps restore a
            // minimized window or open a new one. It never starts a second instance.
            workspace.openApplication(at: bundleURL, configuration: Self.activatingConfiguration())
        } else {
            activate(app)
        }
        return true
    }

    public func locateApplication(_ app: AppReference) -> URL? {
        app.resolvedURL(workspace: workspace)
    }

    public func launchApplication(at url: URL) async throws {
        let configuration = Self.activatingConfiguration()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            workspace.openApplication(at: url, configuration: configuration) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    public func openWebsites(_ urls: [URL]) async throws {
        guard let first = urls.first else { return }
        guard let browserURL = workspace.urlForApplication(toOpen: first) else {
            throw WebsiteOpeningError.noBrowser
        }
        try await open(urls, withApplicationAt: browserURL)
    }

    public func openFileItems(_ urls: [URL]) async -> [URL: any Error] {
        var failures: [URL: any Error] = [:]
        // One request per default app, in the order the items come.
        var requests: [(handler: URL, urls: [URL])] = []
        for url in urls {
            guard let handler = workspace.urlForApplication(toOpen: url) else {
                failures[url] = FileItemOpeningError.noHandler(name: FileLocation.defaultName(for: url))
                continue
            }
            if let identifier = Bundle(url: handler)?.bundleIdentifier, FileItemPolicy.refusesHandler(bundleIdentifier: identifier) {
                failures[url] = FileItemOpeningError.refused
                continue
            }
            if let index = requests.firstIndex(where: { $0.handler == handler }) {
                requests[index].urls.append(url)
            } else {
                requests.append((handler, [url]))
            }
        }
        for request in requests {
            do {
                try await open(request.urls, withApplicationAt: request.handler)
            } catch {
                for url in request.urls {
                    failures[url] = error
                }
            }
        }
        return failures
    }

    public func revealFileItems(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        workspace.activateFileViewerSelecting(urls)
    }

    private func open(_ urls: [URL], withApplicationAt applicationURL: URL) async throws {
        let configuration = Self.activatingConfiguration()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            workspace.open(urls, withApplicationAt: applicationURL, configuration: configuration) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func runningApplication(bundleIdentifier: String) -> NSRunningApplication? {
        RunningApplicationLookup.runningApplications(identifiedBy: bundleIdentifier, workspace: workspace)
            .first { !$0.isTerminated }
    }

    private func activate(_ app: NSRunningApplication) {
        if !app.activate(options: [.activateAllWindows]), let bundleURL = app.bundleURL {
            // macOS may refuse an activation request from an app that isn't frontmost. Asking
            // LaunchServices to open the already running app brings it forward instead; it never
            // starts a second instance.
            workspace.openApplication(at: bundleURL, configuration: Self.activatingConfiguration())
        }
    }

    private static func activatingConfiguration() -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return configuration
    }
}

/// Why websites couldn't be opened.
public enum WebsiteOpeningError: LocalizedError, Equatable, Sendable {
    /// No app on this Mac opens web pages.
    case noBrowser

    public var errorDescription: String? {
        switch self {
        case .noBrowser:
            return Localization.string("core.launch.noBrowser", "No web browser is set up to open it.")
        }
    }
}

/// Why a file or folder item wasn't opened. The texts follow the item's name in the launch report
/// ("• Run.command: wasn't opened, …").
public enum FileItemOpeningError: LocalizedError, Equatable, Sendable {
    /// It's a program, script, installer or location file, or its default app would run it.
    case refused
    /// No app on this Mac opens it.
    case noHandler(name: String)
    /// It's on a volume that isn't connected.
    case volumeUnavailable(name: String)
    /// macOS didn't let the app check what it is, so it isn't opened blindly.
    case unchecked

    public var errorDescription: String? {
        switch self {
        case .refused:
            return Localization.string("core.item.error.notOpened", "wasn't opened, because programs and scripts open only as apps.")
        case .noHandler(let name):
            return Localization.format("core.item.error.noHandler", "No app on this Mac opens “%@”.", name)
        case .volumeUnavailable(let name):
            return Localization.format("core.item.error.volume", "It's on “%@”, which isn't connected.", name)
        case .unchecked:
            return Localization.string("core.item.error.unchecked", "wasn't opened, because macOS didn't allow checking what it is.")
        }
    }
}
