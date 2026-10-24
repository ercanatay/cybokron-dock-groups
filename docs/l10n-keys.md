# Localization keys

Every user-facing string of the app, by key, with its English text — the content of
[`Resources/en.lproj/Localizable.strings`](../Resources/en.lproj/Localizable.strings). Translations
live in `Resources/<language>.lproj/Localizable.strings` and must have exactly these keys, with the
same placeholders (`LocalizationTests` check both). Sections still marked *English
only for now* are exempt until translated (the app shows the English text instead), and
`LocalizationTests.awaitingTranslation` lists their key prefixes; every other key is translated in
every language.

- `%@` is text and `%ld` a number; `%1$@`, `%2$ld` … are numbered so a translation can reorder them.
- Keys ending in `.one` / `.other` are the singular (count 1) and plural text of a count.
- Keep as they are: the app name *Cybokron Dock Groups*, *DockGroups*, *GitHub*, *Siri*, key symbols
  (⌘ ⌥ ⇧ ⌃ ↩ ⌫ esc), file names and `?mode=force`.
- `core.invocation.*.phrase` are Siri phrases: translate them exactly as the App Shortcuts phrases
  of the same language (App Intents localization), or Siri won't recognize what Settings shows.

665 keys.

## Shared: buttons, menu items and phrases used in several places

| Key | English |
| --- | --- |
| `common.ok` | OK |
| `common.cancel` | Cancel |
| `common.add` | Add |
| `common.copy` | Copy |
| `common.copied` | Copied |
| `common.close` | Close |
| `common.done` | Done |
| `common.install` | Install |
| `common.tryAgain` | Try Again |
| `common.openAll` | Open All |
| `common.hideAll` | Hide All |
| `common.closeAll` | Close All |
| `common.forceQuit` | Force Quit |
| `common.addApps` | Add Apps… |
| `common.addWebsite` | Add Website… |
| `common.showInFinder` | Show in Finder |
| `common.removeFromGroup` | Remove from Group |
| `common.moveTo` | Move to |
| `common.default` | Default |
| `common.auto` | Auto |
| `common.changelog` | Changelog |
| `common.links` | Links |
| `common.openReleasesPage` | Open Releases Page |
| `common.openPrivacySettings` | Open Privacy & Security… |
| `common.checkForUpdates` | Check for Updates… |
| `common.settings` | Settings… |
| `common.noLaunchesYet` | No launches tracked yet |
| `common.about` | About %@ |
| `common.hideApp` | Hide %@ |
| `common.quitApp` | Quit %@ |
| `common.versionShort` | v%@ |
| `common.update.installing` | Installing version %@… |
| `common.update.restarting` | Installed version %@ — restarting… |
| `common.appCount.one` | 1 app |
| `common.appCount.other` | %ld apps |
| `common.groupCount.one` | 1 group |
| `common.groupCount.other` | %ld groups |

## Menu bar item and its menu

| Key | English |
| --- | --- |
| `menuBar.groupsHeader` | Groups |
| `menuBar.noGroups` | No groups yet |
| `menuBar.manageGroups` | Manage Groups… |
| `menuBar.mostUsed.empty.tooltip` | Open apps as usual; the ones you open most will appear here. |
| `menuBar.mostUsed.show` | Show Most Used |
| `menuBar.mostUsed.show.tooltip` | Show your most opened apps in a popup. |
| `menuBar.checkForUpdates.tooltip` | Look for a newer version of %@ on GitHub. |
| `menuBar.mostUsed.app.tooltip.one` | Open %@. Opened once. |
| `menuBar.mostUsed.app.tooltip.other` | Open %1$@. Opened %2$ld times. |
| `menuBar.group.tooltip` | Show the apps in “%@”. Hold ⌥ to open them all at once, or ⇧⌥ to hide the running ones. |
| `menuBar.group.tooltip.shortcut` | Show the apps in “%1$@”. Hold ⌥ to open them all at once, or ⇧⌥ to hide the running ones. Shortcut: %2$@. |
| `menuBar.group.openAll` | Open All in “%@” |
| `menuBar.group.openAll.tooltip.one` | Open the app in “%@” |
| `menuBar.group.openAll.tooltip.other` | Open all %1$ld apps in “%2$@” |
| `menuBar.group.noApps` | “%@” has no apps yet. |
| `menuBar.group.hideAll` | Hide All in “%@” |
| `menuBar.group.hideAll.tooltip` | Hide the running apps in “%@”. Apps that aren't running stay closed. |

## Main menu (its shortcuts work while a window of the app is active)

| Key | English |
| --- | --- |
| `mainMenu.edit` | Edit |
| `mainMenu.undo` | Undo |
| `mainMenu.redo` | Redo |
| `mainMenu.cut` | Cut |
| `mainMenu.paste` | Paste |
| `mainMenu.selectAll` | Select All |
| `mainMenu.window` | Window |
| `mainMenu.minimize` | Minimize |

## Group popup over the Dock

| Key | English |
| --- | --- |
| `popup.openAll.help.group` | Open every app in this group; running apps come to the front. |
| `popup.openAll.help.mostUsed` | Open every app in this list; running apps come to the front. |
| `popup.hideAll.help.group` | Hide this group's running apps; apps that aren't running stay closed. |
| `popup.hideAll.help.mostUsed` | Hide this list's running apps; apps that aren't running stay closed. |
| `popup.closeAll.help.group` | Quit this group's running apps. ⌘-click to force quit without saving. |
| `popup.closeAll.help.mostUsed` | Quit this list's running apps. ⌘-click to force quit without saving. |
| `popup.summary.running` | %ld running |
| `popup.summary.byLaunches` | by launches |
| `popup.filter.noMatch.hint` | Press Delete or Esc to clear the filter. |
| `popup.empty.mostUsed.hint` | Open apps as usual to start building your history. |
| `popup.footer.sortAZ` | A→Z |
| `popup.footer.sortAZ.help` | Sort the apps in this group by name, A to Z. |
| `popup.footer.sortAZ.accessibility` | Sort A to Z |
| `popup.footer.filter.noMatch` | Filter: “%@”  ·  no match  ·  ⌫ or esc clears |
| `popup.footer.hint.mostUsed` | Ranked by how often you open them  ·  ⌘-click Close All to force quit |
| `popup.footer.hint.group` | Close All:  ⌥-click quits normally  ·  ⌘-click force quits |
| `popup.footer.drag.remove` | Release to remove %@ from this group |
| `popup.footer.drag.free` | Drop %@ on any cell; on another app to swap  ·  drag out to remove |
| `popup.footer.drag.ordered` | Drop to place %@  ·  drag out of the popup to remove it |
| `popup.cell.accessibility.website` | Website %@ |
| `popup.cell.hint.website` | Opens the website in your browser |
| `popup.cell.hint.running` | Brings the app to the front |
| `popup.cell.hint.open` | Opens the app |
| `popup.cell.help.openWebsite` | Open %@ in your browser. |
| `popup.cell.help.bringToFront` | Bring %@ to the front. |
| `popup.cell.help.openApp` | Open %@. |
| `popup.cell.help.missing` | %@ isn't on this Mac. |
| `popup.cell.help.drag.freeItem` | Drag to any cell or onto another item to swap them, or out of the popup to remove it from the group. |
| `popup.cell.help.drag.freeApp` | Drag to any cell or onto another app to swap them, or out of the popup to remove it from the group. |
| `popup.cell.help.drag.ordered` | Drag to reorder, or out of the popup to remove it from the group. |
| `popup.cell.help.drag.missing` | Drag it out of the popup to remove it from the group. |
| `popup.menu.open` | Open |
| `popup.menu.copyURL` | Copy URL |
| `popup.accessibility.moveEarlier` | Move Earlier |
| `popup.accessibility.moveLater` | Move Later |

## Group window (Manage Groups…)

| Key | English |
| --- | --- |
| `groupWindow.empty.noGroups` | No Groups Yet |
| `groupWindow.empty.noSelection` | No Group Selected |
| `groupWindow.empty.noGroups.description` | Add a group to collect apps you use together. |
| `groupWindow.empty.noSelection.description` | Select a group to edit it. |
| `groupWindow.addGroup` | Add a Group |
| `groupWindow.rename.title` | Rename Group |
| `groupWindow.rename.confirm` | Rename |
| `groupWindow.rename.message` | Enter a new name for the group. |
| `groupWindow.delete.title` | Delete “%@”? |
| `groupWindow.delete.confirm` | Delete Group |
| `groupWindow.delete.message.standalone` | This removes the group and its app list, and its own Dock icon. The apps themselves aren't affected. |
| `groupWindow.delete.message` | This removes the group and its app list. The apps themselves aren't affected. |
| `groupWindow.sidebar.rename` | Rename… |
| `groupWindow.sidebar.delete` | Delete… |
| `groupWindow.sidebar.add.help` | Add a group |
| `groupWindow.sidebar.delete.help` | Delete the selected group |
| `groupWindow.addApps.problem.title` | Some apps couldn't be added |
| `groupWindow.section.group` | Group |
| `groupWindow.name` | Name |
| `groupWindow.emoji` | Emoji |
| `groupWindow.emoji.choose` | Choose… |
| `groupWindow.addWebsite.help` | Add a web link to this group. It opens in your default browser. |
| `groupWindow.sortAZ` | Sort A→Z |
| `groupWindow.sortAZ.help` | Sort the apps in this group by name, A to Z. Drag them to reorder by hand. |
| `groupWindow.showPopup` | Show Popup |
| `groupWindow.showPopup.help` | Show this group's popup over the Dock. |
| `groupWindow.hideAll.help` | Hide this group's running apps. Apps that aren't running stay closed. |
| `groupWindow.app.notFound` | Not found on this Mac · %@ |
| `groupWindow.app.remove.website` | Remove %@ from this group. |
| `groupWindow.app.remove` | Remove %@ from this group. The app itself isn't affected. |
| `groupWindow.section.dockTile` | Dock Tile |
| `groupWindow.tile.preview` | Preview |
| `groupWindow.tile.shows` | Shows |
| `groupWindow.tile.kind.grid` | App Icon Grid |
| `groupWindow.tile.background` | Background |
| `groupWindow.tile.backgroundColor` | Background Color |
| `groupWindow.tile.pinned` | Keep the tile pinned in the Dock |
| `groupWindow.tile.preview.accessibility` | Tile preview, %ld points |
| `groupWindow.section.standalone` | Standalone |
| `groupWindow.standalone.toggle` | Standalone Dock icon |
| `groupWindow.standalone.help` | Give this group its own app, with its own icon in the Dock. |
| `groupWindow.standalone.settingUp` | Setting up the Dock icon… |
| `groupWindow.standalone.removing` | Removing the Dock icon… |
| `groupWindow.standalone.groupApp` | Group App |
| `groupWindow.standalone.updateDockIcon` | Update Dock Icon |
| `groupWindow.standalone.updateDockIcon.help` | Restart the Dock with a fresh icon cache, so the tile shows the group's current icon. |
| `groupWindow.standalone.staleIcon` | The Dock still shows the previous icon. |
| `groupWindow.standalone.footer` | Gives the group its own small app, with the tile above as its icon, at the end of the Dock. Clicking it shows the group's popup (⌥-click opens all of its apps), even while %@ isn't running; right-clicking it lists the group's apps (Settings → Popup). Turning this off, deleting the group or dragging the icon out of the Dock removes that app. Adding or removing the icon restarts the Dock for a moment. |
| `groupWindow.section.popup` | Popup |
| `groupWindow.popup.columns` | Columns |
| `groupWindow.popup.maxRows` | Maximum Rows |
| `groupWindow.popup.appNames` | App Names |
| `groupWindow.popup.show` | Show |
| `groupWindow.popup.hide` | Hide |
| `groupWindow.popup.position` | Position |
| `groupWindow.popup.footer` | “%@” follows the app-wide popup settings. |

## Picker choices

| Key | English |
| --- | --- |
| `choice.tileBackground.solid` | Solid |
| `choice.tileBackground.gradient` | Gradient |
| `choice.tileBackground.glass` | Glass |
| `choice.popupAnchor.dockCenter` | Centered Over the Dock |
| `choice.popupAnchor.dockIcon` | Above the Clicked Icon |
| `choice.theme.dark` | Dark |
| `choice.theme.light` | Light |
| `choice.theme.system` | Match System |

## Add Website sheet and window

| Key | English |
| --- | --- |
| `addWebsite.windowTitle` | Add Website |
| `addWebsite.title` | Add Website to “%@” |
| `addWebsite.address` | Address: |
| `addWebsite.address.accessibility` | Website address |
| `addWebsite.name` | Name: |
| `addWebsite.name.accessibility` | Website name, optional |
| `addWebsite.name.placeholder` | Optional |
| `addWebsite.hint` | Opens in your default browser. Leave the name empty to use the site's address. |
| `addWebsite.duplicate` | “%@” is already in this group. |

## Add Apps open panel

| Key | English |
| --- | --- |
| `appPicker.title` | Add Apps to Group |
| `appPicker.message` | Choose the apps to add to “%@”. |

## Alerts about apps that could not be opened, quit or hidden

| Key | English |
| --- | --- |
| `problems.launch.item` | • %1$@: %2$@ |
| `problems.launch.notFound` | not found on this Mac. |
| `problems.launch.opened` | opened. |
| `problems.quit.force` | Some apps in “%@” couldn't be force quit. |
| `problems.quit.graceful` | Some apps in “%@” couldn't be asked to quit. |
| `problems.hide` | Some apps in “%@” couldn't be hidden. |
| `problems.standalone.failed` | “%@” couldn't get its own Dock icon. |

## A standalone group's own app

| Key | English |
| --- | --- |
| `agent.damaged.title` | This group's app can't open its group. |
| `agent.damaged.message` | %1$@<br><br>In %2$@, turn Standalone off and on again for the group to rebuild its app. |
| `agent.error.groupMismatch` | The app's settings belong to another group. |

## Accessibility access

| Key | English |
| --- | --- |
| `accessibility.staleEntryHint` | Already switched on? After an update the entry may belong to the previous version: select %@, remove it with −, then add the app again with +. |

## Settings window

| Key | English |
| --- | --- |
| `settings.window.title` | Settings |

## Settings tabs

| Key | English |
| --- | --- |
| `settings.tab.popup` | Popup |
| `settings.tab.shortcuts` | Shortcuts & Siri |
| `settings.tab.updates` | Updates |
| `settings.tab.backup` | Backup |

## Settings → Language (at the top of the Popup tab)

`%1$@` in `general.language.system` is the name, in itself, of the language the system settings give
the app ("System (Türkçe)"); the other choices are language names in themselves and aren't translated.

| Key | English |
| --- | --- |
| `general.language` | Language |
| `general.language.system` | System (%1$@) |
| `general.language.restartNote` | The new language takes effect after the app restarts. |
| `general.language.restartNow` | Restart Now |

## Settings → Popup

| Key | English |
| --- | --- |
| `settings.popup.theme` | Theme |
| `settings.popup.frostedGlass` | Frosted glass background |
| `settings.popup.appearance.header` | Popup Appearance |
| `settings.popup.appearance.footer` | The theme applies to the popup only; this window follows your macOS appearance. |
| `settings.popup.columns` | Columns |
| `settings.popup.columns.detail` | Auto keeps the standard popup width; a number makes the popup only as wide as the group needs. |
| `settings.popup.maxRows` | Maximum rows |
| `settings.popup.maxRows.detail` | Limits the popup's height; larger groups scroll. |
| `settings.popup.showNames` | Show app names |
| `settings.popup.position` | Position |
| `settings.popup.position.detail` | Above the clicked icon opens a popup over its group's Dock icon, or under the menu bar icon when chosen from its menu. Popups opened with a shortcut, a link or Siri stay centered over the Dock. |
| `settings.popup.layout.header` | Popup Layout |
| `settings.popup.layout.footer` | These are the defaults for every group. Each group can override them under Manage Groups. |
| `settings.popup.freeLayout` | Free layout |
| `settings.popup.freeLayout.detail` | Apps stay in the cell you drag them to, and the others don't move; dropping an app on another swaps the two. |
| `settings.popup.arranging.header` | Arranging Apps |
| `settings.popup.arranging.footer` | Off, a group's apps fill the popup in order and make room when you move one. A→Z in the popup sorts a group by name either way. |
| `settings.popup.restoreWindows` | Restore windows when reopening an app that is running |
| `settings.popup.restoreWindows.detail` | Clicking a running app brings back its hidden and minimized windows, as clicking it in the Dock does. Off, the app only comes to the front. |
| `settings.popup.runningApps.header` | Running Apps |
| `settings.popup.dockMenus` | Menu on group Dock icons |
| `settings.popup.dockMenus.detail` | Right-click a standalone group's Dock icon for its apps, Open All, Hide All and Close All, once the icon was clicked. Its app then shows as running in the Dock and in ⌘-Tab. |
| `settings.popup.standaloneIcons.header` | Standalone Dock Icons |
| `settings.popup.ax.granted` | Accessibility access granted: minimized windows come back too |
| `settings.popup.ax.required` | Restoring minimized windows requires Accessibility access |
| `settings.popup.ax.detail` | Allow %@ under Privacy & Security → Accessibility. Until then, hidden apps still come back, and apps are asked to reopen as from the Dock. Standalone group icons need the access for their own apps. |

## Settings → Shortcuts & Siri

| Key | English |
| --- | --- |
| `settings.shortcuts.enable` | Open group popups with keyboard shortcuts |
| `settings.shortcuts.modifiers` | Modifier keys |
| `settings.shortcuts.keys` | Shortcut keys |
| `settings.shortcuts.keys.detail` | Hold these keys and press 1 for the first group, 2 for the second, and so on. Press it again to close the popup. |
| `settings.shortcuts.header` | Keyboard Shortcuts |
| `settings.shortcuts.ax.granted` | Works in every app |
| `settings.shortcuts.ax.needed` | Needs Accessibility access |
| `settings.shortcuts.ax.detail` | To notice the shortcuts while you work in other apps, allow %@ under Privacy & Security → Accessibility. Until then they work only while its popup or a window of it is active. |
| `settings.shortcuts.noGroups` | No groups yet. |
| `settings.shortcuts.assigned.header` | Assigned Groups |
| `settings.shortcuts.assigned.footer.limit` | Only the first nine groups have shortcuts. Drag groups in Manage Groups to change the order. |
| `settings.shortcuts.assigned.footer` | Shortcuts follow the order of the groups in Manage Groups. |
| `settings.shortcuts.siri.group` | Group |
| `settings.shortcuts.siri.quoted` | “%@” |
| `settings.shortcuts.siri.noGroups` | Add a group to see what to ask Siri for it. |
| `settings.shortcuts.openShortcuts` | Open Shortcuts |
| `settings.shortcuts.shortcutsApp` | Shortcuts app |
| `settings.shortcuts.shortcutsApp.detail` | Launch Group, Quit Group and Show Group are actions there and in Spotlight: add them to your own shortcuts, with your own trigger. |
| `settings.shortcuts.siri.header` | Siri and Shortcuts |
| `settings.shortcuts.siri.footer` | Ask Siri with these words, by voice or by typing. They use the group's current name; shortcuts you build keep working after a rename. |
| `settings.shortcuts.links.noGroups` | Add a group to see its links. |
| `settings.shortcuts.links.footer` | Open a link from a script or another app, e.g. with `open` in Terminal. A group is named by its name (case, accents and punctuation don't matter) or, when the name is ambiguous, its ID. Add ?mode=force to a quit link to force quit. |
| `settings.shortcuts.copy.help` | Copy “%@” to the clipboard. |

## Settings → Most Used

| Key | English |
| --- | --- |
| `settings.mostUsed.show` | Show Most Used in the menu bar |
| `settings.mostUsed.appsShown` | Apps shown |
| `settings.mostUsed.appsShown.detail` | The most opened apps, in the menu and in the Most Used popup. |
| `settings.mostUsed.sessionLength` | Session length |
| `settings.mostUsed.together` | Opened together within |
| `settings.mostUsed.together.detail` | Apps opened within this time of each other count as used together, which moves them up a little. |
| `settings.mostUsed.footer.recording` | Apps are ranked by how often you open them, from the Dock, Finder, Spotlight or a group. Launches are counted only while Most Used is shown; turning it off keeps the history. |
| `settings.mostUsed.recorded` | Recorded |
| `settings.mostUsed.clear` | Clear History… |
| `settings.mostUsed.history` | History |
| `settings.mostUsed.history.detail` | Stored on this Mac only, in usage-stats.json and usage-cooccurrence.json in Application Support. |
| `settings.mostUsed.usageHistory.header` | Usage History |
| `settings.mostUsed.clear.confirm.title` | Clear the usage history? |
| `settings.mostUsed.clear.confirm.button` | Clear History |
| `settings.mostUsed.clear.confirm.message` | The Most Used list starts over. Your groups and apps aren't affected. |
| `settings.mostUsed.summary.none` | No launches yet |
| `settings.mostUsed.summary.launches.one` | 1 launch |
| `settings.mostUsed.summary.launches.other` | %ld launches |
| `settings.mostUsed.summary` | %1$@ of %2$@ |

## Settings → Updates

| Key | English |
| --- | --- |
| `settings.updates.automatic` | Automatically check for updates |
| `settings.updates.currentVersion` | Current version |
| `settings.updates.lastChecked` | Last checked |
| `settings.updates.checkNow` | Check Now |
| `settings.updates.otherVersions` | Other Versions… |
| `settings.updates.footer` | Checks the project's GitHub releases at launch and every 6 hours; only the app's version number is sent along. A new version is installed only after you choose Download and Install. Other Versions… installs any published release, older or newer; going back skips the newer ones in automatic checks. |
| `settings.updates.viewChangelog` | View Changelog |
| `settings.updates.latestPath` | Back on the latest path: every newer release is offered |
| `settings.updates.skipped` | Skipped newer versions: %@ |
| `settings.updates.clear` | Clear |
| `settings.updates.clear.help` | Let automatic checks offer these versions again |
| `settings.updates.never` | Never |
| `settings.updates.status.idle` | Not checked since the app started |
| `settings.updates.status.checking` | Checking… |
| `settings.updates.status.upToDate` | You're up to date (v%@) |
| `settings.updates.status.available` | Version %@ is available |
| `settings.updates.showUpdate` | Show Update… |

## Settings → Updates → Other Versions…

| Key | English |
| --- | --- |
| `settings.otherVersions.title` | Other Versions |
| `settings.otherVersions.intro` | Install any published release of %@, older or newer. The app quits and reopens as the version you pick. |
| `settings.otherVersions.releasesLink` | Open Releases Page on GitHub |
| `settings.otherVersions.loading` | Loading releases from GitHub… |
| `settings.otherVersions.none` | GitHub lists no published releases. |
| `settings.otherVersions.current` | Current |
| `settings.otherVersions.noDownload` | No download |
| `settings.otherVersions.install.help` | Install version %@ |
| `settings.otherVersions.install.noImage` | This release has no disk image to install from. |
| `settings.otherVersions.confirm.title` | Install version %@? |
| `settings.otherVersions.confirm.quits` | %1$@ quits and reopens as version %2$@. |
| `settings.otherVersions.confirm.cantUpdate` | Version %@ can't update itself: to come back, download a newer version from the releases page. |
| `settings.otherVersions.confirm.skips` | Automatic checks then skip the newer versions (%@); Check for Updates… still offers them. |
| `settings.otherVersions.confirm.older` | An older version may not know about features added since; consider exporting a backup first (Settings → Backup). |
| `settings.otherVersions.confirm.upgrade` | Skipped versions are cleared, so automatic checks offer every newer release again. |

## Settings → Backup

| Key | English |
| --- | --- |
| `settings.backup.export.button` | Export Settings… |
| `settings.backup.export` | Export |
| `settings.backup.export.detail` | Saves your groups and settings to a .dockgroups file. |
| `settings.backup.import.button` | Import Settings… |
| `settings.backup.import` | Import |
| `settings.backup.import.detail` | Replaces your groups and settings with the ones in a backup file, or merges the backup's new groups into yours. |
| `settings.backup.footer` | The backup holds your groups, their apps and every setting. Most Used launch counts aren't included. The file stays wherever you save it. |
| `settings.backup.status.exported` | Exported to “%@” |
| `settings.backup.status.restored` | Restored %1$@ with %2$@ |
| `settings.backup.status.merged` | Merged %@ from the backup |
| `settings.backup.status.mergedSkipped` | Merged %1$@ from the backup; %2$ld already here |
| `settings.backup.exportPanel.title` | Export Settings |
| `settings.backup.exportPanel.message` | Save your groups and settings to a backup file. |
| `settings.backup.exportFailed` | The settings couldn't be exported |
| `settings.backup.importPanel.title` | Import Settings |
| `settings.backup.importPanel.message` | Choose a %@ backup to restore. |
| `settings.backup.readFailed` | The file couldn't be read |
| `settings.backup.confirm.title` | Import the groups and settings in this backup? |
| `settings.backup.confirm.replaceAll` | Replace All |
| `settings.backup.confirm.merge` | Merge |
| `settings.backup.restoreFailed` | The backup couldn't be restored |
| `settings.backup.restoreFailed.kept` | %@ Your current groups and settings were kept. |
| `settings.backup.mergeFailed` | The backup couldn't be merged |
| `settings.backup.mergeFailed.kept` | %@ Your current groups were kept. |
| `settings.backup.rejected.notABackup` | Choose a .dockgroups file made with Export Settings…. Nothing was changed. |
| `settings.backup.rejected.newer` | Nothing was changed. |
| `settings.backup.confirm.noGroups` | The backup has no groups. |
| `settings.backup.confirm.noGroups.exported` | The backup has no groups, exported %@. |
| `settings.backup.confirm.contents` | The backup has %1$@ with %2$@. |
| `settings.backup.confirm.contents.exported` | The backup has %1$@ with %2$@, exported %3$@. |
| `settings.backup.confirm.replace` | Replace All uses the backup's groups and settings instead of yours. |
| `settings.backup.confirm.replaced.one` | 1 current group with the same name as a group in the backup will be replaced by it. |
| `settings.backup.confirm.replaced.other` | %ld current groups with the same name as a group in the backup will be replaced by it. |
| `settings.backup.confirm.removed.one` | 1 current group not in the backup will be removed. |
| `settings.backup.confirm.removed.other` | %ld current groups not in the backup will be removed. |
| `settings.backup.confirm.replaceSettings` | Your settings (popup, shortcuts, Most Used and updates) will be replaced too. |
| `settings.backup.confirm.merge.nothing` | Merge keeps your groups and settings and adds nothing. |
| `settings.backup.confirm.merge.allHere` | Merge keeps your groups and settings; every group in the backup is already here, so it adds nothing. |
| `settings.backup.confirm.merge.adds` | Merge keeps your groups and settings and adds %1$@ with %2$@ from the backup. |
| `settings.backup.confirm.skipped.one` | 1 group already here (same name) will be skipped. |
| `settings.backup.confirm.skipped.other` | %ld groups already here (same name) will be skipped. |
| `settings.backup.confirm.final` | The Most Used launch counts are kept. A copy of your current files is saved next to them in Application Support. This can't be undone. |

## Settings → Backup → Diagnostics

| Key | English |
| --- | --- |
| `settings.diagnostics.save` | Save to File… |
| `settings.diagnostics.export` | Export Diagnostics |
| `settings.diagnostics.export.detail` | A text report to attach to a GitHub issue or a support request. |
| `settings.diagnostics.header` | Diagnostics |
| `settings.diagnostics.footer` | Lists the app and macOS versions, your Mac's model, where the app is installed, Accessibility access, your settings, update checks, your group names with their app counts, and recent errors. It doesn't list the apps in your groups. Nothing is sent anywhere. |
| `settings.diagnostics.copied` | Diagnostics copied to the clipboard |
| `settings.diagnostics.saved` | Saved to “%@” |
| `settings.diagnostics.failed` | The report couldn't be saved: %@ |
| `settings.diagnostics.panel.title` | Save Diagnostics |
| `settings.diagnostics.panel.message` | Save the diagnostics report as a text file, e.g. to attach to a GitHub issue. |
| `settings.diagnostics.panel.prompt` | Save |

## Settings → Changelog (fully translated)

| Key | English |
| --- | --- |
| `changelog.tab` | Changelog |
| `changelog.currentVersion` | Current version: %@ |
| `changelog.refresh` | Refresh |
| `changelog.refresh.help` | Load the latest release notes from GitHub |
| `changelog.lastUpdated` | Last updated %@ |
| `changelog.header` | Release Notes |
| `changelog.footer` | From the project's GitHub releases. A copy stays on this Mac, so the notes show offline too. |
| `changelog.latest` | Latest |
| `changelog.installed` | Installed |
| `changelog.prerelease` | Pre-release |
| `changelog.noNotes` | No release notes for this version. |
| `changelog.loading` | Loading release notes from GitHub… |
| `changelog.unavailable` | Release notes unavailable |
| `changelog.error.cached` | Could not load release notes — showing cached copy. |
| `changelog.retry` | Click Refresh to try again. |
| `changelog.openRelease` | View on GitHub |

## Software Update window

| Key | English |
| --- | --- |
| `updateWindow.title` | Software Update |
| `updateWindow.checking` | Checking for updates… |
| `updateWindow.upToDate.title` | You're up to date! |
| `updateWindow.upToDate.message` | %1$@ %2$@ is the newest version available. |
| `updateWindow.available.title` | A new version of %@ is available! |
| `updateWindow.available.message` | Version %1$@ is available — you have %2$@. |
| `updateWindow.available.noImage` | This release has no disk image for automatic installation; download it from its release page. |
| `updateWindow.available.question` | Would you like to download and install it now? |
| `updateWindow.skip` | Skip This Version |
| `updateWindow.remindLater` | Remind Me Later |
| `updateWindow.openReleasePage` | Open Release Page |
| `updateWindow.downloadAndInstall` | Download and Install |
| `updateWindow.downloading` | Downloading version %@… |
| `updateWindow.restartsWhenDone` | %@ restarts when it's done. |
| `updateWindow.reopening` | %@ is reopening. |
| `updateWindow.dryRun.title` | Dry run finished |
| `updateWindow.dryRun.message` | Version %1$@ was downloaded, verified and copied to %2$@. Nothing was replaced. |
| `updateWindow.checkFailed` | Couldn't check for updates |
| `updateWindow.installFailed` | Version %@ couldn't be installed |
| `updateWindow.link.releases` | Releases |
| `updateWindow.link.releasePage` | Release Page |
| `updateWindow.releaseNotes` | Release Notes |
| `updateWindow.releaseNotes.none` | This release has no notes. |
| `updateWindow.relaunchFailed` | Version %@ is installed, but the app couldn't restart itself. Quit it and open it again. |

## About window

| Key | English |
| --- | --- |
| `about.section.findMe` | Find Me Online |
| `about.section.support` | Support This Project |
| `about.section.books` | My Books |
| `about.section.software` | My Open Source Software |
| `about.fullList` | Full list at github.com/ercanatay |
| `about.section.blogs` | Medium Blogs |
| `about.icon.accessibility` | %@ icon |
| `about.version` | Version %@ · open source, MIT License |
| `about.website` | Website |
| `about.sourceCode` | Source Code |
| `about.license` | License |
| `about.reportBug` | Found a bug? Open an issue |
| `about.inspiredBy` | Inspired by the functionality of DockGroups. %@ is an independent, original implementation written from scratch; it contains no code or artwork from DockGroups. |
| `about.project.dockGroups` | This app · Dock groups for macOS |
| `about.project.intelComputerUse` | Native macOS desktop automation for Intel Macs via MCP. |
| `about.project.exchangeRate` | PHP/MySQL exchange rate & portfolio tracker with live scrape + GitHub release updates. |
| `about.project.backlinkChecker` | Check anchors, dofollow/nofollow and HTTP statuses of backlinks. |
| `about.project.consentManager` | YOOtheme Pro 5 Consent Manager translations plugin (WordPress.org). |
| `about.project.antigravityUpdater` | Lightweight macOS updater for Antigravity Tools, 21 languages. |
| `about.project.widgetVisibility` | Jetpack-free WP plugin for widget visibility with descendant support. |
| `about.project.forbiddenContent` | Detects forbidden keywords (e.g. 'Casino') in post titles — like a WP audit checker. |

## Siri phrases and link titles shown in Settings → Shortcuts & Siri (keep the phrases identical to the App Shortcuts phrases of the same language)

| Key | English |
| --- | --- |
| `core.invocation.showGroup` | Show Group |
| `core.invocation.showGroup.phrase` | Show %1$@ in %2$@ |
| `core.invocation.launchGroup` | Launch Group |
| `core.invocation.launchGroup.phrase` | Launch %1$@ in %2$@ |
| `core.invocation.quitGroup` | Quit Group |
| `core.invocation.quitGroup.phrase` | Quit %1$@ in %2$@ |
| `core.invocation.showPopup` | Show Popup |
| `core.invocation.openAll` | Open All |
| `core.invocation.hideAll` | Hide All |
| `core.invocation.closeAll` | Close All |

## Messages from the app's core: errors, the Most Used name, the default group name

| Key | English |
| --- | --- |
| `core.launch.noBrowser` | No web browser is set up to open it. |
| `core.launch.notOpened` | The app wasn't opened. |
| `core.group.defaultName` | New Group |
| `core.website.error.empty` | Enter a web address. |
| `core.website.error.invalid` | This isn't a valid web address. |
| `core.website.error.scheme` | Only http and https addresses can be added, not “%@:”. |
| `core.website.error.credentials` | Remove the user name and password from the address. |
| `core.persistence.groups.newer` | The groups file was saved by a newer version of Cybokron Dock Groups (format %ld). |
| `core.backup.error.notABackup` | This file isn't a Cybokron Dock Groups backup. |
| `core.backup.error.newer` | This backup was made with a newer version of Cybokron Dock Groups (backup format %ld). Update the app to restore it. |
| `core.persistence.usage.newer` | The usage statistics were saved by a newer version of Cybokron Dock Groups (format %ld). |
| `core.agent.configuration.newer` | The group's settings were saved by a newer version of Cybokron Dock Groups (format %ld). |
| `core.agent.error.icon` | The group's icon couldn't be drawn. |
| `core.agent.error.bundleWrite` | The group's app couldn't be created: %@ |
| `core.agent.error.toolMissing` | A system tool this needs is missing: %@. |
| `core.agent.error.signing` | macOS requires every app to be code-signed, and signing the group's app failed on this Mac, so nothing was installed. |
| `core.agent.error.registration` | macOS didn't register the group's app: %@ |
| `core.agent.error.hostUnavailable` | Cybokron Dock Groups couldn't read its own executable: %@ |
| `core.agent.error.noExecutable` | The app has no executable. |
| `core.dock.saveFailed` | The Dock's settings couldn't be changed. |
| `core.store.loadFailed.title` | Your groups couldn't be loaded |
| `core.store.loadFailed.kept` | %1$@ Starting with an empty group list. A copy was kept at “%2$@”. |
| `core.store.loadFailed.empty` | %@ Starting with an empty group list. |
| `core.store.loadFailed.suspended` | %@ To protect the existing file, changes won't be saved until the app is restarted. |
| `core.store.saveFailed.title` | Your changes couldn't be saved |
| `core.preferences.saveFailed` | Your settings couldn't be saved: %@ |
| `core.websiteIcon.accessibility` | Website |
| `core.update.check.notHTTP` | The answer wasn't HTTP. |
| `core.update.check.malformed` | The release information from GitHub couldn't be read. |
| `core.update.check.unsupportedTag` | The latest release (“%@”) isn't tagged with a version number. |
| `core.update.check.noRelease` | No release has been published yet. |
| `core.update.check.rateLimited` | GitHub is limiting requests right now. Try again in an hour. |
| `core.update.check.httpStatus` | GitHub answered with HTTP status %ld. |
| `core.update.check.network` | GitHub couldn't be reached: %@ |
| `core.update.check.noVersion` | This copy of the app has no version number, so it can't be compared. |
| `core.update.install.insecureURL` | The update's download address isn't secure (%@). |
| `core.update.install.downloadFailed` | The update couldn't be downloaded: %@ |
| `core.update.install.sizeMismatch` | The downloaded update is incomplete (%1$ld of %2$ld bytes). |
| `core.update.install.checksum` | The downloaded update doesn't match its published checksum, so it wasn't installed. |
| `core.update.install.mountFailed` | The update's disk image couldn't be opened: %@ |
| `core.update.install.appNotFound` | The update's disk image doesn't contain the app. |
| `core.update.install.wrongApp` | The update's disk image contains another app (%@). |
| `core.update.install.versionMismatch` | The downloaded app is version %1$@, but the release is %2$@. |
| `core.update.install.replaceFailed` | The new version couldn't be put in place, so the current one was kept: %@ |
| `core.update.install.rollbackFailed` | The update failed and the previous version couldn't be put back. It's kept at %@. |
| `core.update.location.translocated` | macOS runs this copy from a temporary read-only location. Move the app to your Applications folder, open it from there, and try again. |
| `core.update.location.notFound` | The running app wasn't found at %@. |
| `core.update.location.readOnly` | The app runs from a read-only volume, such as its disk image. Copy it to your Applications folder first. |
| `core.update.location.noPermission` | You don't have permission to replace the app in “%@”. Download the new version from the releases page instead. |
| `core.update.install.noFile` | The server sent no file. |
| `core.update.install.httpStatus` | HTTP status %ld. |
| `core.update.install.copyFailed` | Copying the app failed: %@ |
| `core.mostUsed.name` | Most Used |

## Question a `cybokrondockgroups://quit/…` link asks (fully translated)

| Key | English |
| --- | --- |
| `core.quitConfirmation.title` | All apps in “%@” will be quit. Continue? |
| `core.quitConfirmation.message` | A link opened by another app, a script or a web page asked to quit the running apps of this group. |
| `core.quitConfirmation.force` | Force quit: the apps end right away, and unsaved changes are lost. |
| `core.quitConfirmation.quit` | Quit Apps |
| `core.quitConfirmation.forceQuit` | Force Quit Apps |
| `core.quitConfirmation.cancel` | Cancel |

## Update installation: the downloaded app's code signature (fully translated)

| Key | English |
| --- | --- |
| `core.update.install.invalidSignature` | The downloaded app's code signature isn't valid, so it wasn't installed: %@ |
| `core.update.install.wrongSigner` | The downloaded app is signed by another developer (team %1$@ instead of %2$@), so it wasn't installed. |

## Settings → Updates → Other Versions…, while an update is under way (fully translated)

| Key | English |
| --- | --- |
| `settings.otherVersions.busy.title` | An update is under way |
| `settings.otherVersions.busy.message` | %@ is checking for or installing an update right now. Try again once it's finished. |

## Release notes cut short (fully translated)

| Key | English |
| --- | --- |
| `core.releaseNotes.truncated` | The release notes are longer than shown here; the release page has all of them. |

## Settings → Updates → Other Versions…, a version without the security fixes (fully translated)

| Key | English |
| --- | --- |
| `updates.otherVersions.preSafety.title` | This version lacks security fixes |
| `updates.otherVersions.preSafety.message` | Version %@ was released before important security fixes, such as stricter checks of the updates it installs. Install it only if you need it, and update to the latest version again afterwards. |

## Import Settings…, a file too large to be a backup (fully translated)

| Key | English |
| --- | --- |
| `core.backup.error.tooLarge` | This file is too large to be a Cybokron Dock Groups backup. |

## Group Settings: the popup's gear and the “Group Settings…” item of a group's menus (fully translated)

| Key | English |
| --- | --- |
| `group.settings.title` | Group Settings |
| `group.settings.menu` | Group Settings… |
| `group.settings.accessibilityHint` | Shows the name, apps, Dock tile and popup settings of “%@”. |

## What a group holds, apps and websites alike: the popup's summary line (“8 items · 3 running”) and the group window's group list (fully translated)

`common.appCount` stays for lists of apps only, such as Most Used.

| Key | English |
| --- | --- |
| `common.itemCount.one` | 1 item |
| `common.itemCount.other` | %ld items |

## Settings → Support: the About window's content in Settings (fully translated)

| Key | English |
| --- | --- |
| `settings.support.tab` | Support |

## Settings → Shortcuts & Siri: when the shortcut keys couldn't be registered as hot keys and are watched for instead (fully translated)

| Key | English |
| --- | --- |
| `shortcuts.hotkey.unavailable` | macOS couldn't reserve these keys for the shortcuts, so they're watched for instead: that needs Accessibility access, and the app in front receives the key press too. |

## Group items: files and folders, and why one can't be added, located or opened (English only for now; `awaitingTranslation`: `core.item.`)

| Key | English |
| --- | --- |
| `core.item.error.program` | “%@” is a program or script, so it can't be added as a file. |
| `core.item.error.notOpened` | wasn't opened, because programs and scripts open only as apps. |
| `core.item.error.noHandler` | No app on this Mac opens “%@”. |
| `core.item.error.volume` | It's on “%@”, which isn't connected. |
| `core.item.error.unchecked` | wasn't opened, because macOS didn't allow checking what it is. |
| `core.item.unchecked` | macOS didn't let the app check “%@”. |
| `core.item.locate.wrongKind` | “%@” isn't the same kind of item. |

## Group items in the app: the Items section and its Add menu, Add Files or Folders…, files and folders in the popup and the rows, missing items and Locate…, Quick Look, items that couldn't be opened, backup items left out (English only for now; `awaitingTranslation`: `groupWindow.items.`, `addItems.`, `item.`, `popup.item.`, `settings.backup.leftOut.`)

The group window's section was called “Apps”: `groupWindow.items.section`, `.empty` and `.moveHint`
replace `groupWindow.section.apps`, `groupWindow.apps.empty` and `groupWindow.apps.moveHint`, and
`item.problems.allFailed` / `.someFailed` replace `problems.launch.allFailed` / `.someFailed`
(the old keys are gone from every table).

| Key | English |
| --- | --- |
| `groupWindow.items.section` | Items |
| `groupWindow.items.add` | Add |
| `groupWindow.items.add.help` | Add apps, files, folders or a website to this group. |
| `groupWindow.items.empty` | Nothing here yet. Use “%@” to add apps, files, folders or a web link. |
| `groupWindow.items.moveHint` | To move an item to another group, drag it onto that group in the sidebar, or use %@ in its context menu. |
| `groupWindow.items.remove.file` | Remove %@ from this group. The file itself isn't affected. |
| `groupWindow.items.remove.folder` | Remove %@ from this group. The folder itself isn't affected. |
| `addItems.menu` | Add Files or Folders… |
| `addItems.title` | Add Files and Folders to Group |
| `addItems.message` | Choose files and folders to add to “%@”. Apps you choose are added as apps. |
| `addItems.problem.title` | Some items couldn't be added |
| `item.kind.file.accessibility` | File %@ |
| `item.kind.folder.accessibility` | Folder %@ |
| `item.action.quickLook` | Quick Look |
| `item.action.locate` | Locate… |
| `item.missing.help` | “%@” can't be found. It may have been moved, renamed or deleted. |
| `item.volume.help` | “%1$@” is on “%2$@”, which isn't connected. |
| `item.missing.row` | Can't be found · %@ |
| `item.volume.row` | On “%1$@”, which isn't connected · %2$@ |
| `item.unverified.row` | Can't check this location · %@ |
| `item.locate.message` | Choose where “%@” is now. Its details and place in the group are kept. |
| `item.locate.prompt` | Choose |
| `item.locate.duplicate` | “%@” is already in this group. |
| `item.locate.problem.title` | “%@” couldn't be located there |
| `item.problems.allFailed` | The items in “%@” couldn't be opened. |
| `item.problems.someFailed` | Some items in “%@” couldn't be opened. |
| `popup.item.hint.file` | Opens the file in its default app |
| `popup.item.hint.folder` | Opens the folder in Finder |
| `popup.item.help.openFile` | Open %@ in its default app. |
| `popup.item.help.openFolder` | Open the folder %@. |
| `settings.backup.leftOut.one` | 1 item in the backup was left out: it can't be opened safely. |
| `settings.backup.leftOut.other` | %ld items in the backup were left out: they can't be opened safely. |

## Settings → Updates → Other Versions…, going back to a version without files, folders and item details (English only for now; `awaitingTranslation`: `updates.otherVersions.items.`)

Added to the install question when the groups hold files, folders or items with an alias, tags or
task notes; the groups file is copied aside as `groups.pre-downgrade-<time>.json` either way.

| Key | English |
| --- | --- |
| `updates.otherVersions.items.warning` | Version %@ can't show files, folders, aliases, tags or task notes. A copy of your groups is kept before it's installed; editing groups in that version drops these items' details. |

## An item's alias, tags and task notes: the details editor, Edit Details…, the rows and the popup's tooltips (English only for now; `awaitingTranslation`: `item.details.`, `popup.search.`)

The group window's details editor opens from a row's ⓘ button and from **Edit Details…** in the
row's and the popup's context menus. A row shows an item's alias instead of its name, with
`item.details.originalName` below it; the popup's tooltips end with the same name, the tags and the
start of the notes (`popup.search.help.*`, joined with “ · ”).

| Key | English |
| --- | --- |
| `item.details.menu` | Edit Details… |
| `item.details.title` | Details of “%@” |
| `item.details.alias` | Alias |
| `item.details.alias.placeholder` | Another name, shown instead |
| `item.details.tags` | Tags |
| `item.details.tags.placeholder` | finance, q3 |
| `item.details.tags.hint` | Separate tags with commas. |
| `item.details.tags.limit` | Only the first %ld tags are kept. |
| `item.details.notes` | Task notes |
| `item.details.notes.placeholder` | What you use it for |
| `item.details.notes.count` | %1$ld of %2$ld characters |
| `item.details.button.help` | Alias, tags and task notes of %@ |
| `item.details.originalName` | Name: %@ |
| `item.details.hint` | Typing any of these in the popup finds this item. |
| `popup.search.help.tags` | Tags: %@ |
| `popup.search.help.notes` | Notes: %@ |

## The popup's filter by name, alias, tags and task notes, and an empty group (English only for now; `awaitingTranslation`: `popup.search.`, `item.`)

The popup finds items by name and alias first, then by tags and task notes; the footer says when
the selected item (the best match by default) was found by a tag or its notes. An empty group's
popup offers Add Apps… and Add Files or Folders… (`addItems.menu`), which open their panels in the
group window. `popup.search.footer.matches`, `popup.search.noMatch` and `item.group.empty` replace
`popup.footer.filter.matches`, `popup.filter.noMatch` and `common.noAppsInGroup` (the old keys are
gone from every table).

| Key | English |
| --- | --- |
| `popup.search.footer.matches` | Filter: “%@”  ·  ↩ opens the selected item  ·  esc clears |
| `popup.search.footer.tag` | Filter: “%1$@”  ·  tag “%2$@” of %3$@  ·  ↩ opens it  ·  esc clears |
| `popup.search.footer.notes` | Filter: “%1$@”  ·  in the task notes of %2$@  ·  ↩ opens it  ·  esc clears |
| `popup.search.noMatch` | No items match “%@” |
| `item.group.empty` | No items in this group yet |

## Starting or finishing a group from a link, Siri or Shortcuts when it would quit apps: the question asked first; an item not opened with the app chosen for it (English only for now; `awaitingTranslation`: `core.switching.`)

The buttons reuse `core.quitConfirmation.quit` (Quit Apps) and `core.quitConfirmation.cancel`
(Cancel). Siri and Shortcuts show the title and the detail.

| Key | English |
| --- | --- |
| `core.switching.start.title.one` | Switch to “%@” and quit 1 app? |
| `core.switching.start.title.other` | Switch to “%1$@” and quit %2$ld apps? |
| `core.switching.start.detail` | “%1$@” is set to quit the apps of “%2$@” it doesn't use: %3$@. |
| `core.switching.finish.title.one` | Finish “%@” and quit 1 app? |
| `core.switching.finish.title.other` | Finish “%1$@” and quit %2$ld apps? |
| `core.switching.finish.detail` | Finishing “%1$@” quits %2$@. Protected apps stay open. |
| `core.switching.finish.detailWithNext` | Finishing “%1$@” quits %2$@. Protected apps and apps “%3$@” uses stay open. |
| `core.switching.confirmation.link` | A link opened by another app, a script or a web page asked for this. |
| `core.switching.confirmation.save` | Apps can still ask to save changes. |
| `core.switching.confirmation.quitAndSwitch` | Quit and Switch |
| `core.switching.confirmation.hideInstead` | Hide Instead |
| `core.switching.opener.refused` | wasn't opened with “%@”, because that app can't open it safely. |

## Start and Finish in the popup: the button, its tooltip (also of the menu bar menu's Start and Finish items and the group window's buttons), VoiceOver's label, the current group's marker (English only for now; `awaitingTranslation`: `popup.switching.`)

The button shows only its symbol (▶ / ■) in popups narrower than the standard width; its tooltip and VoiceOver label stay.

| Key | English |
| --- | --- |
| `popup.switching.current` | current |
| `popup.switching.start` | Start |
| `popup.switching.finish` | Finish |
| `popup.switching.start.accessibility` | Start %@ |
| `popup.switching.finish.accessibility` | Finish %@ |
| `popup.switching.help.start.leave` | Start: open this group's items and leave the other apps as they are. |
| `popup.switching.help.start.hideAll` | Start: open this group's items and hide all other apps. |
| `popup.switching.help.start.alone` | Start: open this group's items and make it the current group. |
| `popup.switching.help.start.quit` | Start: open this group's items and quit the apps of “%@” it doesn't use. |
| `popup.switching.help.start.hide` | Start: open this group's items and hide the apps of “%@”. |
| `popup.switching.help.finish.hide` | Finish: hide this group's apps. |
| `popup.switching.help.finish.hideAndShow` | Finish: hide this group's apps and show “%@” again. |
| `popup.switching.help.finish.quit` | Finish: quit this group's apps. |
| `popup.switching.help.finish.quitAndShow` | Finish: quit this group's apps and show “%@” again. |
| `popup.switching.help.finish.leave` | Finish: leave this group's apps open; it's no longer the current group. |
| `popup.switching.help.finish.leaveAndShow` | Finish: leave this group's apps open and show “%@” again. |

## Start and Finish in the menu bar menu: the current group and Finish above the groups, the ⌃⌥ alternate of each group (English only for now; `awaitingTranslation`: `menuBar.switching.`)

`menuBar.switching.startHint` is added after `menuBar.group.tooltip` (or `.shortcut`).

| Key | English |
| --- | --- |
| `menuBar.switching.current` | Current: %@ |
| `menuBar.switching.current.tooltip` | “%@” is the current group, the one started last. Choose it to show its popup. |
| `menuBar.switching.start` | Start “%@” |
| `menuBar.switching.finish` | Finish “%@” |
| `menuBar.switching.startHint` | Hold ⌃⌥ to start it. |

## Group window → Start and Finish (English only for now; `awaitingTranslation`: `groupWindow.switching.`)

| Key | English |
| --- | --- |
| `groupWindow.switching.section` | Start and Finish |
| `groupWindow.switching.onStart` | When this group starts |
| `groupWindow.switching.onFinish` | When this group finishes |
| `groupWindow.switching.afterFinish` | After finishing |
| `groupWindow.switching.onStart.leaveOthers` | Leave other apps open |
| `groupWindow.switching.onStart.hidePreviousGroup` | Hide the previous group's apps |
| `groupWindow.switching.onStart.hideAllOtherApps` | Hide all other apps |
| `groupWindow.switching.onStart.quitPreviousGroup` | Quit the previous group's apps |
| `groupWindow.switching.onFinish.hideApps` | Hide its apps |
| `groupWindow.switching.onFinish.quitApps` | Quit its apps |
| `groupWindow.switching.onFinish.leaveApps` | Leave its apps open |
| `groupWindow.switching.afterFinish.showPreviousGroup` | Show the previous group |
| `groupWindow.switching.afterFinish.nothing` | Do nothing |
| `groupWindow.switching.quitWarning` | Quitting asks apps to quit; they can still ask to save changes. Links, Siri and Shortcuts ask you first. |
| `groupWindow.switching.protectedApps` | Protected Apps… |
| `groupWindow.switching.protectedApps.help` | Choose the apps that are never hidden or quit, in Settings → Switching. |
| `groupWindow.switching.current` | This is the current group. |
| `groupWindow.switching.notCurrent` | Start makes this the current group. |
| `groupWindow.switching.footer` | Start opens the group's items as Open All does and puts the group started before it away; Finish puts this group away. Protected apps, and apps both groups use, are never hidden or quit. |

## Settings → Switching: protected apps, what Start and Finish do, the current group; the alert about apps a transition left as they were (English only for now; `awaitingTranslation`: `settings.tab.switching`, `switching.`)

Add Apps… reuses `common.addApps`, the problem alert `groupWindow.addApps.problem.title`.

| Key | English |
| --- | --- |
| `settings.tab.switching` | Switching |
| `switching.protected.header` | Protected Apps |
| `switching.protected.empty` | No protected apps yet. |
| `switching.protected.addRunning` | Add a Running App |
| `switching.protected.addRunning.none` | No other running apps |
| `switching.protected.remove` | Stop protecting %@ |
| `switching.protected.footer` | Start, Finish and Close All never quit these apps, and switching groups never hides them. %@ and its groups' own apps are always protected, and Finder is never quit. |
| `switching.protected.full` | The list holds at most %ld apps. |
| `switching.protected.picker.title` | Add Protected Apps |
| `switching.protected.picker.message` | Choose apps that Start, Finish and Close All never quit. |
| `switching.start.header` | Start and Finish |
| `switching.start.summary` | Start opens a group's items as Open All does, then puts the group started before it away as the group's settings say: by default its apps are hidden, never quit. Finish hides the group's apps and shows the previous group again. Each group's settings are in its group window. |
| `switching.start.asking` | Links, Siri and Shortcuts ask first when a group is set to quit apps. |
| `switching.start.quitting` | Groups set to quit apps |
| `switching.current.label` | Current group |
| `switching.current.none` | None |
| `switching.current.previous` | Started before it |
| `switching.current.detail` | The current group is the one started last, until it's finished. It's forgotten when %@ quits. |
| `switching.problem.start` | Starting “%@” left some apps as they were. |
| `switching.problem.finish` | Finishing “%@” left some apps as they were. |
| `switching.problem.notHidden` | • %@: couldn't be hidden. |
| `switching.problem.notQuit` | • %@: couldn't be asked to quit. |
| `switching.problem.notShown` | • %@: couldn't be shown again. |

## Settings → Shortcuts & Siri: Start Group and Finish Group, their phrases and links (English only for now; `awaitingTranslation`: `settings.shortcuts.switching.`, `core.invocation.startGroup`, `core.invocation.finishGroup`)

Keep `core.invocation.startGroup.phrase` and `core.invocation.finishGroup.phrase` identical to the first App Shortcuts phrase of Start Group and Finish Group in the same language. The two `settings.shortcuts.switching.` texts follow `settings.shortcuts.shortcutsApp.detail` and `settings.shortcuts.links.footer`.

| Key | English |
| --- | --- |
| `settings.shortcuts.switching.shortcutsApp.detail` | Start Group and Finish Group are there too. Nobody answers questions in an automation, so for groups you start or finish there, choose hiding rather than quitting. |
| `settings.shortcuts.switching.links.footer` | Start and finish links share the 5-second limit of launch and hide links, and ask first when the group is set to quit apps. |
| `core.invocation.startGroup` | Start Group |
| `core.invocation.startGroup.phrase` | Start %1$@ in %2$@ |
| `core.invocation.finishGroup` | Finish Group |
| `core.invocation.finishGroup.phrase` | Finish %1$@ in %2$@ |
| `core.invocation.startGroup.link` | Start |
| `core.invocation.finishGroup.link` | Finish |

## An item's launch options: the details editor's Opening part, Other…'s open panel and why an app isn't taken, the rows' captions and the popup's tooltips (English only for now; `awaitingTranslation`: `item.launch.`)

`item.launch.delay.one` / `.other` are the delay menu's choices (`.none` is 0); `item.launch.help.delay.*` the popup's tooltip sentence. The rows' captions join their parts with “ · ” (`item.launch.row.delayAfterOpener` follows an app's name).

| Key | English |
| --- | --- |
| `item.launch.section` | Opening |
| `item.launch.openWith` | Open with |
| `item.launch.defaultApp` | Default App |
| `item.launch.defaultApp.named` | Default App (%@) |
| `item.launch.otherApp` | Other… |
| `item.launch.choice.notOnThisMac` | %@ (not on this Mac) |
| `item.launch.choice.refused` | %@ (can't open it) |
| `item.launch.delay` | Delay |
| `item.launch.delay.none` | None |
| `item.launch.delay.one` | 1 second |
| `item.launch.delay.other` | %ld seconds |
| `item.launch.delay.hint` | Open All and Start wait this long; clicking the item opens it right away. |
| `item.launch.picker.title` | Choose an App |
| `item.launch.picker.message` | Choose the app that opens “%@”. |
| `item.launch.picker.prompt` | Choose |
| `item.launch.help.openWith` | Open %1$@ with %2$@. |
| `item.launch.hint.openWith` | Opens it with %@ |
| `item.launch.help.delay.one` | Open All and Start open it after 1 second. |
| `item.launch.help.delay.other` | Open All and Start open it after %ld seconds. |
| `item.launch.status.notOnThisMac` | “%@” isn't on this Mac: the item opens with its default app. |
| `item.launch.status.refused` | “%@” can't open this item safely, so the item won't open. Choose another app. |
| `item.launch.refusal.notAnApp` | “%@” isn't an app that can open items. |
| `item.launch.refusal.unknown` | macOS doesn't know “%@” yet. Open it once, then choose it again. |
| `item.launch.refusal.runsItems` | “%@” runs what it opens, so it can't open this item. |
| `item.launch.refusal.notListed` | “%@” isn't one of the apps macOS lists for this item. |
| `item.launch.row.openerMissing` | Opens with %@ (not on this Mac: uses the default app) |
| `item.launch.row.opener` | Opens with %@ |
| `item.launch.row.delay` | After %ld s |
| `item.launch.row.delayAfterOpener` | after %ld s |

## Import Settings…: items whose chosen app was dropped because it runs what it opens (English only for now; `awaitingTranslation`: `settings.backup.launchReset.`)

Added after `settings.backup.confirm.contents` (and `settings.backup.leftOut.*`).

| Key | English |
| --- | --- |
| `settings.backup.launchReset.one` | The launch settings of 1 item were reset: they named an app that runs files. |
| `settings.backup.launchReset.other` | The launch settings of %ld items were reset: they named apps that run files. |
