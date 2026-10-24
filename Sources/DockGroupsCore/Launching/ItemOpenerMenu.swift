import Foundation

/// An app the details editor offers to open an item with: one that passes every check of
/// `ItemOpenerPolicy` for that item.
public struct ItemOpenerChoice: Equatable, Sendable, Identifiable {
    public let opener: ItemOpener
    public let applicationURL: URL

    public init(opener: ItemOpener, applicationURL: URL) {
        self.opener = opener
        self.applicationURL = applicationURL
    }

    public var id: String { opener.normalizedBundleIdentifier }
}

/// How the app chosen for an item stands right now, for the details editor.
public enum ItemOpenerStatus: Equatable, Sendable {
    /// No app is chosen: the default app opens the item.
    case defaultApp
    /// The chosen app is here and may open the item.
    case available
    /// The chosen app isn't on this Mac: the item opens with its default app (spec §2.9).
    case notOnThisMac
    /// The chosen app is here but may not open the item (`ItemOpenerPolicy`): the item won't open
    /// at all until another app is chosen.
    case refused

    /// What the editor says under the menu about the chosen app `openerName`; `nil` when all is well.
    public func message(openerName: String) -> String? {
        switch self {
        case .defaultApp, .available:
            return nil
        case .notOnThisMac:
            return Localization.format("item.launch.status.notOnThisMac", "“%@” isn't on this Mac: the item opens with its default app.", openerName)
        case .refused:
            return Localization.format("item.launch.status.refused", "“%@” can't open this item safely, so the item won't open. Choose another app.", openerName)
        }
    }
}

/// Why the details editor won't take an app chosen with "Other…": the same checks as when the item
/// opens (`ItemOpenerPolicy`), so nothing the editor accepts is refused later, and nothing refused
/// there is set.
public enum ItemOpenerRefusal: Error, Equatable, Sendable {
    /// Not an app bundle, or one without a bundle identifier.
    case notAnApp(name: String)
    /// macOS doesn't know the app by its bundle identifier (it was never opened, or it's somewhere
    /// LaunchServices doesn't look): the item would open with its default app instead.
    case unknownToMacOS(name: String)
    /// It runs what it opens: a terminal (except for a folder), an installer, a script runner.
    case runsItems(name: String)
    /// macOS doesn't list it among the apps that open the item.
    case notListed(name: String)

    public var message: String {
        switch self {
        case .notAnApp(let name):
            return Localization.format("item.launch.refusal.notAnApp", "“%@” isn't an app that can open items.", name)
        case .unknownToMacOS(let name):
            return Localization.format("item.launch.refusal.unknown", "macOS doesn't know “%@” yet. Open it once, then choose it again.", name)
        case .runsItems(let name):
            return Localization.format("item.launch.refusal.runsItems", "“%@” runs what it opens, so it can't open this item.", name)
        case .notListed(let name):
            return Localization.format("item.launch.refusal.notListed", "“%@” isn't one of the apps macOS lists for this item.", name)
        }
    }
}

/// The "Open with" menu of the details editor (spec §4.3): the default app's name, then the apps
/// macOS lists for the item that may open it (`ItemOpenerPolicy.decide`), sorted by name — for a
/// folder Terminal and iTerm2 too, when they're here (DECISION 5) — and how the app chosen now
/// stands. Built once when the editor opens; LaunchServices is asked for the item's apps once.
public struct ItemOpenerMenu: Equatable, Sendable {
    /// The app that opens the item without a choice; `nil` when macOS has none for it.
    public let defaultAppName: String?
    public let choices: [ItemOpenerChoice]
    /// The app chosen now (`opener`), and how it stands.
    public let current: ItemOpener?
    public let currentStatus: ItemOpenerStatus

    /// - Parameter target: What opening the item opens: its checked location (`ItemPresence.available`),
    ///   or its own location or web address when it couldn't be checked.
    @MainActor
    public init(for item: GroupItem, opener: ItemOpener?, target: URL, catalog: ApplicationCatalog) {
        let catalog = ListingOnce(catalog)
        defaultAppName = catalog.defaultApplicationURL(toOpen: target).map(catalog.name(ofApplicationAt:))
        var candidates = catalog.applicationURLs(toOpen: target)
        if item.kind == .folder {
            candidates += ItemOpenerPolicy.folderTerminalBundleIdentifiers.sorted().compactMap(catalog.applicationURL(forBundleIdentifier:))
        }
        var seen = Set<String>()
        var choices: [ItemOpenerChoice] = []
        for url in candidates {
            guard let identifier = catalog.bundleIdentifier(ofApplicationAt: url),
                  let opener = ItemOpener(bundleIdentifier: identifier, name: catalog.name(ofApplicationAt: url)),
                  seen.insert(opener.normalizedBundleIdentifier).inserted,
                  case .openWith(let applicationURL) = ItemOpenerPolicy.decide(opener, for: item, target: target, catalog: catalog)
            else { continue }
            choices.append(ItemOpenerChoice(opener: opener, applicationURL: applicationURL))
        }
        self.choices = choices.sorted { $0.opener.name.localizedStandardCompare($1.opener.name) == .orderedAscending }
        current = opener
        currentStatus = Self.status(of: opener, for: item, target: target, catalog: catalog)
    }

    /// The choice for `opener`, when the menu offers it.
    public func choice(for opener: ItemOpener?) -> ItemOpenerChoice? {
        guard let opener else { return nil }
        return choices.first { $0.id == opener.normalizedBundleIdentifier }
    }

    /// How `opener` stands for `item` (`ItemOpenerPolicy.decide`).
    @MainActor
    public static func status(of opener: ItemOpener?, for item: GroupItem, target: URL, catalog: ApplicationCatalog) -> ItemOpenerStatus {
        guard let opener, item.kind != .application else { return .defaultApp }
        switch ItemOpenerPolicy.decide(opener, for: item, target: target, catalog: catalog) {
        case .defaultApp: return .notOnThisMac
        case .openWith: return .available
        case .refused: return .refused
        }
    }

    /// The app chosen with "Other…" at `applicationURL`, checked as it will be when the item opens:
    /// the opener to set, or why it isn't taken (fail closed).
    @MainActor
    public static func check(_ applicationURL: URL, for item: GroupItem, target: URL, catalog: ApplicationCatalog) -> Result<ItemOpener, ItemOpenerRefusal> {
        let fallbackName = applicationURL.deletingPathExtension().lastPathComponent
        guard item.kind != .application,
              applicationURL.isFileURL,
              FileLocation.isAppBundlePath(applicationURL.standardizedFileURL.path),
              let identifier = catalog.bundleIdentifier(ofApplicationAt: applicationURL),
              let opener = ItemOpener(bundleIdentifier: identifier, name: catalog.name(ofApplicationAt: applicationURL))
        else { return .failure(.notAnApp(name: fallbackName)) }
        switch ItemOpenerPolicy.decide(opener, for: item, target: target, catalog: catalog) {
        case .openWith:
            return .success(opener)
        case .defaultApp:
            return .failure(.unknownToMacOS(name: opener.name))
        case .refused:
            return ItemOpenerPolicy.acceptsOpener(bundleIdentifier: opener.bundleIdentifier, for: item.kind)
                ? .failure(.notListed(name: opener.name))
                : .failure(.runsItems(name: opener.name))
        }
    }
}

/// A catalog that asks the one it wraps which apps open a location only once: `decide` asks for
/// every app the menu checks.
@MainActor
private final class ListingOnce: ApplicationCatalog {
    private let base: ApplicationCatalog
    private var listed: [URL: [URL]] = [:]

    init(_ base: ApplicationCatalog) {
        self.base = base
    }

    func applicationURL(forBundleIdentifier bundleIdentifier: String) -> URL? {
        base.applicationURL(forBundleIdentifier: bundleIdentifier)
    }

    func applicationURLs(toOpen url: URL) -> [URL] {
        if let urls = listed[url] { return urls }
        let urls = base.applicationURLs(toOpen: url)
        listed[url] = urls
        return urls
    }

    func bundleIdentifier(ofApplicationAt url: URL) -> String? {
        base.bundleIdentifier(ofApplicationAt: url)
    }

    func defaultApplicationURL(toOpen url: URL) -> URL? {
        base.defaultApplicationURL(toOpen: url)
    }

    func name(ofApplicationAt url: URL) -> String {
        base.name(ofApplicationAt: url)
    }
}
