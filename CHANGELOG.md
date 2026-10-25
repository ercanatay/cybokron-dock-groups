# Changelog

All notable changes to Cybokron Dock Groups are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.10.0] - 2026-10-25

### Added

- New Group from Open Apps… (the menu bar menu, and the group window's + menu) lists the apps that are open now, the one you were working in first, and makes a group of the ones you keep checked, named after them ("Xcode +3") unless you type a name; it's added at the end of the list and selected
- Add Open Apps… (a group's Add menu, and an empty group's popup) adds the open apps to that group, after its items; the apps it has already show as "In this group"
- The list has regular apps only, once each — no background apps, Finder, Cybokron Dock Groups or standalone groups' own apps — ordered by Most Recently Used or Name. Protected apps are listed but start unchecked, and "Select only apps with open windows" (off by default) unchecks the apps that seem to have none; both choices are remembered. Up to 50 apps per capture; a footnote counts the open apps that can't be added (no app bundle, or run from a temporary copy without a bundle identifier)
- `cybokrondockgroups://capture` and `cybokrondockgroups://capture/<group>` show the same sheets; nothing is added until you click. Settings → Shortcuts & Siri lists each group's Add Open Apps link
- Siri and the Shortcuts app: New Group from Open Apps (“Capture my open apps in Cybokron Dock Groups”; an optional name, and returns the group) and Add Open Apps to Group add the open apps the sheet would start with checked — never the Shortcuts app — without asking: nothing is opened or quit. Settings → Shortcuts & Siri lists the phrase
- The diagnostics report has the two capture settings (no app names)

### Changed

- Apps added to a group from anywhere — the open panel, the running apps, a capture — pass the check backups use: an app is kept only as a bundle identifier or an app bundle's location, and a remembered location that isn't an app bundle is dropped

### Security

- Capturing asks for no permission and never opens, hides or quits an app: it reads the running apps and the window list's owner, position, size and on-screen fields (not window titles, which need Screen Recording), and only adds app items

## [0.9.0] - 2026-10-25

### Added

- A keyboard shortcut for each group, set in the group window's new Keyboard Shortcut section: click the field and press the keys (at least two of ⌃, ⌥ and ⌘ plus a key; Escape cancels, Delete removes it), then choose what pressing it does: show the popup, Open All, or Start (Finish when the group is current). It works in every app as a hot key, without Accessibility access; the number shortcuts stay as they are
- Keys a group shortcut can't take are refused with the reason: those typing, editing and menus need, macOS's own shortcuts (built in, and those turned on in System Settings → Keyboard → Keyboard Shortcuts), the number shortcuts' keys, another group's shortcut. A shortcut that stops working says why in the group window
- Settings → Shortcuts & Siri lists the groups' shortcuts, what they do and whether they work, with Change… to each group's settings
- Starting or finishing a group from its shortcut asks first when it would quit apps, as a link does (Hide Instead or Cancel); hiding never asks
- The menu bar menu's tooltip of a group names its own shortcut too, and the diagnostics report counts the group shortcuts (how many, how many work)
- Duplicate (the group window's sidebar, right-click a group) adds a copy at the end of the list — "Coding copy", with the same items and settings, but not standalone and without a keyboard shortcut — so no group's number shortcut changes
- Archive puts a group out of sight without deleting it: it leaves the popup, the menu bar menu, the shortcuts, links, Siri and Focus filters, and its delayed items don't open. A standalone group asks first, since its own app and Dock icon are removed. The sidebar's Archived section lists archived groups, with a read-only summary, Restore and Delete…
- Restore puts an archived group back at the end of the list, with its own Dock icon when it had one; when another group took its keyboard shortcut meanwhile, it comes back without it and says so
- Templates: Save as Template… keeps a group's items and settings under a name (up to 50; one of the same name can be replaced), the sidebar's + menu makes a new group from one, and Manage Templates… renames and deletes them
- Backups include archived groups and templates, and the import question says what happens to yours; Merge adds the new ones, and merged groups whose shortcut another group has come in without it
- Siri and the Shortcuts app say a group is archived instead of acting on it; Settings → Switching says when the current Focus names an archived group; the diagnostics report counts archived groups and templates
- Going back from Other Versions… to a version older than 0.9.0 keeps a copy of the groups and the settings first (as for older ones), and the question warns when a group has a keyboard shortcut, a group is archived or a template exists: there the shortcuts and the archive are dropped on a save, archived groups show as ordinary groups, and templates stay for when you come back

### Changed

- Number shortcuts stay all-or-none; a group shortcut that can't be registered turns off alone, with no event-monitor fallback and no Accessibility prompt
- Archived groups show as ordinary groups in versions before 0.9.0; copies of `groups.json` and `preferences.json` are kept before installing one, with a warning when shortcuts, archived groups or templates are in use

## [0.8.0] - 2026-10-24

### Added

- Going back from Other Versions… to a version without Start and Finish now also keeps a copy of the settings (`preferences.pre-downgrade-*.json`, next to the groups copy), and the question warns when Start and Finish settings, launch options or protected apps would be dropped there
- Start and Finish a group: Start opens its items as Open All does and puts the group started before it away (by default its apps are hidden; apps both groups use stay), Finish hides its apps and shows the previous group again; quitting is never a default and always graceful
- Each group's Start and Finish settings, in a new section of the group window: hide the previous group's apps, hide all other apps, quit the previous group's apps or leave them; hide, quit or leave its own apps on Finish; show the previous group again or not
- The current group (the one started last, until it's finished): the popup says "current" and offers Finish instead of Start, and the menu bar menu begins with it and Finish; it's forgotten when the app quits
- Start in the popup (▶; ■ Finish for the current group), in the menu bar menu (⌃⌥ while choosing a group) and in the group window
- Settings → Switching: protected apps (Add Apps… or a running app, up to 50) that Start, Finish and Close All never quit and Start and Finish never hide, with what Start and Finish do and the current group
- Links `cybokrondockgroups://start/<group>` (also `switch/<group>`) and `finish/<group>`; when they would quit apps they ask first: quit, Hide Instead or Cancel (the quit button waits 0.7 seconds)
- Siri and Shortcuts: Start Group and Finish Group, with phrases such as "Start Work in Cybokron Dock Groups"; they ask there before quitting apps; Settings → Shortcuts & Siri lists their phrases and links
- Launch options in the details editor's new Opening part: a delay of up to 60 seconds that Open All and Start wait (clicks open right away), and the app that opens a file, folder or website (Terminal or iTerm2 for folders); apps that run what they open are refused, and the editor says why
- Item rows and popup tooltips show the chosen app and the delay, and when the chosen app isn't on this Mac
- Importing a backup says how many items' launch settings were reset because they named an app that runs files
- A Focus filter (System Settings → Focus → Focus Filters → Cybokron Dock Groups) starts, opens or shows a group when its Focus turns on, and can finish it (hiding its apps) when the Focus turns off; a Focus never quits apps, repeated calls act once, and Settings → Switching shows what the current Focus asks for. It works while the app is running

### Changed

- Close All leaves protected apps alone wherever it's asked: the popup, the menus, quit links, Siri's Quit Group and a standalone group's own app
- Start and finish links share the 5-second limit of launch and hide links, and their question never shows together with a quit link's
- The groups window has a Start and Finish section; Settings has a Switching pane with protected apps and the current group
- Close All no longer quits Finder or this app's own windows

### Fixed / Security

- Open With adds no new way to run code: the item is checked as before, the chosen app is resolved at launch time, must be a real app bundle macOS lists for the item, and must not run what it opens. Any failure refuses the open (fail closed), including from a crafted groups file or backup
- Copies of `preferences.json` are kept next to `groups.json` before a version without switching is installed; the warning appears only when the new settings are in use

## [0.7.0] - 2026-10-23

### Added

- Groups now hold files and folders as items: click opens them; context menu has Show in Finder and Quick Look; missing items stay visible, removable, and can be located again with their details and place kept
- Every item can have an alias, tags and task notes; the popup finds items by all of them (name matches rank first)
- Groups keep a copy of the groups file before an older version that can't show these items is installed (last 3 copies)

### Fixed

- A crafted groups.json or backup could make an app item point to a script or program outside its app bundle; app items now start only from .app bundles
- File items that are programs, scripts, installers, location or alias files can't be added, and files whose default handler would run them (Terminal, Installer and friends) aren't opened
- Backup import reports items that were left out because they can't be opened safely

### Changed

- The groups window counts "items", not "apps"
- macOS privacy usage descriptions were added for Documents, Downloads, Desktop and volume access

## [0.6.7] - 2026-10-23

### Changed

- CI: the checkout, artifact upload and release actions in the workflows are updated (SHA-pinned, matching Dependabot's bumps)
- The release notes performance test tolerates slower CI runners (1 s); the local bound stays at 200 ms

## [0.6.6] - 2026-10-21

### Added

- Group Settings is one click away: a gear in a group's popup, a "Group Settings…" item in its menus, and a settings link (`cybokrondockgroups://settings/group/<name>`)
- The Settings' Support tab shows the About window's content, donation links included
- Siri's Quit Group intent now asks before quitting the group's apps, with a force-quit warning

### Changed

- A group's apps and websites are counted as items ("8 items"); the old per-app phrasing is gone
- Global group shortcuts now use reserved hot keys: no Accessibility permission, the frontmost app no longer receives the key press
- Translations: all languages now carry every key, with a note when macOS can't reserve the shortcut keys (fallback needs Accessibility)

## [0.6.5] - 2026-10-20

### Fixed

- Updates signed by a third party or left ad hoc are rejected when the running copy is Developer ID
  signed (`codesign --verify --strict -R` with a Developer ID requirement for the running team and
  bundle identifier); the staged DMG signature is verified before mounting. Copies signed ad hoc
  (v0.6.2 and earlier) keep accepting any intact signature, so they can still update
- CI supply chain: every GitHub Action is pinned to a commit SHA (version in a comment), checkouts
  don't persist the token, the release job runs in a `release` environment (`v*` tags only, maintainer
  approval), only `codesign` may use the imported signing key, and a `.p12` holding more than the
  Developer ID Application identity stops the release job
- Update and changelog feed overrides are enabled only in development builds: release builds ignore
  `CYBOKRON_UPDATE_FEED_URL`, `CYBOKRON_RELEASES_FEED_URL`, `CYBOKRON_CHANGELOG_FEED_URL`,
  `CYBOKRON_UPDATE_DRY_RUN` and `CYBOKRON_SIMULATE_SIGN_FAILURE` (`#if DEBUG`)
- Release notes rendering takes linear time: HTML comments are removed in one pass instead of with a
  lazy regular expression (quadratic on text full of `<!--`), long list items and code blocks no
  longer copy themselves line by line, and notes longer than 250,000 characters are cut with a note
- The bundle build number matches the marketing version (major × 10000 + minor × 100 + patch, e.g.
  0.6.4 → 604 instead of 1) so LaunchServices resolves the newest installed copy;
  `scripts/check-version.sh` checks it everywhere it's written and in the built app (CI)
- Link safety: `cybokrondockgroups://launch/…` and `hide/…` links share one 5-second limit, so only
  one group's apps are opened or hidden per 5 seconds whichever group the links name (menus,
  shortcuts, Siri and Shortcuts aren't limited); the quit dialog's Quit / Force Quit Apps button is
  enabled 0.7 seconds after it appears (Cancel and Escape work at once)
- Standalone group agents follow a configuration-change notification's new bundle path only when
  it's an `.app` directly in the agents folder with the agent's own bundle identifier (any process
  can post the notification)
- Backup import refuses files over 5 MB before reading them, and drops app locations that aren't an
  absolute path to a `.app` bundle (an item known only by such a location is left out)
- The usage monitor records events only while Most Used is enabled (the setting is checked at every
  launch and activation); turning it off keeps the history recorded so far, and turning it back on
  records new events. The Settings → Most Used footer says so (new string, English only for now)
- GitHub API answers (update checks, Other Versions…, Changelog) must come, after any redirect, from
  `api.github.com` / `github.com` over HTTPS (or from the host a development override asked)
- Links with a user name or password (`https://github.com%2F@evil.example`) in release notes show
  as plain text, and such a release page address is ignored
- Import Settings… keeps the last three `*.pre-import-<time>.json` copies instead of only the
  latest (ordered by time and counter, collision-safe)
- SECURITY.md describes the app's actual network use; README notes that the quarantine workaround
  is only for releases before v0.6.3 and how ad hoc signed copies (v0.6.2 and earlier) accept updates

### Added

- Settings → Updates → Other Versions… warns before installing a version older than 0.6.5, which
  lacks these security fixes (new strings, English only until the next translation pass)

## [0.6.4] - 2026-10-20

### Added

- CI staples the app itself before stapling the DMG (fixes 'Notary Ticket Missing' for the bundled app)

### Fixed

- Local `UNIVERSAL=1` builds no longer fail (or silently use stale debug data) in the App Intents metadata step; the script now looks up the whole-module `*-primary.swiftconstvalues` file and restricts the search to the current configuration

## [0.6.3] - 2026-10-19

### Added

- **First notarized release**: the app is signed with a Developer ID Application certificate
  (hardened runtime, secure timestamp), and the universal DMG is Developer ID signed, notarized by
  Apple and stapled, so macOS opens it without the “Apple could not verify …” warning. Notarization
  was tested locally first: the notarized build passes `spctl` and `stapler validate`.

### Changed

- Because the signature changes from ad hoc to Developer ID, macOS asks for Accessibility access
  once more after updating to this version (System Settings → Privacy & Security → Accessibility);
  later Developer ID releases keep it.

## [0.6.2] - 2026-10-19

### Fixed

- Release notes security: links in update-window and settings changelog notes are now filtered to https/mailto only; release page URL must be https
- Dock safety: if the Dock's persistent-apps list cannot be read, groups are no longer closed or rewritten; a timestamped backup of the Dock is kept (last 6) before every write, and failed writes keep pending dock additions instead of silently disabling groups
- Safety: clicking a `cybokrondockgroups://quit/...` link now shows a confirmation dialog, with a distinct "Force Quit Apps" button for `?mode=force`
- Backup restore/merge now re-adds missing Dock icons for standalone groups instead of disabling them on the next launch
- Downloaded update is verified with `codesign --verify --strict` (Developer ID builds also require a matching Team ID; ad-hoc builds still accepted)
- Miscellaneous: automatic update checks are skipped while the update window shows an offer or failure; "install picked" while an update is under way warns instead of failing silently; less risky `copyAside` write order plus collision-safe filenames; release notes script handles fenced code blocks; diagnostics report redacts the home directory; DMG name matching compares the full version number; localization test now catches mixed positional and non-positional placeholders

### Added

- CI release now reproduces the version section from CHANGELOG.md as the release body; a version-consistency check (`scripts/check-version.sh`) runs before test and release jobs

## [0.6.1] - 2026-10-19

### Added

- Settings → Changelog tab: release notes fetched from GitHub Releases shown as an accordion (latest open by default, Latest/Installed/Pre-release badges), current-version display, manual refresh with cache (works offline from `changelog-cache.json`)

## [0.6.0] - 2026-10-19

### Added

- **24 new languages**: Azerbaijani, German, French, Spanish, Italian, Brazilian Portuguese, Dutch,
  Swedish, Polish, Czech, Romanian, Hungarian, Greek, Bulgarian, Ukrainian, Russian, Arabic (RTL),
  Farsi (RTL), Hindi, Simplified Chinese, Japanese, Korean, Indonesian, Vietnamese — 463 keys each;
  the language picker now offers 26 languages.

## [0.5.9] - 2026-10-18

### Changed

- **Settings panes in a sidebar**: Popup, Shortcuts & Siri, Most Used, Updates and Backup are now
  listed in a sidebar on the left (on the right in right-to-left languages), as in System Settings,
  instead of a tab bar across the top. The panes keep their width and scroll as before, the window
  is still as tall as the screen has room for (at most 640 points), and the pane last shown is
  selected again the next time Settings opens.

## [0.5.8] - 2026-10-18

### Fixed

- **Settings window scrolls on any screen**: the Popup, Most Used, Updates and Backup tabs still
  sized their form to its full height, so it didn't scroll, its bottom was out of reach and it
  covered the tab bar; the Shortcuts tab was taller than its pane. Every tab now fills the pane and
  scrolls, the pane is as tall as the screen has room for (at most 640 points), and the window is
  kept inside the screen even when its saved position isn't.

## [0.5.7] - 2026-10-18

### Fixed

- **Scrollable Settings panes**: every Settings tab now has the same fixed height and scrolls, instead
  of the window growing past the screen (Popup, Updates, Backup, Most Used were cut off).

### Added

- **Language picker** at the top of Settings → Popup: *System* (the language macOS gives the app,
  named in it) or any language the app has a string table for, each named in itself. The choice is
  stored in `preferences.json` (`"language"`: `"system"` or the code) and applied at launch as the
  app's own `AppleLanguages`, so it shows after a restart: the section then offers **Restart Now**,
  which also quits the running standalone groups' apps so they start in the new language too.
  *System* removes only the value the app set itself, not one chosen in System Settings. The list of
  languages (`SupportedLanguages`, 26 with their native names) is the one place to update when a
  translation is added; the tests check every `.lproj` folder has an entry.
- **Localization framework**: the app's user-facing text — menus, popup, group window, Settings,
  the update and About windows, alerts and the core's error messages — comes from string tables,
  `Resources/<language>.lproj/Localizable.strings`, with the English text in `en.lproj` (listed in
  `docs/l10n-keys.md`); a missing translation falls back to English. Both build paths copy every
  `.lproj` folder into the app, and standalone groups' apps get a copy. No translations yet: the
  app is still in English. Siri and Shortcuts texts follow separately.

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

- Developer ID signing and Apple notarization in the release workflow: when the repository variable
  `NOTARIZE_ENABLED` is `true`, it signs the app and the disk image with the Developer ID Application
  certificate (hardened runtime, secure timestamp), notarizes the disk image with `notarytool`,
  staples the ticket and checks it with `stapler validate`, `codesign` and `spctl` before attaching
  it to the draft release. While the variable is `false`, the releases are signed ad hoc and open
  with a Gatekeeper warning; the first notarized release comes out once the pipeline runs.
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

- The README explains how to open the ad hoc signed releases the
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
[Unreleased]: https://github.com/ercanatay/cybokron-dock-groups/compare/v0.10.0...HEAD
[0.10.0]: https://github.com/ercanatay/cybokron-dock-groups/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/ercanatay/cybokron-dock-groups/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/ercanatay/cybokron-dock-groups/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/ercanatay/cybokron-dock-groups/compare/v0.6.7...v0.7.0
[0.6.7]: https://github.com/ercanatay/cybokron-dock-groups/compare/v0.6.6...v0.6.7
  rebuilt when the group or the app changes and removed (with its Dock tile) when it's turned off or
  deleted.
- Settings window with Popup, Shortcuts and Most Used tabs, and an About window.
- Universal (Apple silicon and Intel) disk image built by `scripts/make-dmg.sh` and attached to a
  draft GitHub release for `v*` tags.

[Unreleased]: https://github.com/ercanatay/cybokron-dock-groups/compare/v0.10.0...HEAD
[0.10.0]: https://github.com/ercanatay/cybokron-dock-groups/compare/v0.9.0...v0.10.0
[0.6.6]: https://github.com/ercanatay/cybokron-dock-groups/compare/v0.6.5...v0.6.6
[0.6.5]: https://github.com/ercanatay/cybokron-dock-groups/compare/v0.6.4...v0.6.5
[0.6.4]: https://github.com/ercanatay/cybokron-dock-groups/compare/v0.6.3...v0.6.4
[0.6.3]: https://github.com/ercanatay/cybokron-dock-groups/compare/v0.6.2...v0.6.3
[0.6.2]: https://github.com/ercanatay/cybokron-dock-groups/compare/v0.6.1...v0.6.2
[0.6.1]: https://github.com/ercanatay/cybokron-dock-groups/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/ercanatay/cybokron-dock-groups/compare/v0.5.9...v0.6.0
[0.5.9]: https://github.com/ercanatay/cybokron-dock-groups/compare/v0.5.8...v0.5.9
[0.5.8]: https://github.com/ercanatay/cybokron-dock-groups/compare/v0.5.7...v0.5.8
[0.5.7]: https://github.com/ercanatay/cybokron-dock-groups/compare/v0.5.6...v0.5.7
[0.5.6]: https://github.com/ercanatay/cybokron-dock-groups/compare/v0.5.5...v0.5.6
[0.5.5]: https://github.com/ercanatay/cybokron-dock-groups/compare/v0.5.4...v0.5.5
[0.5.4]: https://github.com/ercanatay/cybokron-dock-groups/compare/v0.5.3...v0.5.4
[0.5.3]: https://github.com/ercanatay/cybokron-dock-groups/compare/v0.5.2...v0.5.3
[0.5.2]: https://github.com/ercanatay/cybokron-dock-groups/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/ercanatay/cybokron-dock-groups/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/ercanatay/cybokron-dock-groups/releases/tag/v0.5.0
