import AppKit

/// Builds the main menu. A menu bar utility never shows it, but its key equivalents still work
/// while the app's window is active (⌘, ⌘Q, ⌘W, and the text-editing shortcuts in text fields).
@MainActor
enum MainMenuBuilder {
    static func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(submenuItem(appMenu()))
        mainMenu.addItem(submenuItem(editMenu()))
        let windowMenu = windowMenu()
        mainMenu.addItem(submenuItem(windowMenu))
        NSApp.windowsMenu = windowMenu
        return mainMenu
    }

    /// The main menu of a standalone group's agent while it runs as a regular app, named after the
    /// group: Hide and Quit. It shows only while the agent is active, that is while its popup is open.
    static func makeAgentMenu(groupName: String) -> NSMenu {
        let menu = NSMenu(title: groupName)
        menu.addItem(withTitle: L10n.Common.hideApp(groupName), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.Common.quitApp(groupName), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let mainMenu = NSMenu()
        mainMenu.addItem(submenuItem(menu))
        return mainMenu
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: AppInfo.name)
        // No target: the responder chain delivers these to the app delegate.
        menu.addItem(withTitle: L10n.Common.about(AppInfo.name), action: #selector(AppDelegate.showAboutWindow(_:)), keyEquivalent: "")
        menu.addItem(withTitle: L10n.Common.checkForUpdates, action: #selector(AppDelegate.checkForUpdates(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.Common.settings, action: #selector(AppDelegate.showSettingsWindow(_:)), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.Common.hideApp(AppInfo.name), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.Common.quitApp(AppInfo.name), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: L10n.MainMenu.edit)
        menu.addItem(withTitle: L10n.MainMenu.undo, action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: L10n.MainMenu.redo, action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.MainMenu.cut, action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: L10n.Common.copy, action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: L10n.MainMenu.paste, action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: L10n.MainMenu.selectAll, action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: L10n.MainMenu.window)
        menu.addItem(withTitle: L10n.Common.close, action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        menu.addItem(withTitle: L10n.MainMenu.minimize, action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        return menu
    }

    private static func submenuItem(_ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }
}

enum AppInfo {
    static let name = "Cybokron Dock Groups"
    static let repositoryURL = URL(string: "https://github.com/ercanatay/cybokron-dock-groups")!
    static let licenseURL = URL(string: "https://github.com/ercanatay/cybokron-dock-groups/blob/main/LICENSE")!

    /// The marketing version, e.g. "0.3.0".
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    static var copyright: String? {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
    }
}
