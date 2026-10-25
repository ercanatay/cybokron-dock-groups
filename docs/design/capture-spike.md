# Spike: reading the open apps and their windows without a permission (capture PR 1)

- **Date:** 2026-10-25. **Mac:** Mac16,11, macOS 27.0.1 (26A434), one 2560 × 1440 display, Xcode 27.1
  (27A9275), macOS 27.0 SDK. Stage Manager off.
- **Questions** (`docs/design/capture-spec.md` §2.3, §5, §8 PR 1): does reading the running apps and
  the window list ask for a permission; how long does a snapshot take; how well does "has an open
  window" work without the Accessibility API?
- **Method:** a throwaway app bundle (`com.cybokron.dockgroups.capturespike`, `LSUIElement`, ad hoc
  signed, built against this branch's `DockGroupsCore` and launched with `open`, so it is its own
  responsible process for TCC) ran `SystemOpenAppsReader` and `CapturePlanner` 100 times, dumped the
  layer-0 windows of every regular app (owner, bounds, alpha, on-screen flag — never names), and
  launched Calculator, hid it and read again. `log stream --level debug` recorded the `com.apple.TCC`
  subsystem during the run. Nothing of the spike is in the repository. The app's own TCC entries
  (`com.cybokron.dockgroups`) were **not** reset: that would drop the user's Accessibility grant for
  restoring windows; the spec's TCC-reset check of the real app stays a manual gate in PR 2, when
  capture has surfaces.

## Permissions: none asked for

Every TCC request involving the spike during the run, from the stream:

| From | Service | Kind | Result |
| --- | --- | --- | --- |
| the spike, at launch | `kTCCServiceListenEvent` | `preflight=yes` | `authValue=1` (unknown), no prompt |
| WindowServer, for the spike, at launch | `kTCCServiceListenEvent` | `preflight=yes` | `authValue=1`, no prompt |
| WindowServer, for the spike, at the first window list read | `kTCCServiceScreenCapture` | `preflight=yes` | `authValue=1`, no prompt |

- No request without `preflight=yes` appeared in the whole stream (0 of 524 lines), and nothing for
  `kTCCServiceAccessibility` or `kTCCServiceAppleEvents` came from the spike.
- The Input Monitoring preflights are what every app gets at launch: Calculator and the `open`
  command's Terminal showed the same pair. They aren't caused by capture's code.
- The Screen Recording preflight is the window server deciding whether to add window names to the
  list: it didn't (8 of 390 windows of other processes carried a name, the system's own UI), and
  capture never reads the key anyway (`CapturePermissionTests`).
- So `NSWorkspace.runningApplications` and `CGWindowListCopyWindowInfo` (owner, layer, bounds,
  alpha, on-screen) need no permission and show no prompt on macOS 27. **Manual (PR 2):** the same on
  macOS 14, 15 and 26 with the real app after `tccutil reset` of Accessibility and Screen Recording.

## Timing (100 runs; 325 processes, 28 regular apps, 390 windows, 32 on screen)

| Step | Median | p90 | Max |
| --- | --- | --- | --- |
| every process's properties (the first reader) | 10.09 ms | 10.35 ms | 53.58 ms |
| `openApps()`, regular apps only (as shipped) | 0.27–0.33 ms | 0.46–0.62 ms | 0.97–2.76 ms |
| `windows()` (two window list reads) | 6.8–7.6 ms | 8.7–10.3 ms | 19.8–21.1 ms |
| `CapturePlanner.plan` | 1.3–1.5 ms | 1.8 ms | 3.0 ms |
| snapshot + plan | 8.5–9.5 ms | 11.0–13.0 ms | 21.9–22.9 ms |

Reading `bundleURL`, `localizedName` and `launchDate` of all 325 processes cost about 10 ms; reading
them only for the 28 regular ones, after checking `activationPolicy`, costs a third of a
millisecond. **Decision:** `SystemOpenAppsReader.openApps()` returns regular apps only (the planner
never lists or counts the others). The median snapshot is then within §5's 10 ms budget; the window
server is most of what's left, once per capture.

## "Has an open window" (spec R1)

The window list as the spec planned it (layer 0, alpha above 0, at least 50 × 50 points, on screen
or not) said **every** regular app but one had windows: each app keeps invisible helper windows off
screen.

| Off-screen layer-0 windows seen in (almost) every app | Size | Position |
| --- | --- | --- |
| menu bar strips, 4 per app | screen width × 30 | 0, 0 |
| helper squares, 1–2 per app | 500 × 500, 64 × 64, 370 × 370 | x = 0 (y = 940 or 1012) |
| small helpers | 53 × 48, 400 × 33, 288 × 26, 1 × 1, 0 × 0 | anywhere |

Windows that really are there but off screen keep the place they were shown at: Calculator, hidden,
kept its 230 × 408 window at 1382, 750 (`kCGWindowIsOnscreen` absent). TextEdit and Passwords, with
nothing on screen, each had one window of about 1100 × 700 mid-screen — minimized, on another Space
or kept after closing; the list can't say which. No window had alpha 0, and every window had the
same memory, store and sharing values, so those tell nothing apart.

**Decision:** an off-screen window that is a **square at x = 0** doesn't count (`WindowSnapshot`);
the 50-point rule already drops the strips and small helpers. On this Mac that moved the two apps
whose only off-screen windows were helpers (a word processor and a remote-desktop app) to "No open
windows", next to Pages (no windows at all), and changed nothing else: hidden Calculator still has
windows (`hidden` note, still selected with the window option on). It's still a heuristic — it
only decides the first selection (Decision 4) — and the helpers' sizes may differ on other macOS
versions.

**Not measured here, manual in PR 2** (each needs the Accessibility API or Apple Events to set up,
or a person): minimized windows, windows on another Space, a full-screen app, Stage Manager, and
macOS 14, 15 and 26.

## Other observations

- Two instances with the same bundle identifier (two copies of a browser) became one candidate, and
  Finder was left out: 28 regular apps → 26 candidates, 0 unavailable.
- The app the spike was launched from (Terminal, through `open`) was among the first two in the
  on-screen order, as §2.6 expects for the opener of a link.
