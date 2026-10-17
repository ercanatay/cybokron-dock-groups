import AppKit
import DockGroupsCore

/// The menu bar item. Its menu lists the groups with their tiles: choosing one shows the group's
/// popup, choosing it with ⌥ held opens all of its apps right away.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    struct Actions {
        let showPopup: (DockGroup) -> Void
        let openAll: (DockGroup) -> Void
        let showMainWindow: () -> Void
        let showSettings: () -> Void
        let showAbout: () -> Void
        let menuWillOpen: () -> Void
        /// The group's tile, sized for a menu item.
        let tileImage: (DockGroup) -> NSImage
    }

    static let menuTileSize: CGFloat = 18

    private let store: GroupStore
    private let actions: Actions
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    init(store: GroupStore, actions: Actions) {
        self.store = store
        self.actions = actions
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: AppInfo.name)
            image?.isTemplate = true
            button.image = image
            button.toolTip = AppInfo.name
        }
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
    }

    /// Rebuilt right before the menu opens, so it always reflects the current groups.
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        actions.menuWillOpen()
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        menu.addItem(.sectionHeader(title: "Groups"))
        if store.groups.isEmpty {
            let placeholder = NSMenuItem(title: "No groups yet", action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            menu.addItem(placeholder)
        } else {
            for group in store.groups {
                menu.addItem(popupItem(for: group))
                menu.addItem(openAllItem(for: group))
            }
        }

        menu.addItem(.separator())
        let manage = NSMenuItem(title: "Manage Groups…", action: #selector(showMainWindow(_:)), keyEquivalent: "g")
        manage.target = self
        menu.addItem(manage)
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let about = NSMenuItem(title: "About \(AppInfo.name)", action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit \(AppInfo.name)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        menu.addItem(quit)
    }

    private func popupItem(for group: DockGroup) -> NSMenuItem {
        let item = NSMenuItem(title: group.name, action: #selector(showPopup(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = group.id
        item.image = actions.tileImage(group)
        item.keyEquivalentModifierMask = []
        let appCount = group.apps.count
        item.badge = appCount > 0 ? NSMenuItemBadge(count: appCount) : nil
        item.toolTip = "Show the apps in “\(group.name)”. Hold ⌥ to open them all at once."
        return item
    }

    /// Replaces the group's item while ⌥ is held.
    private func openAllItem(for group: DockGroup) -> NSMenuItem {
        let item = NSMenuItem(title: "Open All in “\(group.name)”", action: #selector(openGroup(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = group.id
        item.image = actions.tileImage(group)
        item.keyEquivalentModifierMask = [.option]
        item.isAlternate = true
        let appCount = group.apps.count
        item.isEnabled = appCount > 0
        item.toolTip = appCount > 0
            ? "Open all \(appCount) \(appCount == 1 ? "app" : "apps") in “\(group.name)”"
            : "“\(group.name)” has no apps yet."
        return item
    }

    private func group(for sender: NSMenuItem) -> DockGroup? {
        (sender.representedObject as? UUID).flatMap(store.group(withID:))
    }

    @objc private func showPopup(_ sender: NSMenuItem) {
        guard let group = group(for: sender) else { return }
        actions.showPopup(group)
    }

    @objc private func openGroup(_ sender: NSMenuItem) {
        guard let group = group(for: sender) else { return }
        actions.openAll(group)
    }

    @objc private func showMainWindow(_ sender: NSMenuItem) {
        actions.showMainWindow()
    }

    @objc private func showSettings(_ sender: NSMenuItem) {
        actions.showSettings()
    }

    @objc private func showAbout(_ sender: NSMenuItem) {
        actions.showAbout()
    }
}
