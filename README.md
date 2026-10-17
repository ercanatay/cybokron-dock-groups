# Cybokron Dock Groups

A free, open-source macOS menu bar utility that organizes your apps into named groups. Choose a
group from the menu bar to see its apps in a popup over the Dock, or open them all at once.

> Status: early development (phase B — group popup and tile rendering). Standalone Dock tiles,
> keyboard shortcuts and Siri/Shortcuts support are planned.

## Features (so far)

- Menu bar item listing your groups with their tiles. Choosing a group shows its **popup**; holding
  ⌥ while choosing opens all of its apps right away.
- Group popup: a floating panel over the Dock (it doesn't take focus from the app you're using)
  with the group's app icons in a grid and a running indicator per app. Click an app to open it or
  bring it to the front; **Open All** opens every app; **Close All** quits the group's running apps
  normally, ⌘-click force quits them. Escape, a click elsewhere, or switching apps closes it.
- **Open All** never launches a running app a second time: running apps are brought to the front.
- Group management window: add, rename, reorder and delete groups; add apps with an open panel,
  reorder or remove them. Deleting a group never touches the apps themselves.
- Group tiles drawn by the app: the group's emoji, or a 2×2 / 3×3 grid of its first app icons, on a
  solid, gradient or glass background in the color you pick. They appear in the menu, the popup
  header and a live preview in the group window.
- Settings (⌘,): popup theme (dark by default, light, or matching the system), frosted glass,
  columns (auto or fixed), maximum rows (extra rows scroll), app names, position. Each group can
  override the layout settings in its own settings.
- Everything stays on your Mac, in `~/Library/Application Support/Cybokron/DockGroups/`:
  `groups.json` for the groups and `preferences.json` for the settings.

The app has no Dock icon (`LSUIElement`). Opening it again while it runs (Finder, Spotlight,
`open -a "Cybokron Dock Groups"`) shows the group window.

## Requirements

- macOS 14 Sonoma or later (Apple silicon or Intel)
- To build: Xcode 16 or later, or just the Command Line Tools (see below)

## Building

### Xcode

The project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml`;
the generated `CybokronDockGroups.xcodeproj` is committed, so XcodeGen is only needed after changing
`project.yml` or adding/removing files (`brew install xcodegen && xcodegen generate`).

```sh
xcodebuild -project CybokronDockGroups.xcodeproj -scheme CybokronDockGroups -configuration Debug build
xcodebuild -project CybokronDockGroups.xcodeproj -scheme CybokronDockGroups test
```

Builds are signed ad hoc, so no developer account is needed. Release builds are universal
(arm64 + x86_64).

### Command Line Tools only (SwiftPM)

```sh
scripts/test.sh                              # unit tests
scripts/build-app.sh debug                   # build/debug/Cybokron Dock Groups.app
UNIVERSAL=1 scripts/build-app.sh release     # universal release build
```

The scripts work around two Command Line Tools limitations automatically: they pick a macOS SDK
whose SwiftUI doesn't need Xcode's macro plugins, and they point the compiler at swift-testing's
macro plugin. If SwiftPM reports `disk I/O error` for its build database (seen with checkouts in
synced folders such as `~/Documents`), build elsewhere:
`SWIFTPM_SCRATCH_PATH=~/Library/Caches/CybokronDockGroups scripts/build-app.sh`.

## Project layout

| Path | Contents |
| --- | --- |
| `Sources/DockGroupsCore` | Group model and preferences, JSON persistence, stores, Open All / Close All, popup layout and placement, tile renderer and cache (no UI) |
| `Sources/CybokronDockGroups` | App: AppKit lifecycle, menu bar item, popup panel, SwiftUI group and settings windows |
| `Tests/DockGroupsCoreTests` | swift-testing unit tests for the core |
| `Resources` | `Info.plist`, asset catalog with the placeholder app icon |
| `scripts` | SwiftPM build/test scripts, icon generator |

The placeholder app icon is drawn by `scripts/generate-app-icon.swift` from plain shapes.

## License

MIT — see [LICENSE](LICENSE).
