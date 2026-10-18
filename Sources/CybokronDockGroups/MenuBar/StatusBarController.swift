import AppKit
import DockGroupsCore

/// The menu bar item. Its menu lists the groups with their tiles: choosing one shows the group's
/// popup, choosing it with ⌥ held opens all of its apps right away, and with ⇧⌥ held hides its
/// running apps. Below them, the Most Used
/// section lists the most launched apps: choosing one opens it, and the section's first item
/// shows them in a popup.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    struct Actions {
        let showPopup: (DockGroup) -> Void
        let openAll: (DockGroup) -> Void
        let hideAll: (DockGroup) -> Void
        let showMainWindow: () -> Void
        let showSettings: () -> Void
        let showAbout: () -> Void
        let checkForUpdates: () -> Void
        let menuWillOpen: () -> Void
        /// The group's tile, sized for a menu item.
        let tileImage: (DockGroup) -> NSImage
        /// The group's global shortcut ("⌃⌥1"), `nil` when it has none or shortcuts are off.
        let shortcutTitle: (DockGroup) -> String?
        /// The Most Used apps, best first; `nil` hides the section (turned off in Settings).
        let mostUsedEntries: () -> [MostUsedEntry]?
        let showMostUsedPopup: () -> Void
        let openMostUsedApp: (AppReference) -> Void
        /// The app's icon, sized for a menu item.
        let appIcon: (AppReference) -> NSImage
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

    /// The menu bar item's frame on screen, which popups chosen from its menu can hang from;
    /// `nil` while it isn't shown.
    var itemFrame: CGRect? {
        guard let button = statusItem.button, let window = button.window, window.isVisible else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
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
        menu.addItem(.sectionHeader(title: L10n.MenuBar.groupsHeader))
        if store.groups.isEmpty {
            let placeholder = NSMenuItem(title: L10n.MenuBar.noGroups, action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            menu.addItem(placeholder)
        } else {
            for group in store.groups {
                menu.addItem(popupItem(for: group))
                menu.addItem(openAllItem(for: group))
                menu.addItem(hideAllItem(for: group))
            }
        }
        addMostUsedSection()

        menu.addItem(.separator())
        let manage = NSMenuItem(title: L10n.MenuBar.manageGroups, action: #selector(showMainWindow(_:)), keyEquivalent: "g")
        manage.target = self
        menu.addItem(manage)
        let settings = NSMenuItem(title: L10n.Common.settings, action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let about = NSMenuItem(title: L10n.Common.about(AppInfo.name), action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        let updates = NSMenuItem(title: L10n.Common.checkForUpdates, action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        updates.target = self
        updates.toolTip = L10n.MenuBar.checkForUpdatesTooltip(AppInfo.name)
        menu.addItem(updates)

        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: L10n.Common.quitApp(AppInfo.name),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        menu.addItem(quit)
    }

    private func addMostUsedSection() {
        guard let entries = actions.mostUsedEntries() else { return }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: MostUsedGroup.name))
        guard !entries.isEmpty else {
            let placeholder = NSMenuItem(title: L10n.Common.noLaunchesYet, action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            placeholder.toolTip = L10n.MenuBar.noLaunchesTooltip
            menu.addItem(placeholder)
            return
        }
        let group = MostUsedGroup.group(with: entries)
        let show = NSMenuItem(title: L10n.MenuBar.showMostUsed, action: #selector(showMostUsed(_:)), keyEquivalent: "")
        show.target = self
        show.image = actions.tileImage(group)
        show.toolTip = L10n.MenuBar.showMostUsedTooltip
        menu.addItem(show)
        for entry in entries {
            let item = NSMenuItem(title: entry.app.name, action: #selector(openMostUsedApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.app
            item.image = actions.appIcon(entry.app)
            item.indentationLevel = 1
            item.toolTip = L10n.MenuBar.mostUsedAppTooltip(entry.app.name, launchCount: entry.launchCount)
            menu.addItem(item)
        }
    }

    private func popupItem(for group: DockGroup) -> NSMenuItem {
        let item = NSMenuItem(title: group.name, action: #selector(showPopup(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = group.id
        item.image = actions.tileImage(group)
        item.keyEquivalentModifierMask = []
        let appCount = group.apps.count
        item.badge = appCount > 0 ? NSMenuItemBadge(count: appCount) : nil
        item.toolTip = actions.shortcutTitle(group).map { L10n.MenuBar.groupTooltip(group.name, shortcut: $0) }
            ?? L10n.MenuBar.groupTooltip(group.name)
        return item
    }

    /// Replaces the group's item while ⌥ is held.
    private func openAllItem(for group: DockGroup) -> NSMenuItem {
        let item = NSMenuItem(title: L10n.MenuBar.openAllIn(group.name), action: #selector(openGroup(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = group.id
        item.image = actions.tileImage(group)
        item.keyEquivalentModifierMask = [.option]
        item.isAlternate = true
        let appCount = group.apps.count
        item.isEnabled = appCount > 0
        item.toolTip = appCount > 0
            ? L10n.MenuBar.openAllTooltip(group.name, appCount: appCount)
            : L10n.MenuBar.noAppsTooltip(group.name)
        return item
    }

    /// Replaces the group's item while ⇧⌥ is held. Apps that aren't running are left alone.
    private func hideAllItem(for group: DockGroup) -> NSMenuItem {
        let item = NSMenuItem(title: L10n.MenuBar.hideAllIn(group.name), action: #selector(hideGroup(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = group.id
        item.image = actions.tileImage(group)
        item.keyEquivalentModifierMask = [.option, .shift]
        item.isAlternate = true
        item.isEnabled = !group.apps.isEmpty
        item.toolTip = group.apps.isEmpty
            ? L10n.MenuBar.noAppsTooltip(group.name)
            : L10n.MenuBar.hideAllTooltip(group.name)
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

    @objc private func hideGroup(_ sender: NSMenuItem) {
        guard let group = group(for: sender) else { return }
        actions.hideAll(group)
    }

    @objc private func showMostUsed(_ sender: NSMenuItem) {
        actions.showMostUsedPopup()
    }

    @objc private func openMostUsedApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? AppReference else { return }
        actions.openMostUsedApp(app)
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

    @objc private func checkForUpdates(_ sender: NSMenuItem) {
        actions.checkForUpdates()
    }
}
