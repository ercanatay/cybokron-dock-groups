# Cybokron Dock Groups

A free, open-source macOS menu bar utility that organizes your apps into named groups. Choose a
group from the menu bar to open all of its apps at once.

> Status: early development (phase A — project skeleton and group engine). Dock tiles, the launcher
> popup, keyboard shortcuts and Siri/Shortcuts support are planned.

## Features (so far)

- Menu bar item listing your groups; choosing a group opens all of its apps (**Open All**). Apps
  that are already running are brought to the front instead of being launched again.
- Group management window: add, rename, reorder and delete groups; add apps with an open panel,
  reorder or remove them. Deleting a group never touches the apps themselves.
- Per-group preferences for the upcoming Dock tile and popup: emoji or app-icon grid tile,
  background style and color, pinning, popup columns/rows/titles/position.
- Everything stays on your Mac, in
  `~/Library/Application Support/Cybokron/DockGroups/groups.json`.

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
| `Sources/DockGroupsCore` | Group model, JSON persistence, `GroupStore`, Open All launcher (no UI) |
| `Sources/CybokronDockGroups` | App: AppKit lifecycle and menu bar item, SwiftUI management window |
| `Tests/DockGroupsCoreTests` | swift-testing unit tests for the core |
| `Resources` | `Info.plist`, asset catalog with the placeholder app icon |
| `scripts` | SwiftPM build/test scripts, icon generator |

The placeholder app icon is drawn by `scripts/generate-app-icon.swift` from plain shapes.

## License

MIT — see [LICENSE](LICENSE).
