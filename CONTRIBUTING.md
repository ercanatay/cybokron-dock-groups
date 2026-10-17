# Contributing to Cybokron Dock Groups

Thanks for your interest! Bug reports, ideas and pull requests are all welcome.

- **Questions and ideas:** [Discussions](https://github.com/ercanatay/cybokron-dock-groups/discussions)
- **Bugs and concrete feature requests:** [Issues](https://github.com/ercanatay/cybokron-dock-groups/issues/new/choose)
- **Security problems:** see [SECURITY.md](SECURITY.md) — please report them privately.

## Development setup

Requirements: macOS 14 or later, and Xcode 16+ **or** just the Command Line Tools.

```sh
git clone https://github.com/ercanatay/cybokron-dock-groups.git
cd cybokron-dock-groups

scripts/test.sh                 # unit tests (SwiftPM)
scripts/build-app.sh debug      # build/debug/Cybokron Dock Groups.app
```

With Xcode, open `CybokronDockGroups.xcodeproj` or use
`xcodebuild -project CybokronDockGroups.xcodeproj -scheme CybokronDockGroups test`.
See the [README](README.md#building) for details and Command Line Tools workarounds.

## Project structure

- `Sources/DockGroupsCore` — model, persistence, store and launcher; no UI. Put logic here so it can be unit-tested.
- `Sources/CybokronDockGroups` — AppKit lifecycle, menu bar and SwiftUI windows.
- `Tests/DockGroupsCoreTests` — swift-testing tests for the core.

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen).
After adding or removing source files, run `xcodegen generate` and commit the updated project.

## Pull requests

1. Create a branch from `main`.
2. Keep changes focused; add or update tests in `DockGroupsCoreTests` for core changes.
3. Make sure `scripts/test.sh` passes — CI runs the same tests with SwiftPM and Xcode.
4. Use clear commit messages; [Conventional Commits](https://www.conventionalcommits.org/) style
   (`feat:`, `fix:`, `docs:`, `build:`, `ci:` …) is preferred, as used in the history.
5. Open the PR and fill in the template.

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
