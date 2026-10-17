import AppKit
import DockGroupsCore

/// The menu bar item. Its menu lists the groups; choosing one opens all of its apps.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    struct Actions {
        let openAll: (DockGroup) -> Void
        let showMainWindow: () -> Void
    }

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

    private func rebuildMenu() {
        menu.removeAllItems()
        menu.addItem(.sectionHeader(title: "Open All"))
        if store.groups.isEmpty {
            let placeholder = NSMenuItem(title: "No groups yet", action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            menu.addItem(placeholder)
        } else {
            for group in store.groups {
                menu.addItem(item(for: group))
            }
        }

        menu.addItem(.separator())
        let manage = NSMenuItem(title: "Manage Groups…", action: #selector(showMainWindow(_:)), keyEquivalent: ",")
        manage.target = self
        menu.addItem(manage)

        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit \(AppInfo.name)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        menu.addItem(quit)
    }

    private func item(for group: DockGroup) -> NSMenuItem {
        let item = NSMenuItem(title: "\(group.emoji)  \(group.name)", action: #selector(openGroup(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = group.id
        let appCount = group.apps.count
        item.isEnabled = appCount > 0
        item.badge = appCount > 0 ? NSMenuItemBadge(count: appCount) : nil
        item.toolTip = appCount > 0
            ? "Open all \(appCount) \(appCount == 1 ? "app" : "apps") in “\(group.name)”"
            : "“\(group.name)” has no apps yet."
        return item
    }

    @objc private func openGroup(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let group = store.group(withID: id) else { return }
        actions.openAll(group)
    }

    @objc private func showMainWindow(_ sender: NSMenuItem) {
        actions.showMainWindow()
    }
}
