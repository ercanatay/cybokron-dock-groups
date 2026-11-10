# Slice: side-effect-free layout capture and restore-preview planners

Status: internal Core code on `main`, not connected to the app. Part of the H Core step in the
[window layouts design](window-layouts-and-cli-spec.md#6-implementation-plan-and-release-gates).
It does not close the Accessibility gate in §5: no code here reads or moves another app's windows.

## Scope

Pure planning over caller-supplied values, in `Sources/DockGroupsCore/Layout/`:

- `LayoutWindowObservation.swift` — input values: `LayoutAccessibilityPermission`
  (`unknown`/`granted`/`denied`), `LayoutWindowObservation` (one app: bundle identifier, running
  state, reported window count, windows with AX top-left frame, role, subrole and tri-state
  minimized/visible/current-Space/full-screen/identifiable facts), `LayoutDisplay` (AppKit frame,
  visible frame, scale, primary flag), the shared `LayoutDisplayConfiguration` gate, and the
  `LayoutWindowObserving` protocol. The protocol is a contract only; nothing conforms to it.
- `LayoutCapturePlanner.swift` — permission + observations + displays → a validated
  `WindowLayoutDocument.Group`, or a group skip reason, plus one decision per observed app.
- `LayoutRestorePreviewPlanner.swift` — group + current displays → per window, a target frame
  (AppKit and AX coordinates, display index, fallback flag) or a skip reason. Nothing is written.

## Contracts

- Unknown is never read as present or absent. Permission `unknown` or `denied` produces no group
  before any observation is examined. A role, subrole or count that is unknown keeps the app out.
- Capture uses `LayoutCandidateEligibility` for each app: exactly one standard, visible,
  unminimized, non-full-screen, identifiable window on the current Space, from a complete window
  list. A second window or a dialog skips the app. Windows are not matched by title, PID plus
  geometry or window number.
- The AX frame is converted with `LayoutCoordinateConversion` (primary display height) and captured
  by `WindowLayoutGeometry.capture`. Exactly one display must hold at least half of the window; a
  tie between two displays is skipped. Each window passes `WindowLayoutDocument` validation on its
  own, then the group as a whole; no captured window means no group (no empty snapshot).
- Restore preview validates the group with `WindowLayoutDocument`, chooses a display with
  `DisplayTargetPlanner` (exact size match, otherwise the primary display) and restores with
  `WindowLayoutGeometry.restore`, so a target always lies inside the chosen visible frame. The AX
  target is checked again against the converted visible frame.
- Displays are refused as a whole unless there are 1…256, exactly one primary at the AppKit
  origin, finite non-collapsed frames and a finite positive scale. Scale is validated but does
  not affect point geometry.
- Results are positional (aligned with the input array or `group.windows`). No reason carries a
  bundle identifier, path or geometry.

## Skip reasons

Capture, group level: `accessibilityPermissionUnknown`, `accessibilityPermissionDenied`,
`invalidDisplayConfiguration`, `tooManyApps` (over 256 observations), `noEligibleWindows`,
`documentRejected` (defensive; not expected).

Capture, per app: `ineligible(<LayoutCandidateEligibility.SkipReason>)`, `frameUnavailable`,
`coordinateConversionFailed`, `lessThanHalfOnAnyDisplay`, `ambiguousDisplay`,
`malformedBundleIdentifier`, `displaySizeOutOfRange`, `geometryRejected`, `duplicateApp`
(case-insensitive), `windowLimitReached` (beyond 64 windows).

Restore preview, group level: `invalidDisplayConfiguration`, `invalidGroup`. Per window:
`noTargetGeometry`, `coordinateConversionFailed`, `targetOutsideVisibleFrame`.

## Tests

`Tests/DockGroupsCoreTests/Layout/Layout{WindowObservation,CapturePlanner,RestorePreviewPlanner,PlannerSourceScan}Tests.swift`:
tri-state mapping, permission gates, ambiguous and unknown windows, the half-area boundary,
negative-coordinate secondary displays, primary fallback, clamping, seeded random
capture → encode → decode → preview round trips, privacy of reasons, and a source scan that keeps
AX geometry writes and side-effect APIs out of `Layout/`.

## Next slices

1. A disposable AX read experiment that fills `LayoutWindowObservation` for test fixtures only,
   including the current-Space and visibility facts the spike could not establish.
2. A reviewed read-only AX adapter conforming to `LayoutWindowObserving`, with bounded timeouts.
3. `layouts.json` integration: reader, replacement, backup and archive/delete handling per the
   storage, wire and replacement specs.
4. A writer that rechecks each window before moving it and verifies the result, only after §5 passes.

## Still not done

No AX reads or writes, no `NSScreen` query, no file I/O, no `layouts.json`, no UI, no CLI command,
no Start/Finish/trigger connection, no `SettingsBackup` change, and no user-visible text. The
current-Space, visibility and identity facts have no runtime source yet, so a real adapter may have
to report them as unknown, which makes every app ineligible until that gap is closed.
