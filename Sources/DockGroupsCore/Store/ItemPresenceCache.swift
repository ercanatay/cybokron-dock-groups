import Combine
import Foundation

/// Where the items a window lists are, checked when something happened rather than while the
/// window draws: the group window checks its group's items when it shows the group, when it comes
/// to the front, when the items change and when a volume is connected or ejected. Its rows only
/// read the result, so drawing never looks at the disk or asks LaunchServices.
///
/// With a catalog, each check also looks up the apps chosen to open the items, one bundle
/// identifier lookup per app, so a row can say when its app isn't on this Mac.
@MainActor
public final class ItemPresenceCache: ObservableObject {
    /// By normalized identity (`AppReference.normalizedBundleIdentifier`). Published only when a
    /// check changes something.
    @Published public private(set) var presences: [String: ItemPresence] = [:]
    /// Whether each chosen app is on this Mac, by its normalized bundle identifier. Published only
    /// when a check changes something.
    @Published public private(set) var installedOpeners: [String: Bool] = [:]

    private let locator: ItemLocating
    private let catalog: ApplicationCatalog?
    private var tracked: [GroupItem] = []

    /// - Parameter catalog: Finds the apps chosen to open the items; without one they aren't checked.
    public init(locator: ItemLocating, catalog: ApplicationCatalog? = nil) {
        self.locator = locator
        self.catalog = catalog
    }

    /// Checks `items` now, and again on each `refresh()`, in place of the items checked before.
    public func track(_ items: [GroupItem]) {
        tracked = items
        refresh()
    }

    /// Checks the tracked items again.
    public func refresh() {
        var checked: [String: ItemPresence] = [:]
        for item in tracked {
            checked[item.normalizedBundleIdentifier] = locator.presence(of: item)
        }
        if checked != presences {
            presences = checked
        }
        guard let catalog else { return }
        var openers: [String: Bool] = [:]
        for item in tracked {
            guard let opener = item.launch.allowed(for: item.kind).opener, openers[opener.normalizedBundleIdentifier] == nil else { continue }
            openers[opener.normalizedBundleIdentifier] = catalog.applicationURL(forBundleIdentifier: opener.bundleIdentifier) != nil
        }
        if openers != installedOpeners {
            installedOpeners = openers
        }
    }

    /// Whether the app chosen to open `item` is on this Mac, as last checked; `nil` when it has no
    /// chosen app or it wasn't checked.
    public func isOpenerInstalled(_ item: GroupItem) -> Bool? {
        item.launch.opener.flatMap { installedOpeners[$0.normalizedBundleIdentifier] }
    }

    /// Checks one item now (as Show in Finder and Quick Look do before they show it), keeping the
    /// result when the item is tracked.
    @discardableResult
    public func check(_ item: GroupItem) -> ItemPresence {
        let presence = locator.presence(of: item)
        let key = item.normalizedBundleIdentifier
        if tracked.contains(where: { $0.normalizedBundleIdentifier == key }), presences[key] != presence {
            presences[key] = presence
        }
        return presence
    }

    /// The item's presence as last checked; `nil` before its first check.
    public func presence(of item: GroupItem) -> ItemPresence? {
        presences[item.normalizedBundleIdentifier]
    }

    /// The locator the checks go through, for adding and locating items (`ItemAddition`).
    public var itemLocator: ItemLocating { locator }
}
