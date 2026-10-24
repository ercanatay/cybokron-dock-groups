import Foundation
@testable import DockGroupsCore

/// LaunchServices as the tests want it: installed apps by bundle identifier, and the apps that open
/// a location or address.
@MainActor
final class FakeCatalog: ApplicationCatalog {
    private var locations: [String: URL] = [:]
    private var bundleIdentifiers: [String: String] = [:]
    private var listed: [String: [URL]] = [:]
    private(set) var listingQuestions = 0

    /// Installs the app with this bundle identifier at `path` (by default `/Applications/<name>.app`);
    /// returns its location. `claims` is the bundle identifier its bundle says it has.
    @discardableResult
    func install(_ bundleIdentifier: String, at path: String? = nil, claims: String? = nil) -> URL {
        let url = URL(fileURLWithPath: path ?? "/Applications/\(bundleIdentifier.split(separator: ".").last ?? "App").app", isDirectory: true)
        locations[bundleIdentifier.lowercased()] = url
        bundleIdentifiers[url.standardizedFileURL.path] = claims ?? bundleIdentifier
        return url
    }

    /// Says the app at `app` opens `target`.
    func list(_ app: URL, for target: URL) {
        listed[Self.key(target), default: []].append(app)
    }

    func applicationURL(forBundleIdentifier bundleIdentifier: String) -> URL? {
        locations[bundleIdentifier.lowercased()]
    }

    func applicationURLs(toOpen url: URL) -> [URL] {
        listingQuestions += 1
        return listed[Self.key(url)] ?? []
    }

    func bundleIdentifier(ofApplicationAt url: URL) -> String? {
        bundleIdentifiers[url.standardizedFileURL.path]
    }

    private static func key(_ url: URL) -> String {
        url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
    }
}

/// Records what it's asked to open instead of opening it: "launch:<bundle id>",
/// "files:<names>", "websites:<addresses>", "open:<app>:<names or addresses>".
@MainActor
final class OpenerRecordingWorkspace: ApplicationWorkspace {
    private(set) var events: [String] = []
    var installed: Set<String> = []
    var refusesOpening = false

    func activateRunningApplication(bundleIdentifier: String) -> Bool { false }

    func locateApplication(_ app: AppReference) -> URL? {
        installed.contains(app.bundleIdentifier) ? URL(fileURLWithPath: "/Applications/\(app.bundleIdentifier).app") : nil
    }

    func launchApplication(at url: URL) async throws {
        events.append("launch:\(url.deletingPathExtension().lastPathComponent)")
    }

    func openWebsites(_ urls: [URL]) async throws {
        events.append("websites:\(urls.map(\.absoluteString).joined(separator: ","))")
    }

    func openFileItems(_ urls: [URL]) async -> [URL: any Error] {
        events.append("files:\(urls.map(\.lastPathComponent).joined(separator: ","))")
        return [:]
    }

    func revealFileItems(_ urls: [URL]) {}

    func open(_ urls: [URL], withApplicationAt applicationURL: URL) async throws {
        let names = urls.map { $0.isFileURL ? $0.lastPathComponent : $0.absoluteString }
        events.append("open:\(applicationURL.deletingPathExtension().lastPathComponent):\(names.joined(separator: ","))")
        if refusesOpening { throw FileItemOpeningError.noHandler(name: "x") }
    }
}

/// Waits until told to: `wake(upTo:)` ends the sleeps of at most that many seconds.
@MainActor
final class FakeSleeper: Sleeping {
    private var sleeping: [(seconds: Int, continuation: CheckedContinuation<Void, Error>)] = []
    private(set) var requested: [Int] = []

    var sleepingCount: Int { sleeping.count }

    func sleep(for duration: Duration) async throws {
        let seconds = Int(duration.components.seconds)
        requested.append(seconds)
        try await withCheckedThrowingContinuation { sleeping.append((seconds, $0)) }
    }

    func wake(upTo seconds: Int) {
        let due = sleeping.filter { $0.seconds <= seconds }
        sleeping.removeAll { $0.seconds <= seconds }
        due.forEach { $0.continuation.resume() }
    }

    func wakeAll() {
        wake(upTo: .max)
    }
}

/// Lets the main actor run the tasks started meanwhile until `condition` holds (or gives up).
@MainActor
func settle(until condition: () -> Bool) async {
    var tries = 0
    while !condition(), tries < 1_000 {
        await Task.yield()
        tries += 1
    }
}

extension GroupItem {
    /// The item with these launch options.
    func launching(after delay: Int = 0, with opener: ItemOpener? = nil) -> GroupItem {
        var item = self
        item.launch = ItemLaunchOptions(delay: delay, opener: opener)
        return item
    }
}

extension ItemOpener {
    static func app(_ bundleIdentifier: String, _ name: String? = nil) -> ItemOpener {
        ItemOpener(bundleIdentifier: bundleIdentifier, name: name ?? bundleIdentifier)!
    }
}
