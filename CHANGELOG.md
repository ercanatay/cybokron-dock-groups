# Changelog

All notable changes to Cybokron Dock Groups are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.5.6] - 2026-10-18

### Added

- **Other Versions…** in Settings → Updates: lists the project's published GitHub releases (no
  drafts or prereleases), newest first, with their dates; the running one is marked *Current*. Each
  other release has **Install** (disabled with "No download" when it has no universal DMG), which
  asks first, then downloads, checks and installs it in the update window exactly like an update —
  older or newer — and relaunches. When the list can't be loaded (offline, GitHub's rate limit) it
  says why, with **Try Again** and a link to the releases page.
- Going back to an older version skips every newer published release (and the one left behind) in
  automatic checks, so the app doesn't keep offering what you just left; **Check for Updates…**
  still offers them. Going up from Other Versions… clears the skipped versions. Settings → Updates
  shows them ("Skipped newer versions: …", with **Clear**) or "Back on the latest path".

### Changed

- `update-state.json` keeps a list of skipped versions (`skippedVersions`); the newest is also
  written as `skippedVersion`, the key versions up to 0.5.5 read, so an older version installed
  from Other Versions… keeps quiet about the newest release too. The diagnostics report lists them.

## [0.5.5] - 2026-10-18

### Added

- **Quick Look in the popup**: with an app selected (arrow keys) and nothing typed, Space shows its
  Finder preview — name, version, size — and the preview follows the selection; Space again or
  Escape closes it (Escape then clears the filter, then closes the popup), and closing the popup
  closes it too. While typing a filter, Space is still a space. Websites and missing apps have no
  preview: Space does nothing for them.
- **Websites in groups**: **Add Website…** in the group window, or in the popup's context menu,
  adds a web link (`https://` is added when left out, broken addresses are refused, the name
  defaults to the host). It shows as a globe, opens in the default browser on click or Return, and
  Open All opens a group's websites together; Close All and Hide All, the running indicators and
  Most Used leave them out. A website can be moved, reordered, sorted A→Z with the apps and removed
  like an app, is in a group once (but may be in several groups), and is kept in backups. The
  popup's context menu also has **Open**, **Copy URL** (websites) or **Show in Finder** (apps), and
  **Remove from Group**.

## [0.5.4] - 2026-10-18

### Added

- **Keyboard navigation in the popup**: the arrow keys move a selection through the grid (stopping
  at the edges, scrolling it into view, skipping empty Free Layout cells), Return opens the selected
  app exactly as clicking it does (running apps come to the front; launches count for Most Used),
  Tab / ⇧Tab switch to the next / previous group in the menu bar menu's order (Most Used last), and
  Escape still closes the popup.
- **Type-to-filter in the popup**: typing letters or digits narrows the grid to the apps whose name
  matches — case and accents ignored (`c` finds “Ç…”, `i` finds “ı”), names starting with the text
  first, then names with a word starting with it, then the rest. Return opens the selected (by
  default the best) match, Delete removes the last letter, Escape clears the filter, and when nothing
  matches the popup says so. The popup keeps its size and position while filtering.
- **Export Diagnostics** in Settings → Backup: **Copy** puts a plain-text report on the clipboard
  ("Copied" for a moment), **Save to File…** saves it as a .txt. It lists the app version and build,
  macOS and the Mac's model, where the app is installed, Accessibility access, the popup and other
  settings, the last update check and its result, the group names with their app counts (no app
  names or paths), and the latest errors the app logged (with the home folder shortened to `~`).

### Fixed

- The About window's "Find Me Online" buttons showed no icons: their SVG path data was handed to
  SwiftUI's `Path(String)`, which only reads its own path description format and returned nothing.
  The glyphs are now parsed by an SVG path parser of their own (all SVG path commands, arcs
  included) and drawn in every build; a glyph that can't be read shows a globe instead of an empty
  button.
- The Accessibility status in Settings → Popup (*Restore windows…*) and Settings → Shortcuts & Siri
  turns green as soon as access is granted: one shared monitor reads the access again when the app
  becomes active (coming back from System Settings), when macOS announces an Accessibility change,
  when the status appears, and every second while access is missing — and stops polling once it's
  granted. The warning also explains how to replace an entry left by an earlier ad hoc signed
  version, which stays switched on without granting access to the new one.

## [0.5.3] - 2026-10-18

### Added

- The About window shows a "Find Me Online" row with social profile icons (LinkedIn, X, Instagram,
  YouTube, TikTok, Threads, Pinterest, Steam, WordPress.org, GitHub, Medium, Facebook, Vimeo,
  Flickr, Ekşi Sözlük, Wikipedia).
- **Hide All** hides a group's running apps (apps that aren't running stay closed): in the popup
  next to Open All and Close All, with ⇧⌥ in the menu bar menu, in the group window and a group's
  context menu, and as `cybokrondockgroups://hide/<group>`.
- **Merge** when importing a backup: adds the backup's groups whose name (or ID) isn't there yet
  after the current ones, leaving the current groups and all settings as they are. The groups file
  is copied aside first, as with Replace All.
- **Dock menu for standalone groups**: right-click (or Control-click) a standalone group's Dock icon
  for its apps — checked while running; choose one to open it or bring it to the front — and Open
  All, Hide All and Close All. The Dock shows the menu once the icon was clicked and the group's app
  runs. Settings → Popup → *Menu on group Dock icons* (on by default) turns it off; while it's on,
  the group's app shows as running in the Dock and in the app switcher (it's still never counted in
  Most Used).
- **Move to**: an app's context menu in the popup and in the group window moves it to another
  group, and so does dragging it from the group window onto a group in the sidebar. It joins the end
  of that group (in Free Layout, the first free cell); a group that already has it keeps just its
  own copy.
- Settings → **Shortcuts & Siri** (was Shortcuts) spells out, for a group you pick, what to ask
  Siri (“Launch Work in Cybokron Dock Groups”, Quit, Show) and its four links, each with a Copy
  button, and opens the Shortcuts app.
- **Popup above the clicked icon**: with Position (Settings → Popup, or a group's own) set to *Above
  the Clicked Icon*, a standalone group's popup opens centered above its Dock icon — beside it for a
  left or right Dock, on the display whose Dock was clicked — and a group chosen from the menu bar
  menu hangs 4 points under the menu bar icon. Shortcuts, links, Siri and Show Popup in the group
  window keep the popup centered over the Dock. The tile is found through the Dock's accessibility
  information when the group's app has Accessibility access, else from the clicked point.
- **Restore windows of running apps**: clicking a running app in a popup, the Most Used menu or a
  standalone group's Dock menu brings it back as clicking it in the Dock does: a hidden app
  un-hides, and when all of its windows are minimized they all come back (needs Accessibility
  access; the app asks once, the first time it would help) — otherwise the app is asked to reopen.
  Settings → Popup → *Restore windows when reopening an app that is running* (on by default) turns
  it off, so the app is only brought to the front. Most Used counts this as bringing the app to the
  front, not as a launch.

### Changed

- Settings → Popup → Position *Above the Clicked Icon* no longer centers popups opened from the menu
  bar over the Dock; see above.
- The import confirmation offers **Replace All**, **Merge** and **Cancel**, and explains what each
  would change.
- The popup is at least 440 points wide (was 380), so the group name stays readable next to the
  header buttons.
- The Update window now shows the installation stages: "Installing version X…" while the update
  replaces the app, then "Installed version X — restarting…" with a short "is reopening" note just
  before the app relaunches.

## [0.5.2] - 2026-10-17

### Added

- Developer ID signed and Apple notarized releases: the release workflow signs the
  app and the disk image with the Developer ID Application certificate (hardened runtime, secure
  timestamp), notarizes the disk image with `notarytool`, staples the ticket and checks it with
  `stapler validate`, `codesign` and `spctl` before attaching it to the draft release. Releases open
  without a Gatekeeper warning.
- `CODESIGN_IDENTITY` for `scripts/build-app.sh` and `scripts/make-dmg.sh`: set to a signing
  identity's SHA-1, it signs the app (and the DMG) with that identity instead of ad hoc. Without it,
  builds are signed ad hoc as before.
- Apps without a bundle identifier can now be added to groups; they are identified by their location
  (path), like Half-Life style applets.
- Sort a group's apps A→Z, from the popup bar and the group window.
- Free layout (Settings → Popup): dragged apps stay in their cell or swap with the app already
  there; the slots are remembered per group.
- Export and import of settings as a backup (`.dockgroups` file, `schemaVersion` 1), with an
  automatic safety copy of the current settings before an import.
- The About window links to the website.

### Fixed

- URL scheme commands with several copies of the app installed: only one copy keeps running, and a
  second copy hands the URL to the running app and quits (#4).

### Changed

- The README explains the signed releases and how to open the ad hoc signed v0.5.0 and v0.5.1 the
  first time (Privacy & Security → Open Anyway, or `xattr -dr com.apple.quarantine`).
- Accessibility access needs to be allowed once more when moving from an ad hoc signed build to a
  signed release; afterwards it carries over between signed releases.

## [0.5.1] - 2026-10-17

### Added

- Built-in updates from GitHub Releases, without third-party frameworks:
  - **Check for Updates…** in the menu bar menu and the app menu opens a small update window that
    shows the result of the check: up to date, a new version with its release notes, or what went
    wrong.
  - Automatic checks shortly after launch and every 6 hours (and after the Mac wakes up), on by
    default. A newer version brings up the update window with **Download and Install**, **Remind Me
    Later** and **Skip This Version**.
  - **Download and Install** downloads the release's universal disk image, checks its size and
    SHA-256 checksum, mounts it read-only and hidden, copies the app out, moves the running app to
    `updates/backups/` and the new one into its place, and relaunches. If the new version can't be
    put in place or opened, the previous one is put back.
- Settings → **Updates**: the automatic-check switch, **Check Now**, the time of the last check, the
  result inline (“You're up to date (v0.5.1)”), and links to the releases page and this changelog.
- **Changelog** links in the About window and the update window.
- This changelog.

### Changed

- `preferences.json` stores the new `automaticallyChecksForUpdates` setting; the time of the last
  check and a skipped version are kept in `update-state.json`. The update setting isn't copied into
  standalone group apps, so changing it doesn't rebuild them.

## [0.5.0] - 2026-10-17

First public release.

### Added

- Groups of apps managed in a group window: add, rename, reorder and delete groups, add apps with an
  open panel, reorder or remove them. Saved in `groups.json`; an unreadable file is kept aside
  instead of being overwritten.
- Group tiles drawn by the app: the group's emoji or a grid of its first app icons, on a solid,
  gradient or glass background in the color you pick.
- **Open All** opens every app of a group at once (running apps are brought to the front), with a
  report of apps that couldn't be opened; **Close All** quits the group's running apps, ⌘-click
  force quits them.
- Menu bar item listing the groups with their tiles; choosing a group shows its popup, holding ⌥
  opens all of its apps.
- Group popup over the Dock: a grid of the group's apps with a running indicator per app; dark,
  light or system theme, frosted glass, columns, maximum rows, app names and position, with
  per-group overrides. Apps are reordered by dragging and removed by dragging them out.
- Global keyboard shortcuts (⌃⌥1 … ⌃⌥9 by default) that show the first nine groups' popups.
- Siri, Spotlight and Shortcuts actions to launch, quit and show a group, and
  `cybokrondockgroups://` links for the same commands, the settings and the group window.
- **Most Used**: app launches are counted on this Mac and the most opened apps are listed in the
  menu bar and in a popup; Settings sets the list's length and session length and clears the
  history.
- Standalone Dock icons: a group can get its own small app with the group's tile as its Dock icon,
  rebuilt when the group or the app changes and removed (with its Dock tile) when it's turned off or
  deleted.
- Settings window with Popup, Shortcuts and Most Used tabs, and an About window.
- Universal (Apple silicon and Intel) disk image built by `scripts/make-dmg.sh` and attached to a
  draft GitHub release for `v*` tags.

[Unreleased]: https://github.com/ercanatay/cybokron-dock-groups/compare/v0.5.6...HEAD
[0.5.6]: https://github.com/ercanatay/cybokron-dock-groups/compare/v0.5.5...v0.5.6
[0.5.5]: https://github.com/ercanatay/cybokron-dock-groups/compare/v0.5.4...v0.5.5
[0.5.4]: https://github.com/ercanatay/cybokron-dock-groups/compare/v0.5.3...v0.5.4
[0.5.3]: https://github.com/ercanatay/cybokron-dock-groups/compare/v0.5.2...v0.5.3
[0.5.2]: https://github.com/ercanatay/cybokron-dock-groups/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/ercanatay/cybokron-dock-groups/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/ercanatay/cybokron-dock-groups/releases/tag/v0.5.0
