# Design spec: group window layouts (H) and command-line interface

- **Status:** draft for review (2026-10-26). Design and API research only; neither feature is implemented.
- **Baseline:** `main` at `61c763c` (0.11.1, build 1101). This document describes proposed behavior, not a release promise.
- **Scope:** an explicit, per-group window layout on the current desktop; a bundled CLI that dispatches the existing `start`, `finish`, and `open` links and reports whether the app is running.
- **Gate:** no window-moving implementation PR until the Accessibility spike in §5 passes on the actual macOS releases and window managers we support.

## 1. User behavior and proposed decisions

1. **One saved layout per active group.** The user chooses **Save Window Layout** in the group window. Saving replaces that group's previous layout after a review of the eligible windows. Nothing is sampled in the background. Archiving keeps a layout dormant; deleting the group deletes its layout.
2. **Explicit restore.** The group window offers **Restore Window Layout** after the group is started or its apps are already running. Start, Finish, triggers, Focus, Siri, links, and the CLI never move windows implicitly in the first release. The UI shows a preview/count and the destination displays before the user confirms. A later opt-in automatic mode needs its own review.
3. **Conservative window matching.** The first implementation targets one standard, visible, unminimized window per app in the current Space. If an app has multiple plausible windows, a dialog, a full-screen window, a window in another Space, or an unidentifiable window, it is skipped with a reason. The spike must prove that those exclusions are reliable; if not, ship a smaller tested subset or postpone H. Window titles and contents are never read, stored, logged, or used for matching.
4. **Displays are best effort.** Save a rectangle relative to the display's `visibleFrame`, with current display topology and dimensions as hints rather than a permanent monitor identity. If matching is ambiguous or a display is absent, propose the primary display and clamp inside its current `visibleFrame`; show the fallback in the preview. Do not move a window until the user confirms. Never create or switch Spaces, alter Stage Manager, or change display settings.
5. **Accessibility is opt-in at point of use.** Save and Restore explain the macOS Accessibility permission and provide the system settings link. They do not prompt at launch and do not request Screen Recording. If access is absent or revoked, do not save a partial layout or move anything; show the grant/retry path.
6. **CLI names are literal.** `cybokrondockgroups open <group>` shows the group's popup, matching `cybokrondockgroups://open/<group>`; it does not run Open All. `start` and `finish` dispatch the existing transition links, including their confirmation behavior. `<group>` accepts an active group's UUID or name. Shell metacharacters are data, never executable input.
7. **CLI status is intentionally narrow.** `cybokrondockgroups status` reports the installed app version and whether the main app is running, with a stable machine-readable exit code. It does not claim a current group or command completion: that session state is in the running app, and URL delivery has no response channel. A future richer status requires an authenticated local IPC design.

These are **proposed** product decisions. They require user review before implementation; the technical spike may narrow H further.

## 2. Acceptance criteria

### H — Window layouts

- Saving lists only eligible apps already present in the active group and currently running. A group without eligible windows receives an explanation and no empty snapshot. Saving again replaces exactly that group's snapshot.
- Restoring never launches an app, quits an app, restores a minimized window, raises a window, or alters a protected app. It skips changed or missing windows and reports moved/skipped/failed counts with reasons.
- Before each move, recheck the running process, window eligibility, writability of position and size, target display, and current geometry. A stale AX element or nonresponsive app is skipped after a bounded timeout. A failure in one app does not block another; no unrequested retry loop runs.
- Capture skips windows with less than half their area in the current display's `visibleFrame`; the saved rectangle is finite, positive, normalized to that visible area, and clamped on restore. Position/size writes are verified by reading the resulting geometry; a window that refuses or adjusts the size is reported as partial, not success. Respect each app's own minimum/maximum size.
- Capture and restore have no effect on other Spaces or full-screen windows. Display unplug/replug, changed resolution/scaling, Dock/menu bar movement, Stage Manager, and multiple monitors need explicit manual cases. If the spike cannot distinguish these cases, H remains experimental.
- Layout data stays local in a separate `layouts.json` document keyed by group UUID. It contains bundle identifiers, sanitized normalized geometry, and display matching data only: no window title, screenshot, URL, document path, or raw AX object. Import/export and downgrade rules are specified before UI integration; imported layouts cannot auto-run.

### CLI — first release

- Syntax: `cybokrondockgroups start <group>`, `finish <group>`, `open <group>`, `status`, `--help`, `--version`. Exactly one group argument for the first three; missing/extra/unknown verbs fail before URL dispatch. Names containing spaces, slashes, Unicode, `?`, `#`, and `%` are encoded as one group argument and resolved by the app's existing `GroupLookup`.
- The CLI is bundled with the app. The first release documents the full executable path and a user-created `PATH` link; installation never edits a shell profile or privileged directory silently. Test both the SwiftPM wrapper and Xcode app packaging.
- Dispatch commands use the same `LinkCommand` path and five-second URL cooldown as browser links. A zero exit code means macOS accepted the URL dispatch, **not** that the group existed, a confirmation was accepted, or a transition finished. Stderr and documentation use that wording. A closed app may be launched by LaunchServices; launch triggers remain suppressed for URL launches.
- `status` resolves the app bundle containing the CLI (including through a user-created symlink), reads that bundle's version, and checks for that bundle's running main-app identity; it does not parse user group files. It prints `running VERSION` or `stopped VERSION` and works when the app is closed. Exit codes: `0` for a running status or accepted URL dispatch, `2` for bad arguments, `3` for a stopped status or dispatch failure. No group names or private paths in default output. No `quit`, `force`, arbitrary URL, script, or shell execution command is added.

## 3. Existing architecture and integration seams

| Area | Existing behavior | Proposed seam |
| --- | --- | --- |
| AX windows | `WindowRestorer` / `SystemWindowAccessibility` enumerate `kAXWindowsAttribute` and only unminimize/raise. | Extend through a separate geometry-reading/writing protocol and fakes; do not add positioning to `WindowRestorer`. |
| Capture | `SystemOpenAppsReader` reads CG window owner/bounds without a permission; its window-presence heuristic is intentionally approximate. | Reuse app filtering, but do not treat that heuristic as proof of a specific AX window or Space. |
| Groups | `GroupStore` owns active/archived groups; `groups.json` remains format 1. | Separate `layouts.json` and a coordinator that only acts on active groups; purge on delete, keep on archive. |
| Backup | Existing backup imports sanitize groups, templates, and disabled triggers. | Add an optional layout payload with bounds/count validation, dormant on import; older app versions ignore the separate file. |
| URL links | `URLCommand` / `SwitchingURLCommand` parse and gate `open`, `start`, and `finish`; `AppDelegate` handles them. | CLI builds a URL with `URLComponents`; the app remains the sole executor. `status` is local/read-only. |
| Build | SwiftPM creates the app executable; `project.yml` generates the Xcode project; `build-app.sh` wraps and signs the bundle. | Package the CLI in both build paths and verify its signature and invocation from the installed app. |

## 4. Security, privacy, and compatibility

- Accessibility permission belongs to the signed app doing AX work. A separate CLI must not acquire it or touch other apps' windows. Do not ask for Apple Events or Screen Recording as a fallback.
- AX calls communicate with another process and may return unsupported, invalid-element, or cannot-complete errors. Bound each call, validate every return and type, and keep AX operations off the UI's synchronous path. Never rely on undocumented AX window numbers or window titles for matching.
- The existing link gate is a rate limit, not an authorization boundary. The CLI may invoke only the three documented URLs; it must not create a second, less guarded execution path or bypass confirmation. Treat URL dispatch as asynchronous.
- Layout imports are untrusted JSON. Reject unknown format versions, unbounded arrays, duplicate group/window records, nonfinite/out-of-range coordinates, and non-app bundle identifiers. Preserve unreadable data before reset, as other stores do. Avoid leaking names or paths in logs and CLI output.
- Existing `groups.json` and `preferences.json` formats stay unchanged. An old version must neither parse nor delete `layouts.json`; verify this in a real downgrade copy. A layout snapshot never enables itself after restore/import.

## 5. Required Accessibility spike (before H code PR)

Use a separate, temporary signed test app and ordinary test windows, never the user's saved group data. Its permission is separate from the released app. Record results per macOS 14, 15, 26, and 27 where available; missing platforms remain manual gates.

1. With Accessibility access absent, call `AXIsProcessTrustedWithOptions(nil)` only; verify no prompt from enumeration attempts and a clear failure. Grant access explicitly for the spike app, then verify revocation/relaunch behavior.
2. Enumerate `kAXWindowsAttribute`; read role/subrole, minimized, position and size; check `AXUIElementIsAttributeSettable` for geometry. Do not read title. Measure response/timeout for a normal app and a deliberately unresponsive one.
3. Move and resize one ordinary test window, then read back. Test an app with two windows, minimized/full-screen windows, another Space, Stage Manager, split view, and a dialog. Determine whether a current-Space visible standard window can be identified without a private API or title. **Failure to do so blocks the proposed first H release.**
4. Test two displays, unplug/replug, resolution/scaling changes, left/right placement, Dock/menu bar changes, and clamping to `visibleFrame`. Document AX top-left versus AppKit display coordinates with measured examples.
5. Repeat with an app that refuses one or both geometry attributes. Verify the user sees a skip/partial result and no loop, focus steal, or accidental move of another window.

## 6. Implementation plan and release gates

1. **Spike PR:** documentation and disposable probe only; record a go/no-go matrix. No production AX writer.
2. **H Core PR:** layout model, bounded planner, persistence/import sanitation, geometry abstraction and fakes. No UI or permission prompt.
3. **H App PR:** Save/Restore UI, explicit permission path, AX adapter, previews/results. Manual matrix in §5 and downgrade copies before release.
4. **CLI PR:** small executable, URL encoding/validation, status, packaging in SwiftPM and Xcode, README, tests. Keep CLI independently releasable if H remains blocked.
5. **Localization/release:** 26 languages through the project translation helper, packaged-app verification, CI/CodeQL, signing/notarization, and the release manual gates. No version bump or release is implied by this spec.

## 7. Evidence and API references

- Local macOS 27.0 SDK (`Xcode 27.1`) `AXAttributeConstants.h` documents `kAXPositionAttribute` and `kAXSizeAttribute` as point-based AX values that movable/resizable windows **should** make writable, not guaranteed writable; its `AXValue.h` provides `AXValueCreate`/`AXValueGetValue`. This is header review, not a runtime test.
- Apple: [Accessibility trust check](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions), [AXUIElement APIs and errors](https://developer.apple.com/documentation/applicationservices/axuielement_h), [position](https://developer.apple.com/documentation/applicationservices/kaxpositionattribute), [size](https://developer.apple.com/documentation/applicationservices/kaxsizeattribute), [setting attributes](https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue).
- Apple: [`NSScreen.visibleFrame`](https://developer.apple.com/documentation/appkit/nsscreen/visibleframe) can change as the Dock/menu bar changes; [`NSScreen.screens`](https://developer.apple.com/documentation/appkit/nsscreen/screens) changes with display configuration.
- Apple: [`CGWindowListCopyWindowInfo`](https://developer.apple.com/documentation/coregraphics/cgwindowlistcopywindowinfo%28_%3A_%3A%29) supplies window metadata; Apple [describes window names as privacy-sensitive](https://developer.apple.com/videos/play/wwdc2019/701/?time=1995). This feature does not read or store names.
