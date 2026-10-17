# Changelog

All notable changes to Cybokron Dock Groups are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.5.2] - 2026-10-17

### Added

- Developer ID (Rigicon, Inc.) signed and Apple notarized releases: the release workflow signs the
  app and the disk image with the Developer ID Application certificate (hardened runtime, secure
  timestamp), notarizes the disk image with `notarytool`, staples the ticket and checks it with
  `stapler validate`, `codesign` and `spctl` before attaching it to the draft release. Releases open
  without a Gatekeeper warning.
- `CODESIGN_IDENTITY` for `scripts/build-app.sh` and `scripts/make-dmg.sh`: set to a signing
  identity's SHA-1, it signs the app (and the DMG) with that identity instead of ad hoc. Without it,
  builds are signed ad hoc as before.

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

[0.5.2]: https://github.com/ercanatay/cybokron-dock-groups/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/ercanatay/cybokron-dock-groups/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/ercanatay/cybokron-dock-groups/releases/tag/v0.5.0
