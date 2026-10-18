import DockGroupsCore
import Foundation

/// The app's user-facing text, by area: `L10n.Popup.footerSortAZ`, `L10n.Settings.Updates.checkNow`.
///
/// Every entry is a key of `Resources/<language>.lproj/Localizable.strings` with its English text,
/// which `en.lproj` repeats (`LocalizationTests` keep the two in step: add a key to both). Texts
/// with values are functions whose parameters fill the placeholders in order: `%@` takes a
/// `String`, `%ld` an `Int`. Counts pick a `.one` or `.other` key. Text from DockGroupsCore (error
/// messages, the Most Used name, …) is looked up there, through the same `Localization`.
///
/// Not localized here: the App Intents (titles, phrases, dialogs — they get their own catalog),
/// group, app and website names, the diagnostics report and log messages.
enum L10n {
    enum Common {
        static var ok: String { tr("common.ok", "OK") }
        static var cancel: String { tr("common.cancel", "Cancel") }
        static var add: String { tr("common.add", "Add") }
        static var copy: String { tr("common.copy", "Copy") }
        static var copied: String { tr("common.copied", "Copied") }
        static var close: String { tr("common.close", "Close") }
        static var done: String { tr("common.done", "Done") }
        static var install: String { tr("common.install", "Install") }
        static var tryAgain: String { tr("common.tryAgain", "Try Again") }
        static var openAll: String { tr("common.openAll", "Open All") }
        static var hideAll: String { tr("common.hideAll", "Hide All") }
        static var closeAll: String { tr("common.closeAll", "Close All") }
        static var forceQuit: String { tr("common.forceQuit", "Force Quit") }
        static var addApps: String { tr("common.addApps", "Add Apps…") }
        static var addWebsite: String { tr("common.addWebsite", "Add Website…") }
        static var showInFinder: String { tr("common.showInFinder", "Show in Finder") }
        static var removeFromGroup: String { tr("common.removeFromGroup", "Remove from Group") }
        static var moveTo: String { tr("common.moveTo", "Move to") }
        static var defaultOption: String { tr("common.default", "Default") }
        static var auto: String { tr("common.auto", "Auto") }
        static var changelog: String { tr("common.changelog", "Changelog") }
        static var links: String { tr("common.links", "Links") }
        static var openReleasesPage: String { tr("common.openReleasesPage", "Open Releases Page") }
        static var openPrivacySettings: String { tr("common.openPrivacySettings", "Open Privacy & Security…") }
        static var checkForUpdates: String { tr("common.checkForUpdates", "Check for Updates…") }
        static var settings: String { tr("common.settings", "Settings…") }
        static var noLaunchesYet: String { tr("common.noLaunchesYet", "No launches tracked yet") }
        static var noAppsInGroup: String { tr("common.noAppsInGroup", "No apps in this group yet") }
        /// "About Cybokron Dock Groups".
        static func about(_ appName: String) -> String { tr("common.about", "About %@", appName) }
        static func hideApp(_ appName: String) -> String { tr("common.hideApp", "Hide %@", appName) }
        static func quitApp(_ appName: String) -> String { tr("common.quitApp", "Quit %@", appName) }
        /// A version as shown next to its number: "v0.5.6".
        static func version(_ version: String) -> String { tr("common.versionShort", "v%@", version) }
        static func installingVersion(_ version: String) -> String {
            tr("common.update.installing", "Installing version %@…", version)
        }
        static func installedRestarting(_ version: String) -> String {
            tr("common.update.restarting", "Installed version %@ — restarting…", version)
        }

        static func appCount(_ count: Int) -> String {
            count == 1 ? tr("common.appCount.one", "1 app") : tr("common.appCount.other", "%ld apps", count)
        }

        static func groupCount(_ count: Int) -> String {
            count == 1 ? tr("common.groupCount.one", "1 group") : tr("common.groupCount.other", "%ld groups", count)
        }
    }

    // MARK: - Menus

    enum MenuBar {
        static var groupsHeader: String { tr("menuBar.groupsHeader", "Groups") }
        static var noGroups: String { tr("menuBar.noGroups", "No groups yet") }
        static var manageGroups: String { tr("menuBar.manageGroups", "Manage Groups…") }
        static var noLaunchesTooltip: String {
            tr("menuBar.mostUsed.empty.tooltip", "Open apps as usual; the ones you open most will appear here.")
        }
        static var showMostUsed: String { tr("menuBar.mostUsed.show", "Show Most Used") }
        static var showMostUsedTooltip: String { tr("menuBar.mostUsed.show.tooltip", "Show your most opened apps in a popup.") }

        static func checkForUpdatesTooltip(_ appName: String) -> String {
            tr("menuBar.checkForUpdates.tooltip", "Look for a newer version of %@ on GitHub.", appName)
        }

        static func mostUsedAppTooltip(_ appName: String, launchCount: Int) -> String {
            launchCount == 1
                ? tr("menuBar.mostUsed.app.tooltip.one", "Open %@. Opened once.", appName)
                : tr("menuBar.mostUsed.app.tooltip.other", "Open %1$@. Opened %2$ld times.", appName, launchCount)
        }

        static func groupTooltip(_ groupName: String) -> String {
            tr(
                "menuBar.group.tooltip",
                "Show the apps in “%@”. Hold ⌥ to open them all at once, or ⇧⌥ to hide the running ones.",
                groupName
            )
        }

        static func groupTooltip(_ groupName: String, shortcut: String) -> String {
            tr(
                "menuBar.group.tooltip.shortcut",
                "Show the apps in “%1$@”. Hold ⌥ to open them all at once, or ⇧⌥ to hide the running ones. Shortcut: %2$@.",
                groupName, shortcut
            )
        }

        static func openAllIn(_ groupName: String) -> String { tr("menuBar.group.openAll", "Open All in “%@”", groupName) }

        static func openAllTooltip(_ groupName: String, appCount: Int) -> String {
            appCount == 1
                ? tr("menuBar.group.openAll.tooltip.one", "Open the app in “%@”", groupName)
                : tr("menuBar.group.openAll.tooltip.other", "Open all %1$ld apps in “%2$@”", appCount, groupName)
        }

        static func noAppsTooltip(_ groupName: String) -> String { tr("menuBar.group.noApps", "“%@” has no apps yet.", groupName) }
        static func hideAllIn(_ groupName: String) -> String { tr("menuBar.group.hideAll", "Hide All in “%@”", groupName) }

        static func hideAllTooltip(_ groupName: String) -> String {
            tr("menuBar.group.hideAll.tooltip", "Hide the running apps in “%@”. Apps that aren't running stay closed.", groupName)
        }
    }

    /// The main menu (only its key equivalents are used, while a window of the app is active).
    enum MainMenu {
        static var edit: String { tr("mainMenu.edit", "Edit") }
        static var undo: String { tr("mainMenu.undo", "Undo") }
        static var redo: String { tr("mainMenu.redo", "Redo") }
        static var cut: String { tr("mainMenu.cut", "Cut") }
        static var paste: String { tr("mainMenu.paste", "Paste") }
        static var selectAll: String { tr("mainMenu.selectAll", "Select All") }
        static var window: String { tr("mainMenu.window", "Window") }
        static var minimize: String { tr("mainMenu.minimize", "Minimize") }
    }

    // MARK: - Popup

    enum Popup {
        static var openAllHelpGroup: String {
            tr("popup.openAll.help.group", "Open every app in this group; running apps come to the front.")
        }
        static var openAllHelpMostUsed: String {
            tr("popup.openAll.help.mostUsed", "Open every app in this list; running apps come to the front.")
        }
        static var hideAllHelpGroup: String {
            tr("popup.hideAll.help.group", "Hide this group's running apps; apps that aren't running stay closed.")
        }
        static var hideAllHelpMostUsed: String {
            tr("popup.hideAll.help.mostUsed", "Hide this list's running apps; apps that aren't running stay closed.")
        }
        static var closeAllHelpGroup: String {
            tr("popup.closeAll.help.group", "Quit this group's running apps. ⌘-click to force quit without saving.")
        }
        static var closeAllHelpMostUsed: String {
            tr("popup.closeAll.help.mostUsed", "Quit this list's running apps. ⌘-click to force quit without saving.")
        }

        static func websiteCount(_ count: Int) -> String {
            count == 1 ? tr("popup.summary.websites.one", "1 website") : tr("popup.summary.websites.other", "%ld websites", count)
        }

        static func runningCount(_ count: Int) -> String { tr("popup.summary.running", "%ld running", count) }
        static var byLaunches: String { tr("popup.summary.byLaunches", "by launches") }

        static func noMatch(_ query: String) -> String { tr("popup.filter.noMatch", "No apps match “%@”", query) }
        static var noMatchHint: String { tr("popup.filter.noMatch.hint", "Press Delete or Esc to clear the filter.") }
        static var mostUsedEmptyHint: String { tr("popup.empty.mostUsed.hint", "Open apps as usual to start building your history.") }

        static var footerSortAZ: String { tr("popup.footer.sortAZ", "A→Z") }
        static var footerSortAZHelp: String { tr("popup.footer.sortAZ.help", "Sort the apps in this group by name, A to Z.") }
        static var footerSortAZAccessibility: String { tr("popup.footer.sortAZ.accessibility", "Sort A to Z") }

        static func footerFilter(_ query: String) -> String {
            tr("popup.footer.filter.matches", "Filter: “%@”  ·  ↩ opens the selected app  ·  esc clears", query)
        }

        static func footerFilterNoMatch(_ query: String) -> String {
            tr("popup.footer.filter.noMatch", "Filter: “%@”  ·  no match  ·  ⌫ or esc clears", query)
        }

        static var footerHintMostUsed: String {
            tr("popup.footer.hint.mostUsed", "Ranked by how often you open them  ·  ⌘-click Close All to force quit")
        }
        static var footerHintGroup: String {
            tr("popup.footer.hint.group", "Close All:  ⌥-click quits normally  ·  ⌘-click force quits")
        }

        static func footerReleaseToRemove(_ appName: String) -> String {
            tr("popup.footer.drag.remove", "Release to remove %@ from this group", appName)
        }

        static func footerDropFree(_ appName: String) -> String {
            tr("popup.footer.drag.free", "Drop %@ on any cell; on another app to swap  ·  drag out to remove", appName)
        }

        static func footerDropOrdered(_ appName: String) -> String {
            tr("popup.footer.drag.ordered", "Drop to place %@  ·  drag out of the popup to remove it", appName)
        }

        static func websiteAccessibility(_ name: String) -> String { tr("popup.cell.accessibility.website", "Website %@", name) }
        static var websiteHint: String { tr("popup.cell.hint.website", "Opens the website in your browser") }
        static var runningAppHint: String { tr("popup.cell.hint.running", "Brings the app to the front") }
        static var appHint: String { tr("popup.cell.hint.open", "Opens the app") }

        /// The first sentence of an item's tooltip: what clicking it does.
        static func helpOpenWebsite(_ address: String) -> String {
            tr("popup.cell.help.openWebsite", "Open %@ in your browser.", address)
        }
        static func helpBringToFront(_ appName: String) -> String {
            tr("popup.cell.help.bringToFront", "Bring %@ to the front.", appName)
        }
        static func helpOpenApp(_ appName: String) -> String { tr("popup.cell.help.openApp", "Open %@.", appName) }
        static func helpMissing(_ appName: String) -> String { tr("popup.cell.help.missing", "%@ isn't on this Mac.", appName) }

        /// The second sentence of an item's tooltip: how it can be dragged.
        static var helpDragFreeItem: String {
            tr(
                "popup.cell.help.drag.freeItem",
                "Drag to any cell or onto another item to swap them, or out of the popup to remove it from the group."
            )
        }
        static var helpDragFreeApp: String {
            tr(
                "popup.cell.help.drag.freeApp",
                "Drag to any cell or onto another app to swap them, or out of the popup to remove it from the group."
            )
        }
        static var helpDragOrdered: String {
            tr("popup.cell.help.drag.ordered", "Drag to reorder, or out of the popup to remove it from the group.")
        }
        static var helpDragOutMissing: String {
            tr("popup.cell.help.drag.missing", "Drag it out of the popup to remove it from the group.")
        }

        static var menuOpen: String { tr("popup.menu.open", "Open") }
        static var menuCopyURL: String { tr("popup.menu.copyURL", "Copy URL") }
        static var moveEarlier: String { tr("popup.accessibility.moveEarlier", "Move Earlier") }
        static var moveLater: String { tr("popup.accessibility.moveLater", "Move Later") }
    }

    // MARK: - Group window

    enum GroupWindow {
        static var noGroupsTitle: String { tr("groupWindow.empty.noGroups", "No Groups Yet") }
        static var noSelectionTitle: String { tr("groupWindow.empty.noSelection", "No Group Selected") }
        static var noGroupsDescription: String {
            tr("groupWindow.empty.noGroups.description", "Add a group to collect apps you use together.")
        }
        static var noSelectionDescription: String { tr("groupWindow.empty.noSelection.description", "Select a group to edit it.") }
        static var addGroup: String { tr("groupWindow.addGroup", "Add a Group") }
        static var renameTitle: String { tr("groupWindow.rename.title", "Rename Group") }
        static var rename: String { tr("groupWindow.rename.confirm", "Rename") }
        static var renameMessage: String { tr("groupWindow.rename.message", "Enter a new name for the group.") }
        static func deleteTitle(_ groupName: String) -> String { tr("groupWindow.delete.title", "Delete “%@”?", groupName) }
        static var deleteGroup: String { tr("groupWindow.delete.confirm", "Delete Group") }
        static var deleteMessageStandalone: String {
            tr(
                "groupWindow.delete.message.standalone",
                "This removes the group and its app list, and its own Dock icon. The apps themselves aren't affected."
            )
        }
        static var deleteMessage: String {
            tr("groupWindow.delete.message", "This removes the group and its app list. The apps themselves aren't affected.")
        }

        // Sidebar
        static var renameMenu: String { tr("groupWindow.sidebar.rename", "Rename…") }
        static var deleteMenu: String { tr("groupWindow.sidebar.delete", "Delete…") }
        static var addGroupHelp: String { tr("groupWindow.sidebar.add.help", "Add a group") }
        static var deleteGroupHelp: String { tr("groupWindow.sidebar.delete.help", "Delete the selected group") }

        // Group
        static var addAppsProblemTitle: String { tr("groupWindow.addApps.problem.title", "Some apps couldn't be added") }
        static var groupSection: String { tr("groupWindow.section.group", "Group") }
        static var name: String { tr("groupWindow.name", "Name") }
        static var emoji: String { tr("groupWindow.emoji", "Emoji") }
        static var chooseEmoji: String { tr("groupWindow.emoji.choose", "Choose…") }

        // Apps
        static var appsSection: String { tr("groupWindow.section.apps", "Apps") }
        /// Names the Add Apps… and Add Website… buttons.
        static func noApps(addApps: String, addWebsite: String) -> String {
            tr(
                "groupWindow.apps.empty",
                "No apps yet. Use “%1$@” to choose apps for this group, or “%2$@” for a web link.",
                addApps, addWebsite
            )
        }
        static var addWebsiteHelp: String {
            tr("groupWindow.addWebsite.help", "Add a web link to this group. It opens in your default browser.")
        }
        static var sortAZ: String { tr("groupWindow.sortAZ", "Sort A→Z") }
        static var sortAZHelp: String {
            tr("groupWindow.sortAZ.help", "Sort the apps in this group by name, A to Z. Drag them to reorder by hand.")
        }
        static var showPopup: String { tr("groupWindow.showPopup", "Show Popup") }
        static var showPopupHelp: String { tr("groupWindow.showPopup.help", "Show this group's popup over the Dock.") }
        static var hideAllHelp: String {
            tr("groupWindow.hideAll.help", "Hide this group's running apps. Apps that aren't running stay closed.")
        }
        /// Names the Move to menu.
        static func moveHint(moveTo: String) -> String {
            tr(
                "groupWindow.apps.moveHint",
                "To move an app to another group, drag it onto that group in the sidebar, or use %@ in its context menu.",
                moveTo
            )
        }
        static func appNotFound(_ identity: String) -> String { tr("groupWindow.app.notFound", "Not found on this Mac · %@", identity) }
        static func removeWebsiteHelp(_ name: String) -> String {
            tr("groupWindow.app.remove.website", "Remove %@ from this group.", name)
        }
        static func removeAppHelp(_ name: String) -> String {
            tr("groupWindow.app.remove", "Remove %@ from this group. The app itself isn't affected.", name)
        }

        // Dock tile
        static var dockTileSection: String { tr("groupWindow.section.dockTile", "Dock Tile") }
        static var preview: String { tr("groupWindow.tile.preview", "Preview") }
        static var shows: String { tr("groupWindow.tile.shows", "Shows") }
        static var appIconGrid: String { tr("groupWindow.tile.kind.grid", "App Icon Grid") }
        static var background: String { tr("groupWindow.tile.background", "Background") }
        static var backgroundColor: String { tr("groupWindow.tile.backgroundColor", "Background Color") }
        static var keepPinned: String { tr("groupWindow.tile.pinned", "Keep the tile pinned in the Dock") }
        static func tilePreviewAccessibility(points: Int) -> String {
            tr("groupWindow.tile.preview.accessibility", "Tile preview, %ld points", points)
        }

        // Standalone
        static var standaloneSection: String { tr("groupWindow.section.standalone", "Standalone") }
        static var standaloneToggle: String { tr("groupWindow.standalone.toggle", "Standalone Dock icon") }
        static var standaloneHelp: String {
            tr("groupWindow.standalone.help", "Give this group its own app, with its own icon in the Dock.")
        }
        static var settingUpDockIcon: String { tr("groupWindow.standalone.settingUp", "Setting up the Dock icon…") }
        static var removingDockIcon: String { tr("groupWindow.standalone.removing", "Removing the Dock icon…") }
        static var groupApp: String { tr("groupWindow.standalone.groupApp", "Group App") }
        static var updateDockIcon: String { tr("groupWindow.standalone.updateDockIcon", "Update Dock Icon") }
        static var updateDockIconHelp: String {
            tr(
                "groupWindow.standalone.updateDockIcon.help",
                "Restart the Dock with a fresh icon cache, so the tile shows the group's current icon."
            )
        }
        static var staleDockIcon: String { tr("groupWindow.standalone.staleIcon", "The Dock still shows the previous icon.") }
        static func standaloneFooter(_ appName: String) -> String {
            tr(
                "groupWindow.standalone.footer",
                "Gives the group its own small app, with the tile above as its icon, at the end of the Dock. Clicking it shows the group's popup (⌥-click opens all of its apps), even while %@ isn't running; right-clicking it lists the group's apps (Settings → Popup). Turning this off, deleting the group or dragging the icon out of the Dock removes that app. Adding or removing the icon restarts the Dock for a moment.",
                appName
            )
        }

        // Popup overrides
        static var popupSection: String { tr("groupWindow.section.popup", "Popup") }
        static var columns: String { tr("groupWindow.popup.columns", "Columns") }
        static var maximumRows: String { tr("groupWindow.popup.maxRows", "Maximum Rows") }
        static var appNames: String { tr("groupWindow.popup.appNames", "App Names") }
        static var show: String { tr("groupWindow.popup.show", "Show") }
        static var hide: String { tr("groupWindow.popup.hide", "Hide") }
        static var position: String { tr("groupWindow.popup.position", "Position") }
        /// Names the Default option.
        static func popupFooter(defaultOption: String) -> String {
            tr("groupWindow.popup.footer", "“%@” follows the app-wide popup settings.", defaultOption)
        }
    }

    /// Choices shown by name in pickers.
    enum Choices {
        static var tileSolid: String { tr("choice.tileBackground.solid", "Solid") }
        static var tileGradient: String { tr("choice.tileBackground.gradient", "Gradient") }
        static var tileGlass: String { tr("choice.tileBackground.glass", "Glass") }
        static var anchorDockCenter: String { tr("choice.popupAnchor.dockCenter", "Centered Over the Dock") }
        static var anchorDockIcon: String { tr("choice.popupAnchor.dockIcon", "Above the Clicked Icon") }
        static var themeDark: String { tr("choice.theme.dark", "Dark") }
        static var themeLight: String { tr("choice.theme.light", "Light") }
        static var themeSystem: String { tr("choice.theme.system", "Match System") }
    }

    // MARK: - Adding apps and websites

    enum AddWebsite {
        static var windowTitle: String { tr("addWebsite.windowTitle", "Add Website") }
        static func title(_ groupName: String) -> String { tr("addWebsite.title", "Add Website to “%@”", groupName) }
        static var address: String { tr("addWebsite.address", "Address:") }
        static var addressAccessibility: String { tr("addWebsite.address.accessibility", "Website address") }
        static var name: String { tr("addWebsite.name", "Name:") }
        static var nameAccessibility: String { tr("addWebsite.name.accessibility", "Website name, optional") }
        static var namePlaceholder: String { tr("addWebsite.name.placeholder", "Optional") }
        static var hint: String {
            tr("addWebsite.hint", "Opens in your default browser. Leave the name empty to use the site's address.")
        }
        static func alreadyInGroup(_ address: String) -> String {
            tr("addWebsite.duplicate", "“%@” is already in this group.", address)
        }
    }

    enum AppPicker {
        static var title: String { tr("appPicker.title", "Add Apps to Group") }
        static func message(_ groupName: String) -> String { tr("appPicker.message", "Choose the apps to add to “%@”.", groupName) }
    }

    // MARK: - Problems

    enum Problems {
        static func noneOpened(_ groupName: String) -> String {
            tr("problems.launch.allFailed", "The apps in “%@” couldn't be opened.", groupName)
        }
        static func someNotOpened(_ groupName: String) -> String {
            tr("problems.launch.someFailed", "Some apps in “%@” couldn't be opened.", groupName)
        }
        /// One app that couldn't be opened, with why.
        static func launchItem(_ appName: String, reason: String) -> String {
            tr("problems.launch.item", "• %1$@: %2$@", appName, reason)
        }
        static var notFound: String { tr("problems.launch.notFound", "not found on this Mac.") }
        static var opened: String { tr("problems.launch.opened", "opened.") }
        static func notForceQuit(_ groupName: String) -> String {
            tr("problems.quit.force", "Some apps in “%@” couldn't be force quit.", groupName)
        }
        static func notAskedToQuit(_ groupName: String) -> String {
            tr("problems.quit.graceful", "Some apps in “%@” couldn't be asked to quit.", groupName)
        }
        static func notHidden(_ groupName: String) -> String {
            tr("problems.hide", "Some apps in “%@” couldn't be hidden.", groupName)
        }
        static func noDockIcon(_ groupName: String) -> String {
            tr("problems.standalone.failed", "“%@” couldn't get its own Dock icon.", groupName)
        }
    }

    /// A standalone group's app.
    enum Agent {
        static var damagedTitle: String { tr("agent.damaged.title", "This group's app can't open its group.") }
        static func damagedMessage(_ reason: String, appName: String) -> String {
            tr(
                "agent.damaged.message",
                "%1$@\n\nIn %2$@, turn Standalone off and on again for the group to rebuild its app.",
                reason, appName
            )
        }
        static var groupMismatch: String { tr("agent.error.groupMismatch", "The app's settings belong to another group.") }
    }

    /// Privacy & Security → Accessibility.
    enum Accessibility {
        static func staleEntryHint(_ appName: String) -> String {
            tr(
                "accessibility.staleEntryHint",
                "Already switched on? After an update the entry may belong to the previous version: select %@, remove it with −, then add the app again with +.",
                appName
            )
        }
    }

    // MARK: - Settings

    /// The app's language, at the top of Settings → Popup.
    enum General {
        static var language: String { tr("general.language", "Language") }
        /// The "System" choice, with the language the system settings give the app: "System (English)".
        static func languageSystem(_ languageName: String) -> String {
            tr("general.language.system", "System (%1$@)", languageName)
        }
        static var restartNote: String {
            tr("general.language.restartNote", "The new language takes effect after the app restarts.")
        }
        static var restartNow: String { tr("general.language.restartNow", "Restart Now") }
    }

    enum Settings {
        static var windowTitle: String { tr("settings.window.title", "Settings") }
        static var popupTab: String { tr("settings.tab.popup", "Popup") }
        static var shortcutsTab: String { tr("settings.tab.shortcuts", "Shortcuts & Siri") }
        static var updatesTab: String { tr("settings.tab.updates", "Updates") }
        static var backupTab: String { tr("settings.tab.backup", "Backup") }

        enum Popup {
            static var theme: String { tr("settings.popup.theme", "Theme") }
            static var frostedGlass: String { tr("settings.popup.frostedGlass", "Frosted glass background") }
            static var appearanceHeader: String { tr("settings.popup.appearance.header", "Popup Appearance") }
            static var appearanceFooter: String {
                tr("settings.popup.appearance.footer", "The theme applies to the popup only; this window follows your macOS appearance.")
            }
            static var columns: String { tr("settings.popup.columns", "Columns") }
            static var columnsDetail: String {
                tr(
                    "settings.popup.columns.detail",
                    "Auto keeps the standard popup width; a number makes the popup only as wide as the group needs."
                )
            }
            static var maximumRows: String { tr("settings.popup.maxRows", "Maximum rows") }
            static var maximumRowsDetail: String { tr("settings.popup.maxRows.detail", "Limits the popup's height; larger groups scroll.") }
            static var showAppNames: String { tr("settings.popup.showNames", "Show app names") }
            static var position: String { tr("settings.popup.position", "Position") }
            static var positionDetail: String {
                tr(
                    "settings.popup.position.detail",
                    "Above the clicked icon opens a popup over its group's Dock icon, or under the menu bar icon when chosen from its menu. Popups opened with a shortcut, a link or Siri stay centered over the Dock."
                )
            }
            static var layoutHeader: String { tr("settings.popup.layout.header", "Popup Layout") }
            static var layoutFooter: String {
                tr(
                    "settings.popup.layout.footer",
                    "These are the defaults for every group. Each group can override them under Manage Groups."
                )
            }
            static var freeLayout: String { tr("settings.popup.freeLayout", "Free layout") }
            static var freeLayoutDetail: String {
                tr(
                    "settings.popup.freeLayout.detail",
                    "Apps stay in the cell you drag them to, and the others don't move; dropping an app on another swaps the two."
                )
            }
            static var arrangingHeader: String { tr("settings.popup.arranging.header", "Arranging Apps") }
            static var arrangingFooter: String {
                tr(
                    "settings.popup.arranging.footer",
                    "Off, a group's apps fill the popup in order and make room when you move one. A→Z in the popup sorts a group by name either way."
                )
            }
            static var restoreWindows: String {
                tr("settings.popup.restoreWindows", "Restore windows when reopening an app that is running")
            }
            static var restoreWindowsDetail: String {
                tr(
                    "settings.popup.restoreWindows.detail",
                    "Clicking a running app brings back its hidden and minimized windows, as clicking it in the Dock does. Off, the app only comes to the front."
                )
            }
            static var runningAppsHeader: String { tr("settings.popup.runningApps.header", "Running Apps") }
            static var dockMenus: String { tr("settings.popup.dockMenus", "Menu on group Dock icons") }
            static var dockMenusDetail: String {
                tr(
                    "settings.popup.dockMenus.detail",
                    "Right-click a standalone group's Dock icon for its apps, Open All, Hide All and Close All, once the icon was clicked. Its app then shows as running in the Dock and in ⌘-Tab."
                )
            }
            static var standaloneIconsHeader: String { tr("settings.popup.standaloneIcons.header", "Standalone Dock Icons") }
            static var accessGranted: String {
                tr("settings.popup.ax.granted", "Accessibility access granted: minimized windows come back too")
            }
            static var accessRequired: String {
                tr("settings.popup.ax.required", "Restoring minimized windows requires Accessibility access")
            }
            static func accessDetail(_ appName: String) -> String {
                tr(
                    "settings.popup.ax.detail",
                    "Allow %@ under Privacy & Security → Accessibility. Until then, hidden apps still come back, and apps are asked to reopen as from the Dock. Standalone group icons need the access for their own apps.",
                    appName
                )
            }
        }

        enum Shortcuts {
            static var enable: String { tr("settings.shortcuts.enable", "Open group popups with keyboard shortcuts") }
            static var modifierKeys: String { tr("settings.shortcuts.modifiers", "Modifier keys") }
            static var shortcutKeys: String { tr("settings.shortcuts.keys", "Shortcut keys") }
            static var shortcutKeysDetail: String {
                tr(
                    "settings.shortcuts.keys.detail",
                    "Hold these keys and press 1 for the first group, 2 for the second, and so on. Press it again to close the popup."
                )
            }
            static var keyboardHeader: String { tr("settings.shortcuts.header", "Keyboard Shortcuts") }
            static var worksEverywhere: String { tr("settings.shortcuts.ax.granted", "Works in every app") }
            static var needsAccess: String { tr("settings.shortcuts.ax.needed", "Needs Accessibility access") }
            static func accessDetail(_ appName: String) -> String {
                tr(
                    "settings.shortcuts.ax.detail",
                    "To notice the shortcuts while you work in other apps, allow %@ under Privacy & Security → Accessibility. Until then they work only while its popup or a window of it is active.",
                    appName
                )
            }
            static var noGroups: String { tr("settings.shortcuts.noGroups", "No groups yet.") }
            static var assignedHeader: String { tr("settings.shortcuts.assigned.header", "Assigned Groups") }
            static var assignedFooterLimit: String {
                tr(
                    "settings.shortcuts.assigned.footer.limit",
                    "Only the first nine groups have shortcuts. Drag groups in Manage Groups to change the order."
                )
            }
            static var assignedFooter: String {
                tr("settings.shortcuts.assigned.footer", "Shortcuts follow the order of the groups in Manage Groups.")
            }
            static var group: String { tr("settings.shortcuts.siri.group", "Group") }
            /// A Siri phrase in quotation marks.
            static func quotedPhrase(_ phrase: String) -> String { tr("settings.shortcuts.siri.quoted", "“%@”", phrase) }
            static var siriNoGroups: String { tr("settings.shortcuts.siri.noGroups", "Add a group to see what to ask Siri for it.") }
            static var openShortcuts: String { tr("settings.shortcuts.openShortcuts", "Open Shortcuts") }
            static var shortcutsApp: String { tr("settings.shortcuts.shortcutsApp", "Shortcuts app") }
            static var shortcutsAppDetail: String {
                tr(
                    "settings.shortcuts.shortcutsApp.detail",
                    "Launch Group, Quit Group and Show Group are actions there and in Spotlight: add them to your own shortcuts, with your own trigger."
                )
            }
            static var siriHeader: String { tr("settings.shortcuts.siri.header", "Siri and Shortcuts") }
            static var siriFooter: String {
                tr(
                    "settings.shortcuts.siri.footer",
                    "Ask Siri with these words, by voice or by typing. They use the group's current name; shortcuts you build keep working after a rename."
                )
            }
            static var linksNoGroups: String { tr("settings.shortcuts.links.noGroups", "Add a group to see its links.") }
            /// Markdown: `open` shows as code.
            static var linksFooter: String {
                tr(
                    "settings.shortcuts.links.footer",
                    "Open a link from a script or another app, e.g. with `open` in Terminal. A group is named by its name (case, accents and punctuation don't matter) or, when the name is ambiguous, its ID. Add ?mode=force to a quit link to force quit."
                )
            }
            static func copyHelp(_ text: String) -> String { tr("settings.shortcuts.copy.help", "Copy “%@” to the clipboard.", text) }
        }

        enum MostUsed {
            static var show: String { tr("settings.mostUsed.show", "Show Most Used in the menu bar") }
            static var appsShown: String { tr("settings.mostUsed.appsShown", "Apps shown") }
            static var appsShownDetail: String {
                tr("settings.mostUsed.appsShown.detail", "The most opened apps, in the menu and in the Most Used popup.")
            }
            static var sessionLength: String { tr("settings.mostUsed.sessionLength", "Session length") }
            static var openedTogether: String { tr("settings.mostUsed.together", "Opened together within") }
            static var openedTogetherDetail: String {
                tr(
                    "settings.mostUsed.together.detail",
                    "Apps opened within this time of each other count as used together, which moves them up a little."
                )
            }
            static var footer: String {
                tr(
                    "settings.mostUsed.footer",
                    "Apps are ranked by how often you open them, from the Dock, Finder, Spotlight or a group. Launches are counted even while the list is hidden."
                )
            }
            static var recorded: String { tr("settings.mostUsed.recorded", "Recorded") }
            static var clearHistoryEllipsis: String { tr("settings.mostUsed.clear", "Clear History…") }
            static var history: String { tr("settings.mostUsed.history", "History") }
            static var historyDetail: String {
                tr(
                    "settings.mostUsed.history.detail",
                    "Stored on this Mac only, in usage-stats.json and usage-cooccurrence.json in Application Support."
                )
            }
            static var usageHistoryHeader: String { tr("settings.mostUsed.usageHistory.header", "Usage History") }
            static var clearConfirmTitle: String { tr("settings.mostUsed.clear.confirm.title", "Clear the usage history?") }
            static var clearHistory: String { tr("settings.mostUsed.clear.confirm.button", "Clear History") }
            static var clearConfirmMessage: String {
                tr("settings.mostUsed.clear.confirm.message", "The Most Used list starts over. Your groups and apps aren't affected.")
            }
            static var noLaunches: String { tr("settings.mostUsed.summary.none", "No launches yet") }
            static func launchCount(_ count: Int) -> String {
                count == 1
                    ? tr("settings.mostUsed.summary.launches.one", "1 launch")
                    : tr("settings.mostUsed.summary.launches.other", "%ld launches", count)
            }
            /// "12 launches of 3 apps".
            static func summary(launches: String, apps: String) -> String {
                tr("settings.mostUsed.summary", "%1$@ of %2$@", launches, apps)
            }
        }

        enum Updates {
            static var automatic: String { tr("settings.updates.automatic", "Automatically check for updates") }
            static var currentVersion: String { tr("settings.updates.currentVersion", "Current version") }
            static var lastChecked: String { tr("settings.updates.lastChecked", "Last checked") }
            static var checkNow: String { tr("settings.updates.checkNow", "Check Now") }
            static var otherVersions: String { tr("settings.updates.otherVersions", "Other Versions…") }
            static var footer: String {
                tr(
                    "settings.updates.footer",
                    "Checks the project's GitHub releases at launch and every 6 hours; only the app's version number is sent along. A new version is installed only after you choose Download and Install. Other Versions… installs any published release, older or newer; going back skips the newer ones in automatic checks."
                )
            }
            static var viewChangelog: String { tr("settings.updates.viewChangelog", "View Changelog") }
            static var latestPath: String {
                tr("settings.updates.latestPath", "Back on the latest path: every newer release is offered")
            }
            /// The versions, separated by commas.
            static func skippedVersions(_ versions: String) -> String {
                tr("settings.updates.skipped", "Skipped newer versions: %@", versions)
            }
            static var clear: String { tr("settings.updates.clear", "Clear") }
            static var clearHelp: String { tr("settings.updates.clear.help", "Let automatic checks offer these versions again") }
            static var never: String { tr("settings.updates.never", "Never") }
            static var notChecked: String { tr("settings.updates.status.idle", "Not checked since the app started") }
            static var checking: String { tr("settings.updates.status.checking", "Checking…") }
            static func upToDate(_ version: String) -> String {
                tr("settings.updates.status.upToDate", "You're up to date (v%@)", version)
            }
            static func available(_ version: String) -> String {
                tr("settings.updates.status.available", "Version %@ is available", version)
            }
            static var showUpdate: String { tr("settings.updates.showUpdate", "Show Update…") }
        }

        enum OtherVersions {
            static var title: String { tr("settings.otherVersions.title", "Other Versions") }
            static func intro(_ appName: String) -> String {
                tr(
                    "settings.otherVersions.intro",
                    "Install any published release of %@, older or newer. The app quits and reopens as the version you pick.",
                    appName
                )
            }
            static var releasesOnGitHub: String { tr("settings.otherVersions.releasesLink", "Open Releases Page on GitHub") }
            static var loading: String { tr("settings.otherVersions.loading", "Loading releases from GitHub…") }
            static var none: String { tr("settings.otherVersions.none", "GitHub lists no published releases.") }
            static var current: String { tr("settings.otherVersions.current", "Current") }
            static var noDownload: String { tr("settings.otherVersions.noDownload", "No download") }
            static func installHelp(_ version: String) -> String {
                tr("settings.otherVersions.install.help", "Install version %@", version)
            }
            static var noDiskImage: String {
                tr("settings.otherVersions.install.noImage", "This release has no disk image to install from.")
            }
            static func confirmTitle(_ version: String) -> String {
                tr("settings.otherVersions.confirm.title", "Install version %@?", version)
            }
            static func confirmQuits(_ appName: String, version: String) -> String {
                tr("settings.otherVersions.confirm.quits", "%1$@ quits and reopens as version %2$@.", appName, version)
            }
            static func confirmCantUpdate(_ version: String) -> String {
                tr(
                    "settings.otherVersions.confirm.cantUpdate",
                    "Version %@ can't update itself: to come back, download a newer version from the releases page.",
                    version
                )
            }
            /// The versions, separated by commas.
            static func confirmSkips(_ versions: String) -> String {
                tr(
                    "settings.otherVersions.confirm.skips",
                    "Automatic checks then skip the newer versions (%@); Check for Updates… still offers them.",
                    versions
                )
            }
            static var confirmOlder: String {
                tr(
                    "settings.otherVersions.confirm.older",
                    "An older version may not know about features added since; consider exporting a backup first (Settings → Backup)."
                )
            }
            static var confirmUpgrade: String {
                tr(
                    "settings.otherVersions.confirm.upgrade",
                    "Skipped versions are cleared, so automatic checks offer every newer release again."
                )
            }
        }

        enum Backup {
            static var exportButton: String { tr("settings.backup.export.button", "Export Settings…") }
            static var export: String { tr("settings.backup.export", "Export") }
            static var exportDetail: String { tr("settings.backup.export.detail", "Saves your groups and settings to a .dockgroups file.") }
            static var importButton: String { tr("settings.backup.import.button", "Import Settings…") }
            static var importLabel: String { tr("settings.backup.import", "Import") }
            static var importDetail: String {
                tr(
                    "settings.backup.import.detail",
                    "Replaces your groups and settings with the ones in a backup file, or merges the backup's new groups into yours."
                )
            }
            static var footer: String {
                tr(
                    "settings.backup.footer",
                    "The backup holds your groups, their apps and every setting. Most Used launch counts aren't included. The file stays wherever you save it."
                )
            }
            static func exported(_ fileName: String) -> String { tr("settings.backup.status.exported", "Exported to “%@”", fileName) }
            /// "Restored 2 groups with 7 apps".
            static func restored(groups: String, apps: String) -> String {
                tr("settings.backup.status.restored", "Restored %1$@ with %2$@", groups, apps)
            }
            static func merged(groups: String) -> String {
                tr("settings.backup.status.merged", "Merged %@ from the backup", groups)
            }
            static func merged(groups: String, alreadyHere: Int) -> String {
                tr("settings.backup.status.mergedSkipped", "Merged %1$@ from the backup; %2$ld already here", groups, alreadyHere)
            }

            // Panels and alerts
            static var exportPanelTitle: String { tr("settings.backup.exportPanel.title", "Export Settings") }
            static var exportPanelMessage: String {
                tr("settings.backup.exportPanel.message", "Save your groups and settings to a backup file.")
            }
            static var exportFailed: String { tr("settings.backup.exportFailed", "The settings couldn't be exported") }
            static var importPanelTitle: String { tr("settings.backup.importPanel.title", "Import Settings") }
            static func importPanelMessage(_ appName: String) -> String {
                tr("settings.backup.importPanel.message", "Choose a %@ backup to restore.", appName)
            }
            static var readFailed: String { tr("settings.backup.readFailed", "The file couldn't be read") }
            static var confirmTitle: String {
                tr("settings.backup.confirm.title", "Import the groups and settings in this backup?")
            }
            static var replaceAll: String { tr("settings.backup.confirm.replaceAll", "Replace All") }
            static var merge: String { tr("settings.backup.confirm.merge", "Merge") }
            static var restoreFailed: String { tr("settings.backup.restoreFailed", "The backup couldn't be restored") }
            static func restoreFailedDetail(_ reason: String) -> String {
                tr("settings.backup.restoreFailed.kept", "%@ Your current groups and settings were kept.", reason)
            }
            static var mergeFailed: String { tr("settings.backup.mergeFailed", "The backup couldn't be merged") }
            static func mergeFailedDetail(_ reason: String) -> String {
                tr("settings.backup.mergeFailed.kept", "%@ Your current groups were kept.", reason)
            }
            static var notABackupDetail: String {
                tr("settings.backup.rejected.notABackup", "Choose a .dockgroups file made with Export Settings…. Nothing was changed.")
            }
            static var nothingChanged: String { tr("settings.backup.rejected.newer", "Nothing was changed.") }

            // The confirmation's details
            static var confirmNoGroups: String { tr("settings.backup.confirm.noGroups", "The backup has no groups.") }
            static func confirmNoGroups(exported date: String) -> String {
                tr("settings.backup.confirm.noGroups.exported", "The backup has no groups, exported %@.", date)
            }
            static func confirmContents(groups: String, apps: String) -> String {
                tr("settings.backup.confirm.contents", "The backup has %1$@ with %2$@.", groups, apps)
            }
            static func confirmContents(groups: String, apps: String, exported date: String) -> String {
                tr("settings.backup.confirm.contents.exported", "The backup has %1$@ with %2$@, exported %3$@.", groups, apps, date)
            }
            static var confirmReplace: String {
                tr("settings.backup.confirm.replace", "Replace All uses the backup's groups and settings instead of yours.")
            }
            static func confirmReplaced(_ count: Int) -> String {
                count == 1
                    ? tr(
                        "settings.backup.confirm.replaced.one",
                        "1 current group with the same name as a group in the backup will be replaced by it."
                    )
                    : tr(
                        "settings.backup.confirm.replaced.other",
                        "%ld current groups with the same name as a group in the backup will be replaced by it.",
                        count
                    )
            }
            static func confirmRemoved(_ count: Int) -> String {
                count == 1
                    ? tr("settings.backup.confirm.removed.one", "1 current group not in the backup will be removed.")
                    : tr("settings.backup.confirm.removed.other", "%ld current groups not in the backup will be removed.", count)
            }
            static var confirmReplaceSettings: String {
                tr(
                    "settings.backup.confirm.replaceSettings",
                    "Your settings (popup, shortcuts, Most Used and updates) will be replaced too."
                )
            }
            static var confirmMergeNothing: String {
                tr("settings.backup.confirm.merge.nothing", "Merge keeps your groups and settings and adds nothing.")
            }
            static var confirmMergeAllHere: String {
                tr(
                    "settings.backup.confirm.merge.allHere",
                    "Merge keeps your groups and settings; every group in the backup is already here, so it adds nothing."
                )
            }
            static func confirmMergeAdds(groups: String, apps: String) -> String {
                tr(
                    "settings.backup.confirm.merge.adds",
                    "Merge keeps your groups and settings and adds %1$@ with %2$@ from the backup.",
                    groups, apps
                )
            }
            static func confirmSkipped(_ count: Int) -> String {
                count == 1
                    ? tr("settings.backup.confirm.skipped.one", "1 group already here (same name) will be skipped.")
                    : tr("settings.backup.confirm.skipped.other", "%ld groups already here (same name) will be skipped.", count)
            }
            static var confirmFinal: String {
                tr(
                    "settings.backup.confirm.final",
                    "The Most Used launch counts are kept. A copy of your current files is saved next to them in Application Support. This can't be undone."
                )
            }
        }

        enum Diagnostics {
            static var saveToFile: String { tr("settings.diagnostics.save", "Save to File…") }
            static var export: String { tr("settings.diagnostics.export", "Export Diagnostics") }
            static var exportDetail: String {
                tr("settings.diagnostics.export.detail", "A text report to attach to a GitHub issue or a support request.")
            }
            static var header: String { tr("settings.diagnostics.header", "Diagnostics") }
            static var footer: String {
                tr(
                    "settings.diagnostics.footer",
                    "Lists the app and macOS versions, your Mac's model, where the app is installed, Accessibility access, your settings, update checks, your group names with their app counts, and recent errors. It doesn't list the apps in your groups. Nothing is sent anywhere."
                )
            }
            static var copiedToClipboard: String { tr("settings.diagnostics.copied", "Diagnostics copied to the clipboard") }
            static func saved(_ fileName: String) -> String { tr("settings.diagnostics.saved", "Saved to “%@”", fileName) }
            static func saveFailed(_ reason: String) -> String {
                tr("settings.diagnostics.failed", "The report couldn't be saved: %@", reason)
            }
            static var panelTitle: String { tr("settings.diagnostics.panel.title", "Save Diagnostics") }
            static var panelMessage: String {
                tr(
                    "settings.diagnostics.panel.message",
                    "Save the diagnostics report as a text file, e.g. to attach to a GitHub issue."
                )
            }
            static var panelPrompt: String { tr("settings.diagnostics.panel.prompt", "Save") }
        }
    }

    /// Settings → Changelog: the release notes of the published versions.
    enum Changelog {
        static var tab: String { tr("changelog.tab", "Changelog") }
        /// "Current version: 0.6.0".
        static func currentVersion(_ version: String) -> String {
            tr("changelog.currentVersion", "Current version: %@", version)
        }
        static var refresh: String { tr("changelog.refresh", "Refresh") }
        static var refreshHelp: String { tr("changelog.refresh.help", "Load the latest release notes from GitHub") }
        /// "Last updated 3 minutes ago"; `relativeDate` is the system's relative date, e.g. "3 minutes ago".
        static func lastUpdated(_ relativeDate: String) -> String {
            tr("changelog.lastUpdated", "Last updated %@", relativeDate)
        }
        static var header: String { tr("changelog.header", "Release Notes") }
        static var footer: String {
            tr(
                "changelog.footer",
                "From the project's GitHub releases. A copy stays on this Mac, so the notes show offline too."
            )
        }
        static var latest: String { tr("changelog.latest", "Latest") }
        static var installed: String { tr("changelog.installed", "Installed") }
        static var prerelease: String { tr("changelog.prerelease", "Pre-release") }
        static var noNotes: String { tr("changelog.noNotes", "No release notes for this version.") }
        static var loading: String { tr("changelog.loading", "Loading release notes from GitHub…") }
        static var unavailable: String { tr("changelog.unavailable", "Release notes unavailable") }
        static var showingCachedCopy: String {
            tr("changelog.error.cached", "Could not load release notes — showing cached copy.")
        }
        static var retryHint: String { tr("changelog.retry", "Click Refresh to try again.") }
        static var openRelease: String { tr("changelog.openRelease", "View on GitHub") }
    }

    // MARK: - Update window

    enum UpdateWindow {
        static var title: String { tr("updateWindow.title", "Software Update") }
        static var checking: String { tr("updateWindow.checking", "Checking for updates…") }
        static var upToDateTitle: String { tr("updateWindow.upToDate.title", "You're up to date!") }
        static func upToDateMessage(_ appName: String, version: String) -> String {
            tr("updateWindow.upToDate.message", "%1$@ %2$@ is the newest version available.", appName, version)
        }
        static func availableTitle(_ appName: String) -> String {
            tr("updateWindow.available.title", "A new version of %@ is available!", appName)
        }
        static func availableMessage(_ version: String, current: String) -> String {
            tr("updateWindow.available.message", "Version %1$@ is available — you have %2$@.", version, current)
        }
        static var availableNoDiskImage: String {
            tr(
                "updateWindow.available.noImage",
                "This release has no disk image for automatic installation; download it from its release page."
            )
        }
        static var availableQuestion: String { tr("updateWindow.available.question", "Would you like to download and install it now?") }
        static var skipVersion: String { tr("updateWindow.skip", "Skip This Version") }
        static var remindLater: String { tr("updateWindow.remindLater", "Remind Me Later") }
        static var openReleasePage: String { tr("updateWindow.openReleasePage", "Open Release Page") }
        static var downloadAndInstall: String { tr("updateWindow.downloadAndInstall", "Download and Install") }
        static func downloading(_ version: String) -> String { tr("updateWindow.downloading", "Downloading version %@…", version) }
        static func restartsWhenDone(_ appName: String) -> String {
            tr("updateWindow.restartsWhenDone", "%@ restarts when it's done.", appName)
        }
        static func reopening(_ appName: String) -> String { tr("updateWindow.reopening", "%@ is reopening.", appName) }
        static var dryRunTitle: String { tr("updateWindow.dryRun.title", "Dry run finished") }
        static func dryRunMessage(_ version: String, path: String) -> String {
            tr(
                "updateWindow.dryRun.message",
                "Version %1$@ was downloaded, verified and copied to %2$@. Nothing was replaced.",
                version, path
            )
        }
        static var checkFailed: String { tr("updateWindow.checkFailed", "Couldn't check for updates") }
        static func installFailed(_ version: String) -> String {
            tr("updateWindow.installFailed", "Version %@ couldn't be installed", version)
        }
        static var releasesLink: String { tr("updateWindow.link.releases", "Releases") }
        static var releasePageLink: String { tr("updateWindow.link.releasePage", "Release Page") }
        static var releaseNotes: String { tr("updateWindow.releaseNotes", "Release Notes") }
        static var noReleaseNotes: String { tr("updateWindow.releaseNotes.none", "This release has no notes.") }
        static func relaunchFailed(_ version: String) -> String {
            tr(
                "updateWindow.relaunchFailed",
                "Version %@ is installed, but the app couldn't restart itself. Quit it and open it again.",
                version
            )
        }
    }

    // MARK: - About

    enum About {
        static var findMeOnline: String { tr("about.section.findMe", "Find Me Online") }
        static var supportProject: String { tr("about.section.support", "Support This Project") }
        static var books: String { tr("about.section.books", "My Books") }
        static var openSource: String { tr("about.section.software", "My Open Source Software") }
        static var fullList: String { tr("about.fullList", "Full list at github.com/ercanatay") }
        static var blogs: String { tr("about.section.blogs", "Medium Blogs") }
        static func iconAccessibility(_ appName: String) -> String { tr("about.icon.accessibility", "%@ icon", appName) }
        static func version(_ version: String) -> String {
            tr("about.version", "Version %@ · open source, MIT License", version)
        }
        static var website: String { tr("about.website", "Website") }
        static var sourceCode: String { tr("about.sourceCode", "Source Code") }
        static var license: String { tr("about.license", "License") }
        static var reportBug: String { tr("about.reportBug", "Found a bug? Open an issue") }
        static func inspiredBy(_ appName: String) -> String {
            tr(
                "about.inspiredBy",
                "Inspired by the functionality of DockGroups. %@ is an independent, original implementation written from scratch; it contains no code or artwork from DockGroups.",
                appName
            )
        }

        /// What the projects in My Open Source Software are.
        enum Project {
            static var dockGroups: String { tr("about.project.dockGroups", "This app · Dock groups for macOS") }
            static var intelComputerUse: String {
                tr("about.project.intelComputerUse", "Native macOS desktop automation for Intel Macs via MCP.")
            }
            static var exchangeRate: String {
                tr(
                    "about.project.exchangeRate",
                    "PHP/MySQL exchange rate & portfolio tracker with live scrape + GitHub release updates."
                )
            }
            static var backlinkChecker: String {
                tr("about.project.backlinkChecker", "Check anchors, dofollow/nofollow and HTTP statuses of backlinks.")
            }
            static var consentManager: String {
                tr("about.project.consentManager", "YOOtheme Pro 5 Consent Manager translations plugin (WordPress.org).")
            }
            static var antigravityUpdater: String {
                tr("about.project.antigravityUpdater", "Lightweight macOS updater for Antigravity Tools, 21 languages.")
            }
            static var widgetVisibility: String {
                tr("about.project.widgetVisibility", "Jetpack-free WP plugin for widget visibility with descendant support.")
            }
            static var forbiddenContent: String {
                tr(
                    "about.project.forbiddenContent",
                    "Detects forbidden keywords (e.g. 'Casino') in post titles — like a WP audit checker."
                )
            }
        }
    }
}

// MARK: - Lookup

/// `L10n`'s lookups; the key and English text must be literals (`LocalizationTests` read them).
private func tr(_ key: String, _ english: String) -> String {
    Localization.string(key, english)
}

private func tr(_ key: String, _ english: String, _ arguments: any CVarArg...) -> String {
    Localization.format(key, english, arguments: arguments)
}
