# Slice: read-only Accessibility window observer and screen reader

Status: internal Core code on `main`, not connected to the app: no UI, setting, link, trigger or
user-facing CLI command calls it. The hidden, read-only [developer probe](window-layout-probe.md)
(`CYBOKRON_LAYOUT_PROBE=1`) runs it unchanged for the §5 experiment. Part of the H Core step in the
[window layouts design](window-layouts-and-cli-spec.md#6-implementation-plan-and-release-gates).
It does **not** close the Accessibility gate in §5 and moves nothing.

## Scope

In `Sources/DockGroupsCore/Layout/`:

- `LayoutAccessibilityObserver.swift` — `LayoutAccessibilityObserver`, the one
  `LayoutWindowObserving` implementation, over a `LayoutAccessibilityReading` source.
  `SystemLayoutAccessibilityReader` is the `AXUIElement` source; tests use fakes.
- `LayoutScreenProvider.swift` — `NSScreen.screens` → `[LayoutDisplay]` for the planners.

## What is read, what stays unknown

| Observation field | Source | Value when it cannot be read |
| --- | --- | --- |
| `reportedWindowCount` | `kAXWindowsAttribute` array count | `nil` (snapshot `unknown`) |
| `topLeftFrame` | `kAXPositionAttribute` + `kAXSizeAttribute` (`AXValue` point/size) | `nil` |
| `role` | `kAXRoleAttribute` (`AXWindow` → `window`, other string → `other`) | `unknown` |
| `subrole` | `kAXSubroleAttribute` (standard, dialog/system dialog, other) | `unknown` |
| `minimized` | `kAXMinimizedAttribute` (a `CFBoolean` only; a number is not a boolean) | `unknown` |
| `visible` | no public attribute | always `unknown` |
| `onCurrentSpace` | no public API | always `unknown` |
| `fullScreen` | no documented state attribute (only `kAXFullScreenButtonAttribute`) | always `unknown` |
| `identifiable` | no public, title-free window identity | always `unknown` |
| `appRunningUnprotected` | `NSRunningApplication` lookup + caller's protection answer | see below |

Nothing else is read: no title, document, URL, value or description attribute, no CG window list,
no screen capture. Visibility, Space, full screen and identity are not inferred from geometry,
minimized state, window order or CG metadata; the
[spike](window-layouts-spike.md) shows why such inferences are unsafe (identical geometries,
swapped positions, an unexplained extra `AXDialog`). As a result, the capture planner currently
skips every observed app (`ineligible.windowVisibleUnknown`); that is intended until §5 finds a
public way to establish those facts.

## Fail-closed matrix

| Situation | Result | AX calls |
| --- | --- | --- |
| Permission not granted (plain `AXIsProcessTrusted()` is false) | every app: running `unknown`, count `nil`, no windows | none |
| More than 256 bundle identifiers | same as above | none |
| App not running | running `no`, count `nil` | none |
| Several running instances, or identity not a plain bundle identifier | running `unknown`, count `nil` | none |
| Caller says the app is protected | running `no`, count `nil` | none |
| Protection unknown (the default) | running `unknown`; windows still read | yes |
| Window list unreadable (any error) | count `nil`, no windows | list only |
| List entry is not an AX element | counted, not described → snapshot `no` | — |
| Attribute unsupported / no value, or value of another type | that fact `unknown`; window kept | — |
| Window element gone or other error on a read | window counted, not described → snapshot `no` | stops that window |
| App does not answer (`cannotComplete`, incl. timeout) | further windows of that app not read → snapshot `no`; next app read | stops that app |
| Access turned off mid-read (`apiDisabled`) | that app and all later apps: count `nil` | stops everything |
| More than 64 windows, or the 2 s per-app budget spent | remaining windows not read → snapshot `no` | stops that app |
| Non-finite position, or non-finite / negative size | frame `nil` | — |

## Permission, timeout and the write ban

- **No prompt.** The only trust call is `AXIsProcessTrusted()` without options. The observer never
  uses the app's one-time prompt helper and never opens System Settings. Granting access stays
  an explicit, point-of-use step for the later app PR (spec §1.5).
- **Timeout.** `AXUIElementSetMessagingTimeout(…, 1)` is set on each application and window element
  before it is queried. It configures this process's side only and sends nothing to the target.
  A per-app budget of 2 s (monotonic clock) bounds the total; calls are synchronous, so callers
  must run the observer off the main thread.
- **Read only.** The only AX calls are `AXIsProcessTrusted`, `AXUIElementCreateApplication`,
  `AXUIElementSetMessagingTimeout` and `AXUIElementCopyAttributeValue`. No attribute is set, no
  action is performed, no app is activated, unhidden or raised, and `WindowRestorer` is not used.
  `LayoutPlannerSourceScanTests` fails if a layout source mentions an AX setter, action, value
  constructor, input event, prompt option, title/document attribute, or any `AXUIElement…` call
  other than the four above.

## Screens

`LayoutScreenProvider.currentDisplays()` (main actor) maps each `NSScreen` to its `frame`,
`visibleFrame` and `backingScaleFactor`; a screen is primary when its frame starts at the AppKit
origin. With no main screen the list is empty. It does not validate: `LayoutDisplayConfiguration`
refuses an empty list, no or several primaries, non-finite or collapsed frames and non-positive
scales, which the planners report as `invalidDisplayConfiguration`.

## Tests

`LayoutAccessibilityObserverTests` (fake source with call counters), `LayoutScreenProviderTests`
and the source scans run everywhere. `LayoutAccessibilityObserverSystemTests` performs a live,
read-only observation of Finder only when the test process already has Accessibility access; it
is skipped (not failed) without access, and its counterpart then checks the `denied` result.

## Next step: §5 experiment

Before any writer or UI: run the §5 matrix with a probe that uses this observer unchanged (the
[developer probe](window-layout-probe.md) covers the read-only part) — untrusted preflight with independent UI observation of prompt absence, grant /
revocation / relaunch, a deliberately unresponsive app (time to `unknown`), two windows, dialog,
minimized, full-screen, another Space, Stage Manager and split view, two displays with
negative coordinates and mixed scales, and macOS 14, 15, 26 and 27. Only a public signal found
there may replace an always-`unknown` field, each in its own reviewed change.
