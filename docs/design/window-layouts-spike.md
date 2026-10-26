# Spike: window layouts — permission-free preflight and own-window geometry

- **Date:** 2026-10-26. **Status:** partial evidence only; the H implementation gate is still open.
- **Baseline:** `main` at `5ca0ac2` (0.11.1, build 1101). Scope is the permission-free part of
  [the required Accessibility spike](window-layouts-and-cli-spec.md#5-required-accessibility-spike-before-h-code-pr).
- **Environment actually run:** macOS 27.0.1 (26A434), arm64, Xcode 27.1 (27A9275), macOS 27.0 SDK.
  No result here establishes behavior on macOS 14, 15 or 26.
- **Method:** a disposable app outside the repository, with its own unique bundle identifier,
  was launched through LaunchServices in the background. It created one ordinary titled,
  resizable test window, read only that window's CG metadata and the current screen geometry,
  then closed its window and exited. Probe source and raw evidence remain local, outside the
  repository; private paths, identifiers and signing details are not included here.

## Scope and permission observation

The probe made exactly one Accessibility call: `AXIsProcessTrustedWithOptions(nil)`, before
creating the window. It returned **false**, in **6.32 ms**. No prompt option, permission-grant
call, TCC reset, System Settings change, AX element creation, AX attribute read or AX write was
issued by the probe. It did not open the installed app, read group data or operate on user windows.

**The no-prompt gate is unverified.** The captured TCC evidence includes a system
`universalAccessAuthWarn` / `TCCAccessSetInternal` record for the disposable app, with
`has_prompted_for_allow=false` and `authset_by_disclosure_prompt=false`. Those fields do not
establish that no warning UI appeared. The own-bundle-filtered stream contained no
`AUTHREQ_PROMPTING` marker, but that narrow filter is not proof of complete UI behavior. No
independent UI observation established prompt absence. Runtime probing was stopped after this
finding was identified; it was not repeated or extended to AX operations.

There was **no post-probe trust recheck**. The `false` field in the final geometry result is the
stored initial preflight result, not a second call or evidence about the later permission state.
Grant, denial, revocation and relaunch behavior remain untested.

## Measurements obtained

The CG query used `CGWindowListCreateDescriptionFromArray` with only the test window's known
window ID. Each result had to contain exactly one window and match the probe's own process and
window before any geometry was accepted. No session-wide window list, window title, owner name,
window image, document path or AX object was read or saved.

All **100** samples matched that own window. Its CG layer was **0**, alpha **1**, and on-screen
flag **true**. The fixture was not minimized. At measurement time the app was **inactive** and
its window was **not key**; no activation or make-key call was made. These are fixture
observations, not proof of safe classification or behavior for another application's windows.

### Current display configuration

Only one external display was present. Display configuration was read, not changed.

| Value | Observed |
| --- | --- |
| AppKit screen frame | `(0, 0, 2560, 1440)` points |
| AppKit `visibleFrame` | `(0, 59, 2560, 1351)` points |
| CG display bounds | `(0, 0, 2560, 1440)` |
| Backing scale factor | `2` |
| Current mode dimensions | `2560 × 1440` |
| Current mode pixel dimensions | `5120 × 2880` |
| Mode refresh rate reported by the API | `60 Hz` |

The refresh-rate value describes the reported mode, not a measured refresh-timing test. No
display serial number, UUID, model name or persistent display identifier was collected for this
report.

### One coordinate example

Rectangles below are `(x, y, width, height)` for the whole window frame, including its decoration:

| Coordinate space | Observed rectangle |
| --- | --- |
| AppKit, bottom-left origin | `(80, 159, 360, 252)` |
| Expected CG rectangle from the AppKit frame | `(80, 1029, 360, 252)` |
| CG own-window bounds | `(80, 1029, 360, 252)` |

For this primary screen, `cgY = 1440 - (159 + 252) = 1029`; x and size were unchanged. The
AppKit-to-CG result matched exactly. The two-times backing scale did not double these CG bounds.
This is **not an AX coordinate measurement**: AX position and size were never read. It does not
validate multi-display transforms, display matching, normalized layout persistence or clamping.

### Own-window CG timing

| Operation, 100 samples | Median | p90 | Maximum |
| --- | --- | --- | --- |
| Describe one known own window and validate owner/ID/bounds | 0.251 ms | 0.419 ms | 10.616 ms |

These are local sample timings, including the initial cold query; they establish no latency or
timeout bound for AX calls, another application's windows or a nonresponsive process.

## Required work still open

| Gate from design §5 | Status |
| --- | --- |
| Prompt-free untrusted preflight | **Unverified** because of the system warning/TCC record above; no later trust check |
| Explicit permission grant, denial, revocation and relaunch | Not run |
| Untrusted AX enumeration failure and clear recovery path | Not run; no AX enumeration attempted |
| `kAXWindowsAttribute`, role/subrole, minimized, position and size | Not run |
| Position/size writability via `AXUIElementIsAttributeSettable` | Not run |
| Normal and deliberately unresponsive app response times; bounded AX timeout | Not run |
| One-window AX move/resize and geometry read-back, including refusal/partial results | Not run |
| Reliable exclusion of multiple plausible windows, dialogs, minimized/full-screen windows, other Spaces, split view and Stage Manager | Not run; current Space and Stage Manager were not classified |
| Two displays, unplug/replug, changed scaling/resolution/rotation, left/right arrangement and primary-display fallback | Not run |
| Dock/menu bar changes, `visibleFrame` clamping and per-app minimum/maximum sizes | Not run; only the current static visible frame was observed |
| macOS 14, 15 and 26 | No runtime results |
| macOS 27 | Only the restricted preflight/own-window measurements above |

**Decision:** this partial experiment is not a go decision for H. The own-window CG sample does
not prove that a current-Space, visible standard window can be selected safely through AX.
Resolve the prompt-observation uncertainty in an observed manual session before extending the
spike, then complete the eligibility, timeout, write/read-back and OS/display matrix. No
production window-moving implementation is justified by these results.

## API references

- Apple: [`AXIsProcessTrustedWithOptions`](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions).
- Apple: [`CGWindowListCreateDescriptionFromArray`](https://developer.apple.com/documentation/coregraphics/cgwindowlistcreatedescriptionfromarray(_:)).
- Apple: [`NSScreen.visibleFrame`](https://developer.apple.com/documentation/appkit/nsscreen/visibleframe).
- SDK headers inspected: `AXUIElement.h`, `CGWindow.h`, `CGDisplayConfiguration.h` and
  `CGDirectDisplay.h` from the macOS 27.0 SDK. `CGWindow.h` defines the CG bounds origin at the
  upper-left of the main display; this describes CG, not a completed AX runtime test.
