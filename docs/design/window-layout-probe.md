# Developer probe: observe an app's windows for the §5 experiment

Status: hidden developer tool on `main`. It is **not a release feature**: the CLI help, the README,
the app and its menus never mention it, and it does nothing unless an environment variable is set.
It exists to run the
[Accessibility experiment in §5](window-layouts-and-cli-spec.md#5-required-accessibility-spike-before-h-code-pr)
with the read-only [observer and screen reader](window-layout-observer-slice.md) unchanged. It
does not close the §5 gate and moves nothing.

## Purpose

Record, per macOS release and window setup, what the read-only observer actually reports for an
app's windows: how many windows the app lists, which facts are readable, which stay `unknown`,
how the displays are configured, and how long each app takes to answer. The results fill the §5
go/no-go matrix; only a public signal found there may later replace an always-`unknown` field, in
its own reviewed change.

## What it does and does not do

- Calls `LayoutAccessibilityObserver` (one app per call, so each app is timed separately) and
  `LayoutScreenProvider.currentDisplays()`; nothing else reads Accessibility.
- Reads only: the plain trust check without options, the window list, and role, subrole,
  minimized, position and size of each window. No title, document or URL attribute.
- Never writes an attribute, performs an action, activates, raises, unhides or unminimizes
  anything, never asks macOS to show its permission request and never opens System Settings.
- Dispatches no URL, launches nothing, reads no group data and writes no file.
- Output holds the requested bundle identifiers, display and window geometry, tri-state facts and
  timings. No process identifier, path or window title.

## Usage

The probe ships inside the CLI (`Contents/MacOS/cybokrondockgroups` of a packaged app, or the
SwiftPM product `CybokronDockGroupsCLI`). It runs only when `CYBOKRON_LAYOUT_PROBE` is exactly
`1`; without it, `--layout-observe` is an unknown argument and the CLI prints its normal usage with
exit code 2.

```sh
CLI="/Applications/Cybokron Dock Groups.app/Contents/MacOS/cybokrondockgroups"
# or, from a checkout: swift build --product CybokronDockGroupsCLI
#   CLI="$(swift build --show-bin-path)/CybokronDockGroupsCLI"

CYBOKRON_LAYOUT_PROBE=1 "$CLI" --layout-observe com.apple.finder > finder.json
CYBOKRON_LAYOUT_PROBE=1 "$CLI" --layout-observe com.apple.TextEdit com.apple.Safari > apps.json
```

Arguments: one to 16 distinct plain bundle identifiers (ASCII letters, digits, `.`, `-`, `_`; not
starting with `-` or `.`). Anything else exits 2 with the probe's usage on stderr.

JSON goes to stdout, a human-readable summary to stderr:

```text
layout-observe: permission granted; 1 app(s); 2 of 2 reported window(s) read; 10 unknown field(s); 25.6 ms total
  com.apple.finder: 2 of 2 window(s), snapshot yes, 10 unknown, 21.5 ms
```

The calls are synchronous. Each one is bounded by the observer's 1 s messaging timeout, and the
2 s per-app read budget is checked before each window, so one app can overrun the budget by at
most one window's reads.

### Whose permission is checked

macOS attributes Accessibility access to the *responsible* process. Started from Terminal (or
iTerm, or an editor's terminal), the probe reports that app's access, not the Dock Groups app's.
To test "no access", grant or revoke access for the terminal app in System Settings → Privacy &
Security → Accessibility yourself, or start the probe from a process that has none, for example:

```sh
launchctl submit -l probe.denied -o /tmp/probe.out -e /tmp/probe.err -- \
  /usr/bin/env CYBOKRON_LAYOUT_PROBE=1 "$CLI" --layout-observe com.apple.finder
sleep 3; launchctl list | grep probe.denied   # second column is the exit code
launchctl remove probe.denied; cat /tmp/probe.err
```

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Access granted before and after the read, and every app was running exactly once. |
| 2 | Bad arguments (usage on stderr, no JSON), **or** Accessibility access not granted before or after the read (JSON on stdout, `accessibilityPermission` or `accessibilityPermissionAfterRead` is `denied`). Takes precedence over 3. |
| 3 | At least one app is not running, runs several times, or could not be looked up (JSON on stdout, error line per app on stderr). The other apps are still read. |

## Output fields

All keys are always present and sorted; values that could not be established are `null` or
`"unknown"`, never omitted. Equal states produce byte-identical output except for the durations.

| Field | Meaning |
| --- | --- |
| `probe`, `formatVersion` | `"layout-observe"`, `1`. |
| `system.operatingSystemVersion` | `major.minor.patch` of macOS. |
| `accessibilityPermission` | `granted` / `denied` from the plain trust check before reading. |
| `accessibilityPermissionAfterRead` | The same check after all apps; `denied` shows access revoked mid-run. |
| `limits` | `messagingTimeoutSeconds` (1), `appReadBudgetSeconds` (2), `maximumWindowCount` (64). |
| `displays.coordinateSpace` | `appKitBottomLeftPoints`: origin at the bottom-left of the menu-bar display, `y` up. |
| `displays.configurationAccepted` | Whether the planners would accept this display list (`LayoutDisplayConfiguration`). |
| `displays.screens[]` | `frame`, `visibleFrame` (`x`, `y`, `width`, `height`), `backingScaleFactor`, `primary` (frame starts at the AppKit origin), in `NSScreen.screens` order. |
| `windowCoordinateSpace` | `accessibilityTopLeftPoints`: origin at the top-left of the menu-bar display, `y` down. |
| `applications[].bundleIdentifier` | As requested, in argument order. |
| `applications[].runningInstances` | `none`, `one`, `several` or `unknown`; only `one` is read. |
| `applications[].appRunningUnprotected` | The observer's value. The probe knows no protected apps, so a read app is `unknown`, an absent one `no`. |
| `applications[].reportedWindowCount` | Count of the app's `AXWindows` list, or `null` when unreadable or not read. |
| `applications[].readWindowCount` | Windows that could be described. |
| `applications[].completeSnapshot` | `yes` when every reported window was read, `no` when some were not (unreadable entry, element gone, app stopped answering, budget or 64-window limit), `unknown` when the count is `null`. |
| `applications[].durationMilliseconds` | Time spent on this app (0.1 ms resolution, monotonic clock). |
| `applications[].unknownFieldCount` | Sum of `unknownFields` over its windows. |
| `applications[].windows[]` | `index` (order in the app's list among read windows), `topLeftFrame` (`null` when position or size is unreadable or invalid), `role` (`window`/`other`/`unknown`), `subrole` (`standardWindow`/`dialog`/`other`/`unknown`), `minimized` (`yes`/`no`/`unknown`), `visible`, `onCurrentSpace`, `fullScreen`, `identifiable` (always `unknown`: no public attribute), `unknownFields` (names of the `null`/`unknown` fields). |
| `summary` | `applicationCount`, `reportedWindowCount`, `readWindowCount`, `unknownFieldCount`, `totalDurationMilliseconds`. |

## §5 steps

Use ordinary test windows (TextEdit documents, a Finder window), not real work. Save each run's
stdout and stderr with the macOS version and the setup in the file name, e.g.
`26.1-textedit-fullscreen.json`. Repeat on macOS 14, 15, 26 and 27 where available.

1. **Permission absent.** With the terminal app's Accessibility access off (or via `launchctl
   submit` above), run the probe. Expect `denied`, exit 2, `reportedWindowCount: null`, and **no
   system prompt**: watch the screen for one during and after the run.
2. **Grant, revoke, relaunch.** Grant access to the terminal app yourself, open a new terminal
   window, run again (expect `granted`, exit 0). Revoke while a slow app is being read to see
   `accessibilityPermissionAfterRead: denied`; then quit and relaunch the terminal and run again.
3. **Ordinary windows.** TextEdit with one window, then two windows, one minimized, and an open
   dialog (Save sheet / alert). Note role, subrole, `minimized` and frames.
4. **Full screen.** Put one TextEdit window into full screen; run from another Space. Note whether
   anything other than `fullScreen: unknown` distinguishes it (it should not change the field).
5. **Spaces.** Move a window to another Space; run from the first Space and from the second. Note
   whether `reportedWindowCount` or the frames change.
6. **Stage Manager and split view.** Turn Stage Manager on with windows in and out of the current
   stage; then tile two windows in split view. Record counts and frames.
7. **Multiple displays.** Two displays with the secondary left of or above the primary (negative
   coordinates) and different scales; move windows across. Compare `displays.screens` with
   `topLeftFrame` to confirm the AX top-left versus AppKit bottom-left relationship. Unplug and
   replug, change resolution, move the Dock.
8. **Unresponsive app.** Stop a test app (`kill -STOP <pid>` of a TextEdit you opened for this),
   run the probe for it and another app, then `kill -CONT <pid>`. Expect the stopped app's
   `durationMilliseconds` near the 1 s messaging timeout,
   `completeSnapshot` `no` or `unknown`, and the other app still read.

## Not a release feature

The probe stays hidden: no help text, README entry, menu item, setting, link or localized string
mentions it, and tests fail if the help or README does. It adds no permission request and no code
path that changes another app. Window moving, the Save/Restore UI and the permission path remain
gated on §5 as described in the [design spec](window-layouts-and-cli-spec.md#6-implementation-plan-and-release-gates).

## Tests

`LayoutObservationProbeTests`: the option is inert without the exact variable value; malformed
arguments fail before reading; JSON shape with sorted keys and explicit `null`/`unknown`; denied
permission makes no Accessibility call and exits 2; access revoked mid-run exits 2; apps not
running exactly once exit 3; per-app timing of an unresponsive app; refused display
configuration; no process identifier in the output; and a source scan of the probe and CLI files
for write, action, prompt and settings symbols. `LayoutPlannerSourceScanTests` also covers the
probe file as part of the layout core.
