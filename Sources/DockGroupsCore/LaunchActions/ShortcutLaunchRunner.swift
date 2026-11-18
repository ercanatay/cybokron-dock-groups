import AppKit

// Launch actions: running the user's shortcut (docs/design/launch-action-shortcut.md §3.3, §3.4,
// §6). The only file that builds a `shortcuts://` address or hands one to the system.
//
// What is sent is fixed: one `shortcuts://run-shortcut` address whose query is the shortcut's name
// and nothing else, built here from a constant and the checked name with a strict percent-encoding
// and read back before use. It's handed to Shortcuts.app named explicitly (never to whatever app
// claims the scheme), in the background. No child process, no shell, no `shortcuts` command-line
// tool, no Apple events script, no callback address, no input of any kind, nothing coming back
// (a source scan keeps it so: `ShortcutLaunchRunnerTests`). Nothing here logs:
// the launcher logs the refusal's fixed code only, never the name.

/// What the shortcut runner needs of the system.
@MainActor
protocol ShortcutOpening: AnyObject {
    /// Where the app with this bundle identifier is installed, or `nil` when it isn't.
    func applicationLocation(bundleIdentifier: String) -> URL?
    /// The bundle identifier of the app bundle at `url`, or `nil` when it has none.
    func bundleIdentifier(ofApplicationAt url: URL) -> String?
    /// Hands `url` to the app at `applicationURL` (and only to it) with `configuration`.
    func openShortcutURL(_ url: URL, withApplicationAt applicationURL: URL, configuration: NSWorkspace.OpenConfiguration) async throws
}

/// The address that runs a shortcut by name: `shortcuts://run-shortcut?name=<name>`.
enum ShortcutRunURL {
    static let scheme = "shortcuts"
    static let host = "run-shortcut"
    /// The only query item there is.
    static let nameKey = "name"
    /// Everything before the encoded name.
    static let prefix = "\(scheme)://\(host)?\(nameKey)="

    /// `value` with every UTF-8 byte outside RFC 3986's unreserved set (`A–Z a–z 0–9 - . _ ~`)
    /// written as `%XX`. Not `URLComponents`, which leaves `+ ? / ;` as they are.
    static func percentEncoded(_ value: String) -> String {
        var encoded = ""
        for byte in value.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E:
                encoded.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                encoded += String(format: "%%%02X", byte)
            }
        }
        return encoded
    }

    /// The address for `name`, or `nil` when the name breaks the grammar (`ShortcutName`) or the
    /// address doesn't read back as exactly this name (`name(in:)`).
    static func make(name: String) -> URL? {
        guard ShortcutName.rejection(for: name) == nil,
              let url = URL(string: prefix + percentEncoded(name)),
              isExactly(url, name: name)
        else { return nil }
        return url
    }

    /// Whether `url` reads back as the address for `name` and nothing else: the text is the prefix
    /// and the strictly encoded name, and parsed it has the scheme and host, no user, password, port,
    /// path or fragment, and one query item, `name`, equal to `name` scalar by scalar (`String`'s `==`
    /// would call NFC and NFD the same).
    static func isExactly(_ url: URL, name: String) -> Bool {
        guard url.absoluteString == prefix + percentEncoded(name),
              let decoded = self.name(in: url)
        else { return false }
        return decoded.unicodeScalars.elementsEqual(name.unicodeScalars)
    }

    /// The name `url` would run, or `nil` when it isn't an address of exactly this shape.
    static func name(in url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == scheme, components.host == host,
              components.user == nil, components.password == nil, components.port == nil,
              components.path.isEmpty, components.fragment == nil,
              let items = components.queryItems, items.count == 1,
              let item = items.first, item.name == nameKey,
              let value = item.value, !value.isEmpty
        else { return nil }
        return value
    }
}

/// Why a shortcut wasn't handed to Shortcuts before anything was asked of the system or the
/// screen lock. Fixed reasons that hold nothing from the item, logged as `plan.<reason>`.
enum ShortcutPlanRefusal: String, Error, CaseIterable, Hashable, Sendable {
    /// The action came in with a backup, template or agent copy and is off until turned on.
    case actionDisabled
    /// The action was refused when it was read or set, or its name fails the grammar again here.
    case actionNeedsReview
    /// The item isn't the Shortcuts app's (`com.apple.shortcuts`), or its action isn't a shortcut.
    case notShortcutsItem
    /// The address wasn't built or didn't read back as exactly the name.
    case urlRejected
    /// Shortcuts.app isn't at `/System/Applications/` with its own bundle identifier.
    case shortcutsNotInstalled
}

/// Why a checked shortcut wasn't run. Fixed reasons, logged as `run.<reason>`.
enum ShortcutRunRefusal: String, Error, CaseIterable, Hashable, Sendable {
    /// The screen is locked.
    case screenLocked
    /// Whether the screen is locked can't be told; refused as if it were.
    case lockUnknown
    /// The same item with the same approved action was asked to run less than
    /// `ShortcutRecentRuns.interval` ago.
    case recentlyRun
    /// The system didn't take the address.
    case openFailed
}

/// The last runs of each item and approved action, so a second request within
/// `interval` seconds (a double click, the same item twice in one request) is refused. Kept in
/// memory only; holds the item's identity and the action's digest, never the name.
@MainActor
final class ShortcutRecentRuns {
    static let interval: TimeInterval = 2

    /// Seconds on a clock that doesn't go back (the system's uptime); tests put in their own.
    var now: () -> TimeInterval = { TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }
    private var lastRuns: [String: TimeInterval] = [:]

    /// Whether the item and digest ran less than `interval` ago (or, should the clock seem to have
    /// gone back, later than now).
    func ranRecently(item: String, digest: String) -> Bool {
        guard let last = lastRuns[Self.key(item, digest)] else { return false }
        return now() - last < Self.interval
    }

    /// Records a run now, and forgets runs that no longer count.
    func record(item: String, digest: String) {
        let time = now()
        lastRuns = lastRuns.filter { time - $0.value < Self.interval }
        lastRuns[Self.key(item, digest)] = time
    }

    private static func key(_ item: String, _ digest: String) -> String { item + "\n" + digest }
}

/// Runs the shortcut of a Shortcuts app's item, after every gate, in this order, the first failure
/// winning and nothing opened then:
///
/// 1. the user asked, in the app itself (`LaunchSource.userAction` only: not a link, the CLI, an
///    intent, a Focus, a trigger, a keyboard shortcut or a standalone group's app);
/// 2. the action is on, a shortcut, its name passes the grammar, and the item is the Shortcuts app's;
/// 3. this Mac's approval file has exactly this action's digest (`approval`, read now);
/// 4. the screen is unlocked (locked or unknown: refused);
/// 5. the same item and digest didn't run less than two seconds ago;
/// 6. the address is built and reads back as exactly the name;
/// 7. Shortcuts.app is under `/System/Applications/` with its own bundle identifier;
///
/// then the run is recorded and the address handed to Shortcuts. Success means Shortcuts has the
/// address, not that the shortcut ran: a missing or failing shortcut is Shortcuts' own alert.
@MainActor
struct ShortcutLaunchRunner {
    /// `nil` when the workspace can't open a shortcut's address.
    let opener: ShortcutOpening?
    /// Whether the screen is locked now; `nil` when that can't be told.
    let isScreenLocked: @MainActor () -> Bool?
    let recentRuns: ShortcutRecentRuns

    static let shortcutsBundleIdentifier = LaunchAction.shortcutsBundleIdentifier
    /// Where Shortcuts.app must be: the sealed system volume's apps.
    static let systemApplicationsPath = "/System/Applications/"

    enum Outcome: Hashable, Sendable {
        /// Shortcuts has the address.
        case handedToShortcuts
        case refused(LaunchActionItemRefusal)
    }

    /// Whether the launcher runs `item` through this runner: its action is a shortcut (on or under
    /// review as imported), or it's the Shortcuts app's item with any action.
    static func handles(_ item: GroupItem) -> Bool {
        if item.isShortcutsApplication { return true }
        switch item.launchActionSetting {
        case .enabled(.shortcut)?, .needsReview(.imported(.shortcut))?: return true
        default: return false
        }
    }

    func run(_ item: GroupItem, source: LaunchSource, approval: () -> LaunchActionApprovalRefusal?) async -> Outcome {
        guard source == .userAction else { return .refused(.unattendedSource(source)) }
        let name: String
        switch item.launchActionSetting {
        case .enabled(.shortcut(let enabledName))?:
            name = enabledName
        case .enabled?:
            return .refused(.shortcutPlan(.notShortcutsItem))
        case .needsReview(.imported)?:
            return .refused(.shortcutPlan(.actionDisabled))
        case .needsReview(.invalid)?, nil:
            return .refused(.shortcutPlan(.actionNeedsReview))
        }
        guard ShortcutName.rejection(for: name) == nil else { return .refused(.shortcutPlan(.actionNeedsReview)) }
        guard LaunchAction.shortcut(name: name).isAllowed(for: item.kind, identity: item.bundleIdentifier) else {
            return .refused(.shortcutPlan(.notShortcutsItem))
        }
        if let refusal = approval() { return .refused(.approval(refusal)) }
        switch isScreenLocked() {
        case false?: break
        case true?: return .refused(.shortcutRun(.screenLocked))
        case nil: return .refused(.shortcutRun(.lockUnknown))
        }
        guard let digest = LaunchActionApprovalDigest.digest(for: item) else { return .refused(.shortcutPlan(.actionNeedsReview)) }
        let identity = item.normalizedBundleIdentifier
        guard !recentRuns.ranRecently(item: identity, digest: digest) else { return .refused(.shortcutRun(.recentlyRun)) }
        guard let url = ShortcutRunURL.make(name: name) else { return .refused(.shortcutPlan(.urlRejected)) }
        guard let opener else { return .refused(.noRunner) }
        guard let shortcuts = shortcutsLocation(opener) else { return .refused(.shortcutPlan(.shortcutsNotInstalled)) }
        // Recorded before the address is handed over, with no suspension since the check above, so
        // a second request can't pass while the first is under way. A failed open counts too.
        recentRuns.record(item: identity, digest: digest)
        do {
            try await opener.openShortcutURL(url, withApplicationAt: shortcuts, configuration: Self.configuration())
            return .handedToShortcuts
        } catch {
            // The error may quote the address, so it goes nowhere.
            return .refused(.shortcutRun(.openFailed))
        }
    }

    /// Shortcuts.app as LaunchServices has it, only when it's an app bundle under
    /// `/System/Applications/` whose own bundle identifier is `com.apple.shortcuts`.
    func shortcutsLocation(_ opener: ShortcutOpening) -> URL? {
        guard let location = opener.applicationLocation(bundleIdentifier: Self.shortcutsBundleIdentifier),
              location.isFileURL
        else { return nil }
        let path = location.standardizedFileURL.path
        guard path.hasPrefix(Self.systemApplicationsPath), FileLocation.isAppBundlePath(path),
              let found = opener.bundleIdentifier(ofApplicationAt: location),
              found.lowercased() == Self.shortcutsBundleIdentifier
        else { return nil }
        return location
    }

    /// In the background (Shortcuts' own alert still shows), not in Recent Items, no arguments, an
    /// empty environment, never a second instance.
    static func configuration() -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.arguments = []
        configuration.environment = [:]
        configuration.createsNewApplicationInstance = false
        return configuration
    }
}

extension SystemApplicationWorkspace: ShortcutOpening {
    func openShortcutURL(_ url: URL, withApplicationAt applicationURL: URL, configuration: NSWorkspace.OpenConfiguration) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            workspace.open([url], withApplicationAt: applicationURL, configuration: configuration) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
