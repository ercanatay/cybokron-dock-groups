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

        /// Apps only, such as the Most Used list's.
        static func appCount(_ count: Int) -> String {
            count == 1 ? tr("common.appCount.one", "1 app") : tr("common.appCount.other", "%ld apps", count)
        }

        /// What a group holds, apps and websites alike.
        static func itemCount(_ count: Int) -> String {
            count == 1 ? tr("common.itemCount.one", "1 item") : tr("common.itemCount.other", "%ld items", count)
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

        static func runningCount(_ count: Int) -> String { tr("popup.summary.running", "%ld running", count) }
        static var byLaunches: String { tr("popup.summary.byLaunches", "by launches") }

        static func noMatch(_ query: String) -> String { tr("popup.search.noMatch", "No items match “%@”", query) }
        static var noMatchHint: String { tr("popup.filter.noMatch.hint", "Press Delete or Esc to clear the filter.") }
        static var mostUsedEmptyHint: String { tr("popup.empty.mostUsed.hint", "Open apps as usual to start building your history.") }

        static var footerSortAZ: String { tr("popup.footer.sortAZ", "A→Z") }
        static var footerSortAZHelp: String { tr("popup.footer.sortAZ.help", "Sort the apps in this group by name, A to Z.") }
        static var footerSortAZAccessibility: String { tr("popup.footer.sortAZ.accessibility", "Sort A to Z") }

        static func footerFilter(_ query: String) -> String {
            tr("popup.search.footer.matches", "Filter: “%@”  ·  ↩ opens the selected item  ·  esc clears", query)
        }

        /// The selected item was found by one of its tags.
        static func footerFilterTag(_ query: String, tag: String, itemName: String) -> String {
            tr("popup.search.footer.tag", "Filter: “%1$@”  ·  tag “%2$@” of %3$@  ·  ↩ opens it  ·  esc clears", query, tag, itemName)
        }

        /// The selected item was found by its task notes.
        static func footerFilterNotes(_ query: String, itemName: String) -> String {
            tr("popup.search.footer.notes", "Filter: “%1$@”  ·  in the task notes of %2$@  ·  ↩ opens it  ·  esc clears", query, itemName)
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
        static var fileHint: String { tr("popup.item.hint.file", "Opens the file in its default app") }
        static var folderHint: String { tr("popup.item.hint.folder", "Opens the folder in Finder") }

        /// The first sentence of an item's tooltip: what clicking it does.
        static func helpOpenWebsite(_ address: String) -> String {
            tr("popup.cell.help.openWebsite", "Open %@ in your browser.", address)
        }
        static func helpBringToFront(_ appName: String) -> String {
            tr("popup.cell.help.bringToFront", "Bring %@ to the front.", appName)
        }
        static func helpOpenApp(_ appName: String) -> String { tr("popup.cell.help.openApp", "Open %@.", appName) }
        static func helpMissing(_ appName: String) -> String { tr("popup.cell.help.missing", "%@ isn't on this Mac.", appName) }
        static func helpOpenFile(_ name: String) -> String { tr("popup.item.help.openFile", "Open %@ in its default app.", name) }
        static func helpOpenFolder(_ name: String) -> String { tr("popup.item.help.openFolder", "Open the folder %@.", name) }

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

    // MARK: - Group Settings

    /// The popup's gear and the "Group Settings…" items of a group's menus, which open the group
    /// window on the group.
    enum GroupSettings {
        /// The gear's tooltip and VoiceOver label.
        static var title: String { tr("group.settings.title", "Group Settings") }
        static var menuItem: String { tr("group.settings.menu", "Group Settings…") }
        static func accessibilityHint(_ groupName: String) -> String {
            tr("group.settings.accessibilityHint", "Shows the name, apps, Dock tile and popup settings of “%@”.", groupName)
        }
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

        // Items
        static var itemsSection: String { tr("groupWindow.items.section", "Items") }
        /// The menu of Add Apps…, Add Files or Folders… and Add Website….
        static var addMenu: String { tr("groupWindow.items.add", "Add") }
        static var addMenuHelp: String { tr("groupWindow.items.add.help", "Add apps, files, folders or a website to this group.") }
        /// Names the Add menu.
        static func noItems(add: String) -> String {
            tr("groupWindow.items.empty", "Nothing here yet. Use “%@” to add apps, files, folders or a web link.", add)
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
                "groupWindow.items.moveHint",
                "To move an item to another group, drag it onto that group in the sidebar, or use %@ in its context menu.",
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
        static func removeFileHelp(_ name: String) -> String {
            tr("groupWindow.items.remove.file", "Remove %@ from this group. The file itself isn't affected.", name)
        }
        static func removeFolderHelp(_ name: String) -> String {
            tr("groupWindow.items.remove.folder", "Remove %@ from this group. The folder itself isn't affected.", name)
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

    /// Add Files or Folders…: the open panel, and the alert about what couldn't be added.
    enum AddItems {
        static var menu: String { tr("addItems.menu", "Add Files or Folders…") }
        static var title: String { tr("addItems.title", "Add Files and Folders to Group") }
        static func message(_ groupName: String) -> String {
            tr("addItems.message", "Choose files and folders to add to “%@”. Apps you choose are added as apps.", groupName)
        }
        static var problemTitle: String { tr("addItems.problem.title", "Some items couldn't be added") }
    }

    /// What every kind of item shares: files and folders, Quick Look, missing items and Locate….
    enum Item {
        /// A group without items: its popup, and a standalone group's Dock menu.
        static var emptyGroup: String { tr("item.group.empty", "No items in this group yet") }
        static func fileAccessibility(_ name: String) -> String { tr("item.kind.file.accessibility", "File %@", name) }
        static func folderAccessibility(_ name: String) -> String { tr("item.kind.folder.accessibility", "Folder %@", name) }
        static var quickLook: String { tr("item.action.quickLook", "Quick Look") }
        static var locate: String { tr("item.action.locate", "Locate…") }
        static func missingHelp(_ name: String) -> String {
            tr("item.missing.help", "“%@” can't be found. It may have been moved, renamed or deleted.", name)
        }
        static func volumeHelp(_ name: String, volume: String) -> String {
            tr("item.volume.help", "“%1$@” is on “%2$@”, which isn't connected.", name, volume)
        }
        /// The second line of a missing item's row, with where it was.
        static func missingRow(_ location: String) -> String { tr("item.missing.row", "Can't be found · %@", location) }
        static func volumeRow(_ volume: String, location: String) -> String {
            tr("item.volume.row", "On “%1$@”, which isn't connected · %2$@", volume, location)
        }
        static func unverifiedRow(_ location: String) -> String { tr("item.unverified.row", "Can't check this location · %@", location) }
        static func locateMessage(_ name: String) -> String {
            tr("item.locate.message", "Choose where “%@” is now. Its details and place in the group are kept.", name)
        }
        static var locatePrompt: String { tr("item.locate.prompt", "Choose") }
        static func locateDuplicate(_ name: String) -> String { tr("item.locate.duplicate", "“%@” is already in this group.", name) }
        static func locateProblemTitle(_ name: String) -> String {
            tr("item.locate.problem.title", "“%@” couldn't be located there", name)
        }
        /// Titles of the alert about the items a group couldn't open (apps, websites, files, folders).
        static func noneOpened(_ groupName: String) -> String {
            tr("item.problems.allFailed", "The items in “%@” couldn't be opened.", groupName)
        }
        static func someNotOpened(_ groupName: String) -> String {
            tr("item.problems.someFailed", "Some items in “%@” couldn't be opened.", groupName)
        }
    }

    /// An item's alias, tags and task notes: the details editor, Edit Details…, and where they're
    /// shown (the group window's rows, the popup's tooltips).
    enum Details {
        static var menu: String { tr("item.details.menu", "Edit Details…") }
        /// The editor's title, with the item's own name.
        static func title(_ name: String) -> String { tr("item.details.title", "Details of “%@”", name) }
        static var alias: String { tr("item.details.alias", "Alias") }
        static var aliasPlaceholder: String { tr("item.details.alias.placeholder", "Another name, shown instead") }
        static var tags: String { tr("item.details.tags", "Tags") }
        static var tagsPlaceholder: String { tr("item.details.tags.placeholder", "finance, q3") }
        static var tagsHint: String { tr("item.details.tags.hint", "Separate tags with commas.") }
        /// Shown when more tags were typed than an item keeps.
        static func tagsLimit(_ maximum: Int) -> String {
            tr("item.details.tags.limit", "Only the first %ld tags are kept.", maximum)
        }
        static var notes: String { tr("item.details.notes", "Task notes") }
        static var notesPlaceholder: String { tr("item.details.notes.placeholder", "What you use it for") }
        /// The counter under the task notes: "42 of 500 characters".
        static func notesCount(_ count: Int, maximum: Int) -> String {
            tr("item.details.notes.count", "%1$ld of %2$ld characters", count, maximum)
        }
        /// The ⓘ button of a row: its tooltip and VoiceOver label.
        static func buttonHelp(_ name: String) -> String { tr("item.details.button.help", "Alias, tags and task notes of %@", name) }
        /// The item's own name, where its alias is shown instead.
        static func originalName(_ name: String) -> String { tr("item.details.originalName", "Name: %@", name) }
        static var searchHint: String { tr("item.details.hint", "Typing any of these in the popup finds this item.") }
        /// Parts of the details line of a tooltip, after "Name: …".
        static func tagsList(_ tags: String) -> String { tr("popup.search.help.tags", "Tags: %@", tags) }
        static func notesSummary(_ notes: String) -> String { tr("popup.search.help.notes", "Notes: %@", notes) }
    }

    /// An item's launch options: the details editor's Opening part, the open panel of "Open with" →
    /// Other…, and the popup's tooltips. The rows' captions and the editor's notes about a chosen
    /// app come from DockGroupsCore (`ItemLaunchCaption`, `ItemOpenerStatus`, `ItemOpenerRefusal`).
    enum Launch {
        static var section: String { tr("item.launch.section", "Opening") }
        static var openWith: String { tr("item.launch.openWith", "Open with") }
        static var defaultApp: String { tr("item.launch.defaultApp", "Default App") }
        /// The default app, named: "Default App (Preview)".
        static func defaultApp(named name: String) -> String { tr("item.launch.defaultApp.named", "Default App (%@)", name) }
        static var other: String { tr("item.launch.otherApp", "Other…") }
        /// The app chosen before, in the menu, when it isn't on this Mac.
        static func notOnThisMac(_ name: String) -> String { tr("item.launch.choice.notOnThisMac", "%@ (not on this Mac)", name) }
        /// The app chosen before, in the menu, when it may not open the item.
        static func refusedChoice(_ name: String) -> String { tr("item.launch.choice.refused", "%@ (can't open it)", name) }
        static var delay: String { tr("item.launch.delay", "Delay") }
        /// A choice of the delay menu: "None", "1 second", "3 seconds".
        static func delayTitle(_ seconds: Int) -> String {
            switch seconds {
            case 0: return tr("item.launch.delay.none", "None")
            case 1: return tr("item.launch.delay.one", "1 second")
            default: return tr("item.launch.delay.other", "%ld seconds", seconds)
            }
        }
        static var delayHint: String {
            tr("item.launch.delay.hint", "Open All and Start wait this long; clicking the item opens it right away.")
        }
        static var pickerTitle: String { tr("item.launch.picker.title", "Choose an App") }
        static func pickerMessage(_ itemName: String) -> String {
            tr("item.launch.picker.message", "Choose the app that opens “%@”.", itemName)
        }
        static var pickerPrompt: String { tr("item.launch.picker.prompt", "Choose") }
        /// The popup's tooltip of a file, folder or website with a chosen app.
        static func helpOpenWith(_ name: String, appName: String) -> String {
            tr("item.launch.help.openWith", "Open %1$@ with %2$@.", name, appName)
        }
        /// VoiceOver's hint of such an item.
        static func hintOpenWith(_ appName: String) -> String { tr("item.launch.hint.openWith", "Opens it with %@", appName) }
    }

    // MARK: - Problems

    enum Problems {
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
        static var supportTab: String { tr("settings.support.tab", "Support") }

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
            /// Only when the shortcuts couldn't be registered as hot keys and are watched for instead.
            static var hotKeyUnavailable: String {
                tr(
                    "shortcuts.hotkey.unavailable",
                    "macOS couldn't reserve these keys for the shortcuts, so they're watched for instead: that needs Accessibility access, and the app in front receives the key press too."
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
                    "Launch Group, Quit Group, Show Group, New Group from Open Apps and Add Open Apps to Group are actions in Shortcuts and Spotlight: add them to your own shortcuts, with your own trigger."
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
                    "settings.mostUsed.footer.recording",
                    "Apps are ranked by how often you open them, from the Dock, Finder, Spotlight or a group. Launches are counted only while Most Used is shown; turning it off keeps the history."
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
            static var busyTitle: String { tr("settings.otherVersions.busy.title", "An update is under way") }
            static func busyMessage(_ appName: String) -> String {
                tr(
                    "settings.otherVersions.busy.message",
                    "%@ is checking for or installing an update right now. Try again once it's finished.",
                    appName
                )
            }
            static var confirmUpgrade: String {
                tr(
                    "settings.otherVersions.confirm.upgrade",
                    "Skipped versions are cleared, so automatic checks offer every newer release again."
                )
            }
            /// Title of the question before installing a version older than
            /// `ReleaseHistory.minimumSecurityVersion`.
            static var preSafetyTitle: String {
                tr("updates.otherVersions.preSafety.title", "This version lacks security fixes")
            }
            static func preSafetyMessage(_ version: String) -> String {
                tr(
                    "updates.otherVersions.preSafety.message",
                    "Version %@ was released before important security fixes, such as stricter checks of the updates it installs. Install it only if you need it, and update to the latest version again afterwards.",
                    version
                )
            }
            /// Part of the question before installing a version older than
            /// `ReleaseHistory.firstGroupItemsVersion` while the groups hold files, folders or details.
            static func groupItemsWarning(_ version: String) -> String {
                tr(
                    "updates.otherVersions.items.warning",
                    "Version %@ can't show files, folders, aliases, tags or task notes. A copy of your groups is kept before it's installed; editing groups in that version drops these items' details.",
                    version
                )
            }
            /// Part of the question before installing a version older than
            /// `ReleaseHistory.firstContextSwitchingVersion` while Start and Finish settings,
            /// launch options or protected apps are in use.
            static func switchingWarning(_ version: String) -> String {
                tr(
                    "updates.otherVersions.switching.warning",
                    "Version %@ doesn't know Start and Finish, launch options or protected apps. Copies of your groups and settings are kept before it's installed; Close All there quits protected apps, and saving there drops these settings.",
                    version
                )
            }
            /// Part of the question before installing a version older than
            /// `ReleaseHistory.firstGroupShortcutsVersion` while a group has a shortcut, a group is
            /// archived or a template exists.
            static func libraryWarning(_ version: String) -> String {
                tr(
                    "updates.otherVersions.library.warning",
                    "Version %@ doesn't know archived groups, group shortcuts or templates. Archived groups show there as ordinary groups, and editing groups there drops their shortcuts and which groups are archived. Copies of your groups and settings are kept before it's installed; templates stay for when you come back.",
                    version
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
            /// "Restored 2 groups with 7 items".
            static func restored(groups: String, items: String) -> String {
                tr("settings.backup.status.restored", "Restored %1$@ with %2$@", groups, items)
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
            static func confirmContents(groups: String, items: String) -> String {
                tr("settings.backup.confirm.contents", "The backup has %1$@ with %2$@.", groups, items)
            }
            static func confirmContents(groups: String, items: String, exported date: String) -> String {
                tr("settings.backup.confirm.contents.exported", "The backup has %1$@ with %2$@, exported %3$@.", groups, items, date)
            }
            /// Items of the backup that import leaves out (`SettingsBackup.leftOutItemCount`).
            static func leftOut(_ count: Int) -> String {
                count == 1
                    ? tr("settings.backup.leftOut.one", "1 item in the backup was left out: it can't be opened safely.")
                    : tr("settings.backup.leftOut.other", "%ld items in the backup were left out: they can't be opened safely.", count)
            }
            /// Items of the backup kept without the app chosen to open them
            /// (`SettingsBackup.resetLaunchOptionCount`).
            static func launchReset(_ count: Int) -> String {
                count == 1
                    ? tr("settings.backup.launchReset.one", "The launch settings of 1 item were reset: they named an app that runs files.")
                    : tr("settings.backup.launchReset.other", "The launch settings of %ld items were reset: they named apps that run files.", count)
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
            static func confirmMergeAdds(groups: String, items: String) -> String {
                tr(
                    "settings.backup.confirm.merge.adds",
                    "Merge keeps your groups and settings and adds %1$@ with %2$@ from the backup.",
                    groups, items
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

// MARK: - Start and Finish

extension L10n {
    /// Starting and finishing groups: the popup's marker, the menu bar menu, the group window's
    /// Start and Finish section, Settings → Switching and the alert about apps a transition left
    /// as they were. The Start and Finish buttons' titles and help come from `SwitchingOffer`.
    enum Switching {
        enum Popup {
            /// The summary line's marker of the current group: "8 items · 3 running · current".
            static var current: String { tr("popup.switching.current", "current") }
        }

        enum MenuBar {
            /// The menu's first line while a group is current.
            static func current(_ groupName: String) -> String { tr("menuBar.switching.current", "Current: %@", groupName) }
            static func currentTooltip(_ groupName: String) -> String {
                tr("menuBar.switching.current.tooltip", "“%@” is the current group, the one started last. Choose it to show its popup.", groupName)
            }
            static func start(_ groupName: String) -> String { tr("menuBar.switching.start", "Start “%@”", groupName) }
            static func finish(_ groupName: String) -> String { tr("menuBar.switching.finish", "Finish “%@”", groupName) }
            /// Added to a group's tooltip.
            static var startHint: String { tr("menuBar.switching.startHint", "Hold ⌃⌥ to start it.") }
        }

        enum GroupWindow {
            static var section: String { tr("groupWindow.switching.section", "Start and Finish") }
            static var onStart: String { tr("groupWindow.switching.onStart", "When this group starts") }
            static var onFinish: String { tr("groupWindow.switching.onFinish", "When this group finishes") }
            static var afterFinish: String { tr("groupWindow.switching.afterFinish", "After finishing") }
            static var leaveOthers: String { tr("groupWindow.switching.onStart.leaveOthers", "Leave other apps open") }
            static var hidePreviousGroup: String { tr("groupWindow.switching.onStart.hidePreviousGroup", "Hide the previous group's apps") }
            static var hideAllOtherApps: String { tr("groupWindow.switching.onStart.hideAllOtherApps", "Hide all other apps") }
            static var quitPreviousGroup: String { tr("groupWindow.switching.onStart.quitPreviousGroup", "Quit the previous group's apps") }
            static var hideApps: String { tr("groupWindow.switching.onFinish.hideApps", "Hide its apps") }
            static var quitApps: String { tr("groupWindow.switching.onFinish.quitApps", "Quit its apps") }
            static var leaveApps: String { tr("groupWindow.switching.onFinish.leaveApps", "Leave its apps open") }
            static var showPreviousGroup: String { tr("groupWindow.switching.afterFinish.showPreviousGroup", "Show the previous group") }
            static var doNothing: String { tr("groupWindow.switching.afterFinish.nothing", "Do nothing") }
            static var quitWarning: String {
                tr(
                    "groupWindow.switching.quitWarning",
                    "Quitting asks apps to quit; they can still ask to save changes. Links, Siri and Shortcuts ask you first."
                )
            }
            static var protectedApps: String { tr("groupWindow.switching.protectedApps", "Protected Apps…") }
            static var protectedAppsHelp: String {
                tr("groupWindow.switching.protectedApps.help", "Choose the apps that are never hidden or quit, in Settings → Switching.")
            }
            static var isCurrent: String { tr("groupWindow.switching.current", "This is the current group.") }
            static var isNotCurrent: String { tr("groupWindow.switching.notCurrent", "Start makes this the current group.") }
            static var footer: String {
                tr(
                    "groupWindow.switching.footer",
                    "Start opens the group's items as Open All does and puts the group started before it away; Finish puts this group away. Protected apps, and apps both groups use, are never hidden or quit."
                )
            }
        }

        enum Settings {
            static var tab: String { tr("settings.tab.switching", "Switching") }
            static var protectedHeader: String { tr("switching.protected.header", "Protected Apps") }
            static var protectedEmpty: String { tr("switching.protected.empty", "No protected apps yet.") }
            static var addRunningApp: String { tr("switching.protected.addRunning", "Add a Running App") }
            static var noRunningApps: String { tr("switching.protected.addRunning.none", "No other running apps") }
            static func remove(_ appName: String) -> String { tr("switching.protected.remove", "Stop protecting %@", appName) }
            static func protectedFooter(_ appName: String) -> String {
                tr(
                    "switching.protected.footer",
                    "Start, Finish and Close All never quit these apps, and switching groups never hides them. %@ and its groups' own apps are always protected, and Finder is never quit.",
                    appName
                )
            }
            static func full(_ count: Int) -> String { tr("switching.protected.full", "The list holds at most %ld apps.", count) }
            static var pickerTitle: String { tr("switching.protected.picker.title", "Add Protected Apps") }
            static var pickerMessage: String {
                tr("switching.protected.picker.message", "Choose apps that Start, Finish and Close All never quit.")
            }
            static var startHeader: String { tr("switching.start.header", "Start and Finish") }
            static var startSummary: String {
                tr(
                    "switching.start.summary",
                    "Start opens a group's items as Open All does, then puts the group started before it away as the group's settings say: by default its apps are hidden, never quit. Finish hides the group's apps and shows the previous group again. Each group's settings are in its group window."
                )
            }
            static var startAsking: String {
                tr("switching.start.asking", "Links, Siri and Shortcuts ask first when a group is set to quit apps.")
            }
            static var quittingGroups: String { tr("switching.start.quitting", "Groups set to quit apps") }
            static var currentGroup: String { tr("switching.current.label", "Current group") }
            static var noCurrentGroup: String { tr("switching.current.none", "None") }
            static var previousGroup: String { tr("switching.current.previous", "Started before it") }
            static func currentDetail(_ appName: String) -> String {
                tr(
                    "switching.current.detail",
                    "The current group is the one started last, until it's finished. It's forgotten when %@ quits.",
                    appName
                )
            }
        }

        /// Settings → Switching → Focus. What the current Focus asks for comes from DockGroupsCore
        /// (`FocusFilterStatus`).
        enum Focus {
            static var header: String { tr("switching.focus.header", "Focus") }
            static func howTo(_ appName: String) -> String {
                tr(
                    "switching.focus.howTo",
                    "A Focus can start a group when it turns on. In System Settings → Focus, choose a Focus, then Focus Filters → Add Filter → %@, and pick the group and what happens.",
                    appName
                )
            }
            static var openSettings: String { tr("switching.focus.openSettings", "Open Focus Settings…") }
            static var now: String { tr("switching.focus.now", "Now") }
            static func footer(_ appName: String) -> String {
                tr(
                    "switching.focus.footer",
                    "A Focus only hides apps; it never quits them. It works while %@ is running. A Shortcuts automation that starts the group when the Focus turns on does the same.",
                    appName
                )
            }
        }

        /// Apps a transition couldn't hide, quit or show again.
        enum Problems {
            static func start(_ groupName: String) -> String {
                tr("switching.problem.start", "Starting “%@” left some apps as they were.", groupName)
            }
            static func finish(_ groupName: String) -> String {
                tr("switching.problem.finish", "Finishing “%@” left some apps as they were.", groupName)
            }
            static func notHidden(_ appName: String) -> String { tr("switching.problem.notHidden", "• %@: couldn't be hidden.", appName) }
            static func notQuit(_ appName: String) -> String { tr("switching.problem.notQuit", "• %@: couldn't be asked to quit.", appName) }
            static func notShown(_ appName: String) -> String { tr("switching.problem.notShown", "• %@: couldn't be shown again.", appName) }
        }

        /// Settings → Shortcuts & Siri.
        enum Shortcuts {
            static var shortcutsAppDetail: String {
                tr(
                    "settings.shortcuts.switching.shortcutsApp.detail",
                    "Start Group and Finish Group are there too. Nobody answers questions in an automation, so for groups you start or finish there, choose hiding rather than quitting."
                )
            }
            static var linksFooter: String {
                tr(
                    "settings.shortcuts.switching.links.footer",
                    "Start and finish links share the 5-second limit of launch and hide links, and ask first when the group is set to quit apps."
                )
            }
        }
    }
}

// MARK: - Group shortcuts

extension L10n.GroupWindow {
    /// The group window's Keyboard Shortcut section (spec §3.1). The refusal and status texts come
    /// from DockGroupsCore (`GroupShortcutRefusal`, `GroupShortcutStatus`).
    enum Shortcut {
        static var section: String { tr("groupWindow.shortcut.section", "Keyboard Shortcut") }
        static var label: String { tr("groupWindow.shortcut.label", "Shortcut") }
        static var record: String { tr("groupWindow.shortcut.record", "Record Shortcut") }
        static var recording: String { tr("groupWindow.shortcut.recording", "Type a shortcut…") }
        static var recordingHelp: String {
            tr(
                "groupWindow.shortcut.recordingHelp",
                "Press the keys: at least two of Control, Option and Command, and a key. Escape cancels; Delete removes the shortcut."
            )
        }
        static var fieldHelp: String {
            tr("groupWindow.shortcut.fieldHelp", "Click, then press the keys of a shortcut that works in every app.")
        }
        static var remove: String { tr("groupWindow.shortcut.remove", "Remove Shortcut") }
        static var whenPressed: String { tr("groupWindow.shortcut.whenPressed", "When pressed") }
        static var none: String {
            tr("groupWindow.shortcut.none", "No shortcut yet. Record one to show, open or start this group from any app.")
        }
        static var startNote: String {
            tr("groupWindow.shortcut.startNote", "Starting or finishing asks first when it would quit apps; hiding, the default, doesn't ask.")
        }
        static func accessibility(_ shortcut: String) -> String { tr("groupWindow.shortcut.accessibility", "Keyboard shortcut: %@", shortcut) }
        static var accessibilityNone: String { tr("groupWindow.shortcut.accessibility.none", "Keyboard shortcut: none") }
    }
}

extension L10n.Settings.Shortcuts {
    /// Settings → Shortcuts & Siri → Group Shortcuts (spec §3.2): read-only, set in each group.
    enum Groups {
        static var header: String { tr("settings.shortcuts.groups.header", "Group Shortcuts") }
        static var none: String { tr("settings.shortcuts.groups.none", "No group has its own shortcut yet.") }
        static var change: String { tr("settings.shortcuts.groups.change", "Change…") }
        static func changeHelp(_ groupName: String) -> String {
            tr("settings.shortcuts.groups.changeHelp", "Change the shortcut of “%@” in its settings.", groupName)
        }
        static func footer(_ appName: String) -> String {
            tr(
                "settings.shortcuts.groups.footer",
                "Each group can have its own shortcut, set in its settings. These keys work in every app while %@ is running, and the app in front doesn't receive them.",
                appName
            )
        }
        /// Added to the number shortcuts' footer.
        static var renumber: String {
            tr(
                "settings.shortcuts.groups.renumber",
                "Archiving, deleting or moving a group renumbers the groups after it; a group's own keyboard shortcut stays the same."
            )
        }
    }
}

// MARK: - Archive, duplicate and templates

extension L10n.GroupWindow {
    /// Duplicate, Archive and the Archived list of the group window (spec §1.6–1.8, §3.3–3.4).
    enum Archive {
        static var duplicate: String { tr("groupWindow.archive.duplicate", "Duplicate") }
        static var archive: String { tr("groupWindow.archive.archive", "Archive") }
        static var restore: String { tr("groupWindow.archive.restore", "Restore") }
        /// The sidebar's Archived section: "Archived (2)".
        static func section(_ count: Int) -> String { tr("groupWindow.archive.section", "Archived (%ld)", count) }

        // Archiving a standalone group
        static func confirmTitle(_ groupName: String) -> String { tr("groupWindow.archive.confirm.title", "Archive “%@”?", groupName) }
        static var confirmMessage: String {
            tr(
                "groupWindow.archive.confirm.message",
                "Its own app and Dock icon are removed until you restore it. The group, its items and its settings are kept."
            )
        }

        // The archived group's summary
        static func archivedOn(_ date: String) -> String { tr("groupWindow.archive.detail.archivedOn", "Archived on %@", date) }
        static var archived: String { tr("groupWindow.archive.detail.archived", "Archived") }
        static var explanation: String {
            tr(
                "groupWindow.archive.detail.explanation",
                "Archived groups don't appear in the popup, the menu bar menu, Siri, links or Focus filters, and their keyboard shortcut is off. Restore the group to use or edit it."
            )
        }
        static var noItems: String { tr("groupWindow.archive.detail.noItems", "No items") }
        static func file(_ name: String) -> String { tr("groupWindow.archive.item.file", "%@ (file)", name) }
        static func folder(_ name: String) -> String { tr("groupWindow.archive.item.folder", "%@ (folder)", name) }
        static func shortcutOff(_ shortcut: String) -> String {
            tr("groupWindow.archive.detail.shortcutOff", "%@ (off while archived)", shortcut)
        }
        static var noShortcut: String { tr("groupWindow.archive.detail.noShortcut", "None") }
        static var dockIcon: String { tr("groupWindow.archive.detail.dockIcon", "Dock icon") }
        static var dockIconReturns: String {
            tr("groupWindow.archive.detail.dockIconReturns", "Comes back when the group is restored")
        }
        static var restoreHelp: String {
            tr("groupWindow.archive.detail.restoreHelp", "Put the group back at the end of the list, with all its settings.")
        }

        /// Settings → Switching → Focus, when the current Focus names an archived group.
        static func focusStatus(_ groupName: String) -> String {
            tr(
                "groupWindow.archive.focusStatus",
                "The current Focus names “%@”, which is archived: it does nothing until you restore the group.",
                groupName
            )
        }
    }
}

extension L10n {
    /// Save as Template…, the + menu's templates and Manage Templates (spec §1.9, §3.5).
    enum Templates {
        // Menus
        static var newGroup: String { tr("templates.menu.newGroup", "New Group") }
        static var newGroupFromTemplate: String { tr("templates.menu.fromTemplate", "New Group from Template") }
        static var noTemplates: String { tr("templates.menu.none", "No Templates") }
        static var manage: String { tr("templates.menu.manage", "Manage Templates…") }
        static var saveAsTemplate: String { tr("templates.menu.save", "Save as Template…") }
        static var addMenuHelp: String {
            tr("templates.menu.help", "Add a group. Its menu also adds a group made from a template.")
        }

        // Save as Template
        static func saveTitle(_ groupName: String) -> String { tr("templates.save.title", "Save “%@” as a Template", groupName) }
        static var name: String { tr("templates.save.name", "Template name") }
        static var saveMessage: String {
            tr(
                "templates.save.message",
                "A template keeps the group's items, with their details and launch options, and its Dock tile, popup, and Start and Finish settings. Groups made from it don't get its keyboard shortcut or its own Dock icon."
            )
        }
        static var save: String { tr("templates.save.confirm", "Save") }
        static func limit(_ maximum: Int) -> String {
            tr("templates.save.limit", "You can keep up to %ld templates. Delete one in Manage Templates… first.", maximum)
        }
        static func replaceTitle(_ templateName: String) -> String {
            tr("templates.replace.title", "A template named “%@” already exists", templateName)
        }
        static var replaceMessage: String {
            tr("templates.replace.message", "Replace it with this group? Groups made from it before aren't affected.")
        }
        static var replace: String { tr("templates.replace.confirm", "Replace") }

        // Manage Templates
        static var manageTitle: String { tr("templates.manage.title", "Manage Templates") }
        static var empty: String {
            tr("templates.manage.empty", "No templates yet. To save one, choose Save as Template… in a group's menu in the sidebar.")
        }
        /// "7 items · saved October 25, 2026".
        static func summary(items: String, saved date: String) -> String {
            tr("templates.manage.summary", "%1$@ · saved %2$@", items, date)
        }
        static func newGroupHelp(_ templateName: String) -> String {
            tr("templates.manage.newGroup.help", "Add a group made from “%@”.", templateName)
        }
        static var footer: String {
            tr(
                "templates.manage.footer",
                "To change a template, make a group from it, edit the group, then save it as a template with the same name and replace it."
            )
        }
        static var renameTitle: String { tr("templates.rename.title", "Rename Template") }
        static var renameMessage: String { tr("templates.rename.message", "Enter a new name for the template.") }
        static func nameTaken(_ templateName: String) -> String {
            tr("templates.rename.taken", "A template named “%@” already exists. Choose another name.", templateName)
        }
        static func deleteTitle(_ templateName: String) -> String {
            tr("templates.delete.title", "Delete the template “%@”?", templateName)
        }
        static var deleteMessage: String { tr("templates.delete.message", "Groups made from it aren't affected.") }
        static var deleteTemplate: String { tr("templates.delete.confirm", "Delete Template") }
    }
}

extension L10n.Settings.Backup {
    /// The import question's and status's lines about archived groups and templates; the rest of
    /// what the backup holds is said by DockGroupsCore (`SettingsRestoreSummary`).
    enum Library {
        /// Merging adds archived groups or templates, but no active group.
        static var mergeKeeps: String { tr("settings.backup.library.merge.keeps", "Merge keeps your groups and settings.") }
        static func mergesArchived(_ count: Int) -> String {
            count == 1
                ? tr("settings.backup.library.mergesArchived.one", "It adds 1 archived group.")
                : tr("settings.backup.library.mergesArchived.other", "It adds %ld archived groups.", count)
        }
        /// After a merge: "Added 2 archived groups".
        static func addedArchived(_ count: Int) -> String {
            count == 1
                ? tr("settings.backup.library.status.archived.one", "Added 1 archived group")
                : tr("settings.backup.library.status.archived.other", "Added %ld archived groups", count)
        }
        static func addedTemplates(_ count: Int) -> String {
            count == 1
                ? tr("settings.backup.library.status.templates.one", "Added 1 template")
                : tr("settings.backup.library.status.templates.other", "Added %ld templates", count)
        }
    }
}

// MARK: - Capture

extension L10n {
    /// Capturing the open apps into a group (capture spec §1, §3): the menu items that start it and
    /// the review sheet.
    enum Capture {
        static var menuBarItem: String { tr("menuBar.capture.newGroup", "New Group from Open Apps…") }
        static var menuBarTooltip: String {
            tr("menuBar.capture.newGroup.tooltip", "Make a group of the apps that are open now. You choose which ones first.")
        }
        /// The sidebar's + menu.
        static var sidebarItem: String { tr("groupWindow.capture.newGroup", "New Group from Open Apps…") }
        /// A group's Add menu.
        static var addMenuItem: String { tr("groupWindow.capture.addOpenApps", "Add Open Apps…") }
        static var addMenuHelp: String { tr("groupWindow.capture.addOpenApps.help", "Add apps that are open now to this group.") }
        /// The pill of an empty group's popup.
        static var popupPill: String { tr("popup.capture.addOpenApps", "Add Open Apps…") }

        enum Sheet {
            static var newGroupTitle: String { tr("capture.sheet.title.new", "New Group from Open Apps") }
            static func addTitle(_ groupName: String) -> String { tr("capture.sheet.title.add", "Add Open Apps to “%@”", groupName) }
            static var name: String { tr("capture.sheet.name", "Name") }
            /// "Open Apps (7)".
            static func header(_ count: Int) -> String { tr("capture.sheet.header", "Open Apps (%ld)", count) }
            static var order: String { tr("capture.sheet.order", "Order:") }
            static var orderRecentlyUsed: String { tr("capture.sheet.order.recentlyUsed", "Most Recently Used") }
            static var orderName: String { tr("capture.sheet.order.name", "Name") }
            static var windowsOnly: String { tr("capture.sheet.windowsOnly", "Select only apps with open windows") }
            static var windowsOnlyUnavailable: String {
                tr("capture.sheet.windowsOnly.unavailable", "macOS didn't say which apps have open windows.")
            }
            static var hidden: String { tr("capture.sheet.note.hidden", "Hidden") }
            static var noWindows: String { tr("capture.sheet.note.noWindows", "No open windows") }
            static var protected: String { tr("capture.sheet.note.protected", "Protected") }
            static var inGroup: String { tr("capture.sheet.note.inGroup", "In this group") }
            static var selectAll: String { tr("capture.sheet.selectAll", "Select All") }
            static var selectNone: String { tr("capture.sheet.selectNone", "Select None") }
            static var create: String { tr("capture.sheet.create", "Create Group") }
            /// "Add 3 Apps".
            static func add(_ count: Int) -> String {
                count == 1 ? tr("capture.sheet.add.one", "Add 1 App") : tr("capture.sheet.add.other", "Add %ld Apps", count)
            }
            static func footer(_ appName: String) -> String {
                tr("capture.sheet.footer", "Background apps, Finder and %@ aren't listed. Nothing is opened or quit.", appName)
            }
            static var noOpenApps: String { tr("capture.sheet.empty", "No other apps are open.") }
            static func allInGroup(_ groupName: String) -> String {
                tr("capture.sheet.allInGroup", "Every open app is already in “%@”.", groupName)
            }
        }
    }
}

// MARK: - Triggers

extension L10n {
    /// Triggers (triggers spec §1.14, §3): the editor, the notice, the group window's section,
    /// Settings → Triggers and the menu bar's pause. The rules' and last runs' words come from
    /// DockGroupsCore (`TriggerDescriptions`).
    enum Triggers {
        enum Editor {
            static func newTitle(_ groupName: String) -> String { tr("triggers.editor.title.new", "New Trigger for “%@”", groupName) }
            static var editTitle: String { tr("triggers.editor.title.edit", "Edit Trigger") }
            static var when: String { tr("triggers.editor.when", "When") }
            static var action: String { tr("triggers.editor.do", "Do") }
            static var how: String { tr("triggers.editor.how", "How") }
            static var atATime: String { tr("triggers.editor.event.time", "At a Time") }
            static var atLogin: String { tr("triggers.editor.event.login", "At Login") }
            static func whenAppOpens(_ appName: String) -> String { tr("triggers.editor.event.appOpens", "When %@ Opens", appName) }
            static var whenScreensWake: String { tr("triggers.editor.event.screensWake", "When the Screens Wake") }
            static var whenScreensSleep: String { tr("triggers.editor.event.screensSleep", "When the Screens Sleep") }
            static var whenDisplayConnects: String { tr("triggers.editor.event.displayConnects", "When a Display Connects") }
            static var whenDisplayDisconnects: String { tr("triggers.editor.event.displayDisconnects", "When a Display Disconnects") }
            static var whenDisplaysConnected: String { tr("triggers.editor.event.displaysConnected", "When These Displays Are Connected") }
            static var whenDisplaysDisconnected: String {
                tr("triggers.editor.event.displaysDisconnected", "When These Displays Are No Longer Connected")
            }
            static var whenWiFiJoins: String { tr("triggers.editor.event.wifiJoins", "When the Mac Joins a Wi-Fi Network") }
            static var whenWiFiLeaves: String { tr("triggers.editor.event.wifiLeaves", "When the Mac Leaves a Wi-Fi Network") }
            static var whenEthernetConnects: String { tr("triggers.editor.event.ethernetConnects", "When Ethernet Connects") }
            static var whenEthernetDisconnects: String { tr("triggers.editor.event.ethernetDisconnects", "When Ethernet Disconnects") }
            static var display: String { tr("triggers.editor.display", "Display") }
            static var anyExternalDisplay: String { tr("triggers.editor.display.anyExternal", "Any External Display") }
            /// A saved display that isn't connected now: "LG UltraFine (not connected)".
            static func notConnected(_ name: String) -> String { tr("triggers.editor.display.notConnected", "%@ (not connected)", name) }
            static var unnamedDisplay: String { tr("triggers.editor.display.unnamed", "Unnamed Display") }
            static var displays: String { tr("triggers.editor.displays", "Displays") }
            static var useCurrentDisplays: String { tr("triggers.editor.displays.useCurrent", "Use Current Displays") }
            static var noDisplays: String {
                tr("triggers.editor.displays.none", "No displays chosen: connect them, then click Use Current Displays.")
            }
            static var displaysHint: String {
                tr(
                    "triggers.editor.displays.hint",
                    "Only which displays are connected counts, built-in included: not where they are, their resolution or which one is main."
                )
            }
            static var networkName: String { tr("triggers.editor.wifi.name", "Network Name") }
            static var useCurrentNetwork: String { tr("triggers.editor.wifi.useCurrent", "Use Current Network") }
            static var invalidNetworkName: String {
                tr("triggers.editor.wifi.invalid", "A Wi-Fi network's name has 1 to 32 bytes and no control characters.")
            }
            static var networkNameHint: String {
                tr("triggers.editor.wifi.hint", "The name is matched exactly, capitals included, and any network with this name counts.")
            }
            static var leavesHint: String {
                tr(
                    "triggers.editor.wifi.leavesHint",
                    "Leaving counts when the Mac joins another network or Wi-Fi is turned off — never when the app just can't see the network's name."
                )
            }
            static var locationNeeded: String {
                tr(
                    "triggers.editor.wifi.location",
                    "macOS shows Wi-Fi network names only to apps allowed to use Location Services. Your location is never read."
                )
            }
            static var allowLocation: String { tr("triggers.editor.wifi.allow", "Allow…") }
            static var openPrivacySettings: String { tr("triggers.editor.wifi.openPrivacySettings", "Open Privacy Settings…") }
            static var waitsForLocation: String {
                tr("triggers.editor.wifi.waits", "You can add the trigger now: it waits until macOS lets the app see network names.")
            }
            static var locationAllowed: String {
                tr("triggers.editor.wifi.allowed", "Location access is allowed: the app reads only the network's name.")
            }
            static func locationDenied(_ appName: String) -> String {
                tr(
                    "triggers.editor.wifi.denied",
                    "Location access isn't allowed: turn %@ on in System Settings → Privacy & Security → Location Services.",
                    appName
                )
            }
            static var locationServicesOff: String {
                tr(
                    "triggers.editor.wifi.servicesOff",
                    "Location Services is off on this Mac: turn it on in System Settings → Privacy & Security → Location Services."
                )
            }
            static var locationRestricted: String {
                tr("triggers.editor.wifi.restricted", "Location access isn't available on this Mac: it's restricted by a profile or Screen Time.")
            }
            static var ethernetHint: String {
                tr(
                    "triggers.editor.ethernet.hint",
                    "Ethernet counts as connected while a wired connection — built in, an adapter or a dock — has a network, even when Wi-Fi is used first. It needs no permission."
                )
            }
            static var finishWhenEnds: String { tr("triggers.editor.finishWhenEnds", "Finish when it ends") }
            static func finishWhenEndsHint(_ groupName: String) -> String {
                tr(
                    "triggers.editor.finishWhenEnds.hint",
                    "When it ends, “%@” is finished — its apps hidden — if it's still the current group and this trigger started it.",
                    groupName
                )
            }
            static var time: String { tr("triggers.editor.time", "Time") }
            static var days: String { tr("triggers.editor.days", "Days") }
            static var weekdays: String { tr("triggers.editor.weekdays", "Weekdays") }
            static var weekends: String { tr("triggers.editor.weekends", "Weekends") }
            static var everyDay: String { tr("triggers.editor.everyDay", "Every Day") }
            /// A day's button for VoiceOver: "Monday, on".
            static func dayOn(_ day: String) -> String { tr("triggers.editor.day.on", "%@, on", day) }
            static func dayOff(_ day: String) -> String { tr("triggers.editor.day.off", "%@, off", day) }
            static var noDays: String { tr("triggers.editor.noDays", "Choose at least one day.") }
            static var showPopup: String { tr("triggers.editor.action.showPopup", "Show the Popup") }
            static var openAll: String { tr("triggers.editor.action.openAll", "Open All") }
            static var start: String { tr("triggers.editor.action.start", "Start") }
            static var finish: String { tr("triggers.editor.action.finish", "Finish") }
            static var notice: String { tr("triggers.editor.runMode.notice", "Show a 5-Second Notice") }
            static var askFirst: String { tr("triggers.editor.runMode.askFirst", "Ask First") }
            static var rightAway: String { tr("triggers.editor.runMode.immediately", "Run Right Away") }
            static var oncePerDay: String { tr("triggers.editor.oncePerDay", "At most once a day") }
            static func startHint(_ groupName: String) -> String {
                tr(
                    "triggers.editor.hint.start",
                    "Starting hides the apps of the group started before, as “%@” is set to. A trigger never quits apps.",
                    groupName
                )
            }
            static func finishHint(_ groupName: String) -> String {
                tr(
                    "triggers.editor.hint.finish",
                    "Finish runs only while “%@” is the current group, and hides its apps; it never quits them.",
                    groupName
                )
            }
            static var sleepHint: String {
                tr(
                    "triggers.editor.hint.screensSleep",
                    "Nobody can answer a notice while the screens sleep, so this trigger finishes the group right away."
                )
            }
            static func catchUp(_ time: String) -> String {
                tr(
                    "triggers.editor.catchUp",
                    "If the Mac is asleep at %@, the trigger runs when it wakes, up to 30 minutes late.",
                    time
                )
            }
            static func loginNeedsLoginItem(_ appName: String) -> String {
                tr("triggers.editor.login.needsLoginItem", "At Login triggers need %@ to open at login.", appName)
            }
            static var turnOnLoginItem: String { tr("triggers.editor.login.turnOn", "Turn On Open at Login") }
            static var add: String { tr("triggers.editor.add", "Add Trigger") }
            static var save: String { tr("triggers.editor.save", "Save") }
        }

        enum Notice {
            static func starting(_ groupName: String) -> String { tr("triggers.notice.starting", "Starting “%@”", groupName) }
            static func opening(_ groupName: String) -> String { tr("triggers.notice.opening", "Opening “%@”", groupName) }
            static func finishing(_ groupName: String) -> String { tr("triggers.notice.finishing", "Finishing “%@”", groupName) }
            static func showing(_ groupName: String) -> String { tr("triggers.notice.showing", "Showing “%@”", groupName) }
            static func askStart(_ groupName: String) -> String { tr("triggers.notice.ask.start", "Start “%@”?", groupName) }
            static func askOpen(_ groupName: String) -> String { tr("triggers.notice.ask.openAll", "Open All in “%@”?", groupName) }
            static func askFinish(_ groupName: String) -> String { tr("triggers.notice.ask.finish", "Finish “%@”?", groupName) }
            static func askShow(_ groupName: String) -> String { tr("triggers.notice.ask.showPopup", "Show “%@”?", groupName) }
            static var notNow: String { tr("triggers.notice.notNow", "Not Now") }
            static var startNow: String { tr("triggers.notice.startNow", "Start Now") }
            static var openNow: String { tr("triggers.notice.openNow", "Open Now") }
            static var finishNow: String { tr("triggers.notice.finishNow", "Finish Now") }
            static var showNow: String { tr("triggers.notice.showNow", "Show Now") }
            /// The countdown's accessibility value: "5 seconds".
            static func seconds(_ count: Int) -> String {
                count == 1 ? tr("triggers.notice.seconds.one", "1 second") : tr("triggers.notice.seconds.other", "%ld seconds", count)
            }
            /// What VoiceOver says when the notice appears.
            static func announcement(_ title: String, _ detail: String) -> String {
                tr("triggers.notice.announcement", "%1$@. %2$@.", title, detail)
            }
        }

        enum GroupWindow {
            static var section: String { tr("groupWindow.triggers.section", "Triggers") }
            static var empty: String {
                tr("groupWindow.triggers.empty", "No triggers. A trigger starts, opens or shows this group when something happens.")
            }
            static var add: String { tr("groupWindow.triggers.add", "Add Trigger…") }
            static var edit: String { tr("groupWindow.triggers.edit", "Edit…") }
            static var remove: String { tr("groupWindow.triggers.remove", "Remove") }
            static var cantEdit: String {
                tr("groupWindow.triggers.cantEdit", "This version can't edit this kind of trigger; you can turn it off or remove it.")
            }
            static var toggleHelp: String { tr("groupWindow.triggers.toggle.help", "Turn this trigger on or off") }
            static func footer(_ appName: String) -> String {
                tr("groupWindow.triggers.footer", "Triggers run while %@ is open. They never quit apps.", appName)
            }
            static var loginItemOff: String { tr("groupWindow.triggers.loginItemOff", "Open at Login is off.") }
            static var turnOn: String { tr("groupWindow.triggers.turnOn", "Turn On…") }
            static var paused: String { tr("groupWindow.triggers.paused", "Triggers are paused: none of them runs now.") }
            static var archived: String { tr("groupWindow.triggers.archived", "Doesn't run while the group is archived.") }
            static var waitingForLocation: String { tr("groupWindow.triggers.waitingForLocation", "Waiting for Location access.") }
            static var vpnNotWatched: String {
                tr("groupWindow.triggers.vpnNotWatched", "Doesn't run in this version: macOS doesn't tell reliably when a VPN connects.")
            }
            /// The archived group's summary.
            static func archivedCount(_ count: Int) -> String {
                count == 1
                    ? tr("groupWindow.triggers.archivedCount.one", "1 trigger (it doesn't run while the group is archived)")
                    : tr("groupWindow.triggers.archivedCount.other", "%ld triggers (they don't run while the group is archived)", count)
            }
        }

        enum Settings {
            static var tab: String { tr("settings.triggers.tab", "Triggers") }
            static var openAtLogin: String { tr("settings.triggers.openAtLogin", "Open at Login") }
            static func openAtLoginDetail(_ appName: String) -> String {
                tr("settings.triggers.openAtLogin.detail", "Opens %@ when you log in, so At Login and other triggers can run.", appName)
            }
            static var needsApproval: String { tr("settings.triggers.openAtLogin.approval", "macOS needs your approval in Login Items.") }
            static var openLoginItems: String { tr("settings.triggers.openAtLogin.settings", "Open Login Items Settings…") }
            static func loginItemFailed(_ reason: String) -> String {
                tr("settings.triggers.openAtLogin.failed", "macOS didn't change Open at Login: %@", reason)
            }
            static var status: String { tr("settings.triggers.status", "Status") }
            static var running: String { tr("settings.triggers.status.running", "Running") }
            static func pausedUntil(_ date: String) -> String { tr("settings.triggers.status.pausedUntil", "Paused until %@", date) }
            static var pausedIndefinitely: String { tr("settings.triggers.status.pausedIndefinitely", "Paused until you resume them") }
            static var pause: String { tr("settings.triggers.pause", "Pause") }
            static var resume: String { tr("settings.triggers.resume", "Resume") }
            static var location: String { tr("settings.triggers.location", "Location Access") }
            static var locationAllowed: String { tr("settings.triggers.location.allowed", "Allowed") }
            static var locationNotDetermined: String { tr("settings.triggers.location.notDetermined", "Not asked yet") }
            static var locationDenied: String {
                tr("settings.triggers.location.denied", "Not allowed: Wi-Fi triggers can't see network names.")
            }
            static var locationRestricted: String { tr("settings.triggers.location.restricted", "Not available on this Mac") }
            static var locationServicesOff: String {
                tr("settings.triggers.location.servicesOff", "Location Services is off: Wi-Fi triggers can't see network names.")
            }
            static var locationHint: String {
                tr(
                    "settings.triggers.location.hint",
                    "Only triggers that wait for a Wi-Fi network need it: macOS shows network names only to apps allowed to use Location Services. You're asked only when you click Allow… in such a trigger, and the app reads the network's name, never your location."
                )
            }
            static var openPrivacySettings: String { tr("settings.triggers.location.openSettings", "Open Privacy Settings…") }
            static var listHeader: String { tr("settings.triggers.list", "All Triggers") }
            static var listEmpty: String { tr("settings.triggers.list.empty", "No triggers yet. Add them in a group's settings in the group window.") }
            static var showInGroupWindow: String { tr("settings.triggers.showInGroupWindow", "Show in Group Window…") }
            static func footer(_ appName: String) -> String {
                tr(
                    "settings.triggers.footer",
                    "Triggers run while %@ is open. When it's quit, the Shortcuts app's automations can still start a group (macOS 26 and later): in Shortcuts, Automation → Time of Day → Start Group.",
                    appName
                )
            }
        }

        enum MenuBar {
            static var pause: String { tr("menuBar.triggers.pause", "Pause Triggers") }
            static var forOneHour: String { tr("menuBar.triggers.pause.oneHour", "For 1 Hour") }
            static var untilTomorrow: String { tr("menuBar.triggers.pause.untilTomorrow", "Until Tomorrow") }
            static var untilResumed: String { tr("menuBar.triggers.pause.untilResumed", "Until I Resume Them") }
            static var resume: String { tr("menuBar.triggers.resume", "Resume Triggers") }
            static func pausedUntil(_ date: String) -> String { tr("menuBar.triggers.pausedUntil", "Triggers paused until %@", date) }
            static var pausedIndefinitely: String { tr("menuBar.triggers.pausedIndefinitely", "Triggers paused until you resume them") }
            static func quitTooltip(_ appName: String) -> String {
                tr("menuBar.triggers.quitTooltip", "Triggers don't run while %@ is quit.", appName)
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
