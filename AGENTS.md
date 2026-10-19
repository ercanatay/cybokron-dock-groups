# AGENTS.md

Instructions for AI coding agents (OpenCode, Claude, Codex, Copilot, …) working in this repository.

## Project

Cybokron Dock Groups is a macOS 14+ menu bar app (Swift, AppKit + SwiftUI) that organizes apps into
named groups and opens a whole group at once. See [README.md](README.md) and [CONTRIBUTING.md](CONTRIBUTING.md).

- `Sources/DockGroupsCore` — model, JSON persistence, `GroupStore`, launcher, standalone agent bundles and Dock tile list. No UI; keep logic here so it is testable.
- `Sources/CybokronDockGroups` — app lifecycle, menu bar, SwiftUI windows. The same executable runs a standalone group's agent when its bundle identifier starts with `com.cybokron.dockgroups.agent.` (`Agent/AgentAppDelegate.swift`).
- Tests never touch the real Dock or LaunchServices: use `DockTileStoring` / `ToolRunning` fakes.
- `Tests/DockGroupsCoreTests` — swift-testing unit tests.

## Commands

```sh
scripts/test.sh                 # run unit tests (SwiftPM)
scripts/build-app.sh debug      # build/debug/Cybokron Dock Groups.app
```

Run `scripts/test.sh` before committing. After adding or removing source files or changing
`project.yml`, run `xcodegen generate` and commit the regenerated `CybokronDockGroups.xcodeproj`.
Keep version numbers in `scripts/build-app.sh` and `project.yml` in sync; `scripts/check-version.sh`
(run by CI) checks them against `project.pbxproj` and, for tags, the tag.

## Commit conventions

- Use [Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `docs:`, `build:`, `ci:`, `test:`, `refactor:`, `chore:`.
- Never force push to or delete `main`.

## Commit attribution

End every commit message with a blank line followed by `Co-authored-by:` trailers for the agent
and model that helped write the change. Use exactly these addresses so GitHub links them to the right
accounts; include only the lines that apply:

```text
Co-authored-by: opencode-agent[bot] <219766164+opencode-agent[bot]@users.noreply.github.com>
Co-authored-by: Claude <81847+claude@users.noreply.github.com>
Co-authored-by: Codex <267193182+codex@users.noreply.github.com>
Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
```

- Working through OpenCode → add the `opencode-agent[bot]` line, plus the line for the model used
  (Claude models → Claude, OpenAI/GPT models → Codex).
- Working directly in Claude Code → Claude line; Codex CLI or cloud → Codex line; GitHub Copilot → Copilot line.
- Do not use other e-mail addresses for these agents (e.g. `noreply@anthropic.com`, `noreply@openai.com`).
