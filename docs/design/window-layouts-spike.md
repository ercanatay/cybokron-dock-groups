# Spike: window layouts — preflight, own-window geometry and restricted AX roundtrip

- **Dates:** 2026-10-26–27. **Status:** partial evidence only; the H implementation gate is still open.
- **Baseline:** `main` at `5ca0ac2` (0.11.1, build 1101). The initial scope was the permission-free part of
  [the required Accessibility spike](window-layouts-and-cli-spec.md#5-required-accessibility-spike-before-h-code-pr).
  The restricted AX follow-up used `main` at `87ec301` with the same app version and build number.
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
Grant and revocation were subsequently exercised with a separate client as described below; denial
and the original probe's later trust state remain untested.

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
This initial sample is **not an AX coordinate measurement**: that probe did not read AX position
or size. It does not validate multi-display transforms, display matching, normalized layout
persistence or clamping.

### Own-window CG timing

| Operation, 100 samples | Median | p90 | Maximum |
| --- | --- | --- | --- |
| Describe one known own window and validate owner/ID/bounds | 0.251 ms | 0.419 ms | 10.616 ms |

These are local sample timings, including the initial cold query; they establish no latency or
timeout bound for AX calls, another application's windows or a nonresponsive process.

## Restricted AX follow-up

A separate, locally ad hoc signed client and a disposable one-window AppKit target were built
outside the repository. The client accepted only the unique target process with the expected bundle,
bundle path and executable path, used a two-second AX messaging timeout, and read no window title,
content or document path. Raw logs and signed fixtures remain local. No group data or other app's
windows were targeted.

An untrusted LaunchServices launch returned `false` from `AXIsProcessTrustedWithOptions(nil)` and
the client appeared disabled in System Settings. A user enabled the exact client; a fresh launch
returned `true`. After the experiment, its switch was disabled and another fresh launch returned
`false`. The entry remained in the list, disabled. A direct executable launch under an already
trusted shell had earlier returned `true` without a separate client grant; its responsible-app
attribution was ambiguous, so it was not used to establish client-specific permission. The user
removed an entry created before a rebuild and re-added the current ad hoc-signed bundle before
the grant worked; the cause of the initial mismatch was not proven. No
conclusion about prompt absence follows: a post-call screenshot showed no modal, but transient UI
and the user's visual observation were not independently confirmed.

The first target's AX window array contained **two** AX elements. A read-only diagnostic restricted
to that fixture found one nonminimized `AXDialog` and one nonminimized `AXStandardWindow`; the
client's one-window guard stopped before moving either. The dialog was nonmodal, 66 × 20 points,
and six points from the standard window's top-left corner. Its location resembled an on-screen
indicator, but its identity was not established. After restarting the disposable target, and
without taking a CUA screenshot or observing that target through CUA after restart, the diagnostic
found one standard window. This comparison does not establish the cause of the extra element.
The design's conservative dialog exclusion remains in force.

For the restarted target, a fresh LaunchServices client reported one standard, nonminimized window
at AX position `(100, 1040)` and size `(400, 300)` points; both geometry attributes were settable.
A single roundtrip moved the window by `(16, 16)` points and increased its size by `(24, 16)`
points. Trial writes and readback matched within one point; both original geometry writes and
restoration readback matched within one point. A separate client launch then read the original
position and size again. The test target was closed after the permission was disabled. This one
fixture on one display does not establish
other-app, multiple-display, Space, full-screen, error recovery or timing behavior. Visual
observation of the brief motion was not independently confirmed.

## Subsequent own-window eligibility and CG observations

A separate read-only AX fixture tested four window sets on macOS 27.0.1. One standard,
unminimized window was labeled only as a candidate, with visibility and Space unverified. Two
standard windows and a standard window accompanied by an `AXDialog` were skipped. A minimized
window was reported as both minimized and `AXDialog` and was skipped under the dialog rule.
The observer was launched directly from an already trusted environment; its `trusted=true`
result does not prove a separate application grant. No user-window data was read or modified.

A second fixture queried only its own known window ID with
`CGWindowListCreateDescriptionFromArray`. Passing an `NSNumber` object as an array element
returned an empty array in two attempts, using both 64-bit and 32-bit values. A subsequent build
passed the ID as an integer-sized bit pattern in a `CFArray` with nil callbacks, like the earlier
successful probe, and received exactly one dictionary matching its own PID and ID at every stage.
The resulting observations were:

| Fixture state | AppKit visible | AppKit minimized | CG on-screen key |
| --- | --- | --- | --- |
| Normal | true | false | true |
| Minimized | false | true | absent |
| Restored | true | false | true |
| App hidden | false | false | absent |

The SDK describes an absent `kCGWindowIsOnscreen` key as not ordered on screen. This one fixture
does not establish visible pixels, occlusion, current Space, full-screen or Stage Manager state.
The fixture supplied its own `NSWindow.windowNumber` and observed matching CG metadata. Apple
documents that this AppKit window-device number is not the global number assigned by the window
server; the observed match is not a documented identity guarantee. The result also does not
establish a safe way to match a different app's AX window to a CG window ID. The failed and
successful attempts occurred at different times, so the input encoding is a strong lead rather
than a controlled proof of the sole cause. No AX writes, screen capture, system-wide window list or other apps' windows were
used in this second fixture.

### Own-window geometry collision

A third fixture created two distinct standard windows in its own process at the same frame, then
queried CG metadata using only their own fixture handles. In one run on macOS 27.0.1, both CG
descriptions had the same owner PID and identical bounds, while their window numbers differed.
The fixture moved only its second window by 24 points on each AppKit axis. A second read found
the first window's CG bounds unchanged and the second window's bounds changed; the latter's
earlier geometry was therefore stale. Twenty fixture checks passed, and the fixture exited.

This controlled example shows that owner PID plus geometry is not a unique window identity and
that geometry can change between observations. It does not demonstrate an actual concurrent
time-of-check/time-of-use race, prove that rechecking makes a move safe, or establish AX-to-CG
identity. No other app's windows, AX calls, screen capture, or system-wide window list were used.
The original H gate remains open.

### Own-window position swap

A fourth fixture placed two same-sized windows belonging to its own process at different
positions, then exchanged their positions and queried only their known fixture handles. In one
run on macOS 27.0.1, both handles remained stable: each window's final CG bounds matched the
other window's initial bounds. The unordered set of bounds was unchanged while the mapping from
fixture handle to bounds changed. All 28 fixture checks passed and the process exited.

This controlled example shows that the same set of geometries does not establish that the same
window remains at each position. It did not query AX identities, demonstrate an actual
concurrent race, or establish an AX-to-CG identity mechanism. No other app's windows,
system-wide window list, screen capture or AX calls were used. Space and third-party behavior
remain untested; the H gate stays open.

## Required work still open

| Gate from design §5 | Status |
| --- | --- |
| Prompt-free untrusted preflight | **Unverified**: the original system warning/TCC record and incomplete UI observation remain |
| Explicit permission grant, denial, revocation and relaunch | Grant and disable/relaunch observed for the separate fixture; denial and original-probe follow-up remain open |
| Untrusted AX enumeration failure and clear recovery path | Not run; no AX enumeration attempted |
| `kAXWindowsAttribute`, role/subrole, minimized, position and size | Read for the restricted fixture; other apps and eligibility cases remain open |
| Position/size writability via `AXUIElementIsAttributeSettable` | Both settable for the single fixture window; refusal cases remain open |
| Normal and deliberately unresponsive app response times; bounded AX timeout | Not run |
| One-window AX move/resize and geometry read-back, including refusal/partial results | One fixture roundtrip and independent restore readback passed; refusal and partial cases remain open |
| Reliable exclusion of multiple plausible windows, dialogs, minimized/full-screen windows, other Spaces, split view and Stage Manager | Own-window fixtures skipped multiple, dialog and minimized cases; current Space, Stage Manager and broader cases remain unclassified |
| Two displays, unplug/replug, changed scaling/resolution/rotation, left/right arrangement and primary-display fallback | Not run |
| Dock/menu bar changes, `visibleFrame` clamping and per-app minimum/maximum sizes | Not run; only the current static visible frame was observed |
| macOS 14, 15 and 26 | No runtime results |
| macOS 27 | Restricted own-window preflight, permission cycle and one AX fixture roundtrip above |

**Decision:** this partial experiment is not a go decision for H. One successful fixture roundtrip
does not prove that a current-Space, visible standard window can be selected safely across apps.
Resolve prompt-observation uncertainty and complete the eligibility, timeout, refusal and
OS/display matrix before production window-moving implementation.

## API references

- Apple: [`AXIsProcessTrustedWithOptions`](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions).
- Apple: [`kAXWindowsAttribute`](https://developer.apple.com/documentation/applicationservices/kaxwindowsattribute).
- Apple: [`CGWindowListCreateDescriptionFromArray`](https://developer.apple.com/documentation/coregraphics/cgwindowlistcreatedescriptionfromarray(_:)).
- Apple: [`NSWindow.windowNumber`](https://developer.apple.com/documentation/appkit/nswindow/windownumber).
- Apple: [`NSScreen.visibleFrame`](https://developer.apple.com/documentation/appkit/nsscreen/visibleframe).
- SDK headers inspected: `AXUIElement.h`, `CGWindow.h`, `CGDisplayConfiguration.h` and
  `CGDirectDisplay.h` from the macOS 27.0 SDK. `CGWindow.h` defines the CG bounds origin at the
  upper-left of the main display; this describes CG, not a completed AX runtime test.
