import AppKit

/// What LaunchServices knows about apps, for choosing the app that opens an item. The app's
/// implementation asks `NSWorkspace`; tests use a fake.
@MainActor
public protocol ApplicationCatalog: AnyObject {
    /// Where the app with this bundle identifier is, `nil` when it isn't on this Mac.
    func applicationURL(forBundleIdentifier bundleIdentifier: String) -> URL?
    /// The apps that declare they open `url` (`NSWorkspace.urlsForApplications(toOpen:)`).
    func applicationURLs(toOpen url: URL) -> [URL]
    /// The bundle identifier of the app at `url`, read from its bundle.
    func bundleIdentifier(ofApplicationAt url: URL) -> String?
}

/// `ApplicationCatalog` backed by `NSWorkspace` and the apps' bundles.
@MainActor
public final class SystemApplicationCatalog: ApplicationCatalog {
    private let workspace: NSWorkspace

    public init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    public func applicationURL(forBundleIdentifier bundleIdentifier: String) -> URL? {
        workspace.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    public func applicationURLs(toOpen url: URL) -> [URL] {
        workspace.urlsForApplications(toOpen: url)
    }

    public func bundleIdentifier(ofApplicationAt url: URL) -> String? {
        Bundle(url: url)?.bundleIdentifier
    }
}

/// What opening an item with its chosen app comes to (`ItemOpenerPolicy.decide`).
public enum ItemOpenerDecision: Equatable, Sendable {
    /// Open it with its default app: it has no chosen app, or the chosen app isn't on this Mac
    /// (an older version would open it that way too).
    case defaultApp
    /// Open it with the app at this location, which passed every check.
    case openWith(URL)
    /// Don't open it at all — not with the default app either: the chosen app could run it, isn't
    /// an app that opens it, or isn't what it claims to be. That means the setting is wrong or was
    /// crafted.
    case refused(openerName: String)
}

/// Decides whether an item may be opened with the app chosen for it (spec §3.5, §5.3). The item
/// itself is checked first, exactly as without a chosen app (`GroupLauncher`); then the app:
///
/// 1. none chosen, or the item is an app → the default app;
/// 2. not on this Mac → the default app;
/// 3. found by its bundle identifier, it must be an app bundle with that very bundle identifier;
/// 4. it must not be an app that runs what it opens — a terminal, an installer, a script runner
///    (`runnerBundleIdentifiers`) — except Terminal and iTerm2 for a folder item;
/// 5. macOS must list it among the apps that open the item (Terminal and iTerm2 for a folder
///    excepted: macOS doesn't list them for folders).
///
/// Any check from 3 on that fails refuses the item: it isn't opened, not even with its default app.
public enum ItemOpenerPolicy {
    /// Apps that run the files they're given rather than show them: never the app that opens a
    /// file or website, and of a folder only the terminals of `folderTerminalBundleIdentifiers`.
    /// Lowercased.
    public static let runnerBundleIdentifiers: Set<String> = FileItemPolicy.refusedHandlerBundleIdentifiers.union([
        "dev.warp.warp-stable",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "org.python.pythonlauncher",
        "com.apple.automator.automator-application-stub",
    ])

    /// Bundle identifiers starting like this are script applets (Script Editor's "Application"
    /// format): runners too. Lowercased.
    public static let runnerBundleIdentifierPrefixes = ["com.apple.scripteditor.id."]

    /// The terminals that may open a folder item: they start a shell in that folder. Lowercased.
    public static let folderTerminalBundleIdentifiers: Set<String> = ["com.apple.terminal", "com.googlecode.iterm2"]

    /// Whether the app with this bundle identifier runs what it opens (any case).
    public static func isRunner(bundleIdentifier: String) -> Bool {
        let identifier = bundleIdentifier.lowercased()
        return runnerBundleIdentifiers.contains(identifier) || runnerBundleIdentifierPrefixes.contains { identifier.hasPrefix($0) }
    }

    /// Whether an item of `kind` may be opened with the app with this bundle identifier as far as
    /// its identity tells, without asking LaunchServices: not a runner, except a folder terminal for
    /// a folder. Backups are stricter still (`SettingsBackup.sanitizedForImport`).
    public static func acceptsOpener(bundleIdentifier: String, for kind: AppReference.Kind) -> Bool {
        if kind == .folder, folderTerminalBundleIdentifiers.contains(bundleIdentifier.lowercased()) { return true }
        return !isRunner(bundleIdentifier: bundleIdentifier)
    }

    /// How `item` opens, given its chosen app `opener`. `target` is what opening it would open: the
    /// file's or folder's checked location (symbolic links resolved), or the website's address.
    @MainActor
    public static func decide(_ opener: ItemOpener?, for item: GroupItem, target: URL, catalog: ApplicationCatalog) -> ItemOpenerDecision {
        guard let opener, item.kind != .application else { return .defaultApp }
        guard let applicationURL = catalog.applicationURL(forBundleIdentifier: opener.bundleIdentifier) else { return .defaultApp }
        let refused = ItemOpenerDecision.refused(openerName: opener.name)
        guard applicationURL.isFileURL,
              FileLocation.isAppBundlePath(applicationURL.standardizedFileURL.path),
              catalog.bundleIdentifier(ofApplicationAt: applicationURL)?.lowercased() == opener.normalizedBundleIdentifier
        else { return refused }
        let isFolderTerminal = item.kind == .folder && folderTerminalBundleIdentifiers.contains(opener.normalizedBundleIdentifier)
        if isFolderTerminal { return .openWith(applicationURL) }
        guard acceptsOpener(bundleIdentifier: opener.bundleIdentifier, for: item.kind) else { return refused }
        let listed = Set(catalog.applicationURLs(toOpen: target).map(Self.comparable))
        guard listed.contains(comparable(applicationURL)) else { return refused }
        return .openWith(applicationURL)
    }

    /// A location as two URLs of the same app bundle compare equal.
    private static func comparable(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
    }
}
