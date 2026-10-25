# Spike: triggers (phase 4b)

Results of the spikes in `docs/design/triggers-spec.md` §2.3 (TS-1 … TS-11). Each PR adds the ones it
needs; PR 1 ran TS-1, PR 2 TS-2, TS-3 and TS-4 (TS-10 is a manual gate), PR 3 TS-5 and TS-6.

## TS-1: how late a one-shot timer fires in a windowless menu bar app (PR 1)

- **Date:** 2026-10-25. **Mac:** Mac16,11 on AC power, macOS 27.0.1 (26A434), Xcode 27.1 (27A9275).
  System sleep and display sleep were held off by other apps during the runs (`pmset -g`), so
  nothing slept.
- **Question:** the clock source arms one timer for the next due time (spec §2.4, §5). How late does
  it fire in an `LSUIElement` app with a menu bar item and no windows — the app's situation, where App
  Nap may throttle timers — and does a `ProcessInfo` activity begun 90 seconds before the due time
  help (R1)?
- **Method:** a throwaway app bundle (`com.cybokron.dockgroups.ts1spike`, `LSUIElement`, a status
  item, no window, ad hoc signed with the hardened runtime, launched with `open` so it's its own
  process for App Nap) armed one-shot `Timer`s on the main run loop in common modes, due 120 or 150
  seconds apart from launch. The odd ones got
  `ProcessInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep)` 90 seconds before they
  were due (ended when they fired), the even ones nothing. It logged when each timer fired against
  its due time. The app was in the background the whole time (never activated); the Mac was in use
  meanwhile. Nothing of the spike is in the repository.
- **Runs:** tolerance 10 seconds (8 timers, 120 s apart, 16 minutes) and tolerance 1 second (6
  timers, 150 s apart, 15 minutes), side by side.

| Tolerance | With the activity (late by) | Without (late by) |
| --- | --- | --- |
| 10 s | 10.000, 10.000, 10.002, 10.002 s | 10.000, 10.001, 10.003, 10.003 s |
| 1 s | 0.999, 1.004, 1.004 s | 1.003, 1.006, 1.005 s |

### Findings

1. **Timers fire at the end of their tolerance, every time.** The system coalesces them to the latest
   moment the tolerance allows: a 10-second tolerance means 10 seconds late, not "up to". The spec's
   10 seconds (§2.4, §5) would make every 9:00 run at 9:00:10.
2. **The activity changed nothing here:** with and without it, the lateness was the tolerance to
   the millisecond. No further throttling showed up over 15–16 minutes in the background. The app's
   scheduling priority (`ps -o pri`) stayed 46 throughout; whether App Nap was engaged can't be read
   without root (`taskinfo` needs it), so "no extra delay" is what was measured, not "no App Nap".
3. On battery, a laptop and longer idle periods may throttle more: not measured (no laptop on this
   Mac's desk).

### Decision for PR 2

- The clock source arms its timer for the due time with a **tolerance of 1 second** (not 10): a
  9:00 trigger runs at 9:00:01. One timer at a time, so the energy cost is one wake-up per due time.
- The 90-second activity stays out unless the manual gate on a laptop on battery shows timers firing
  more than 60 seconds late; then it's begun 90 seconds before the due time and ended once the timer
  fired, as the spec planned.
- **Manual gate (PR 2):** a MacBook on battery, the lid open and the app idle for an hour before a
  due time; record the lateness with and without the activity.

## TS-2, TS-3, TS-4: Open at Login and how a launch counts (PR 2)

- **Date:** 2026-10-25. **Mac:** Mac16,11 on AC power, macOS 27.0.1 (26A434), Xcode 27.1 (27A9275).
- **Method:** a throwaway app bundle (`com.cybokron.dockgroups.ts24spike`, `LSUIElement`, a URL
  scheme and a plain-text document type, ad hoc signed with the hardened runtime, registered with
  `lsregister`) that logged, in `applicationWillFinishLaunching`, `applicationDidFinishLaunching`
  and `application(_:open:)`: `NSApplicationLaunchIsDefaultLaunchKey`, the current Apple event
  (its ID and its `keyAEPropData`, which is `keyAELaunchedAsLogInItem` for a login item), the
  console login session's start (the latest `USER_PROCESS` record on `console` for the user, from
  `getutxent`), the process's launch date, and `SMAppService.mainApp.status`; an environment
  variable made it `register()` or `unregister()`. It quit itself after 2 seconds. It was deleted
  and unregistered from LaunchServices afterwards; nothing of it is in the repository.

### TS-4: what each kind of launch looks like

| Launch | `isDefaultLaunch` | Event in `didFinishLaunching` | URL or document |
| --- | --- | --- | --- |
| `open App.app` (Finder's way) | true | `oapp`, no `propData` | — |
| `/usr/bin/open <path>` (the updater's and the language restart's helper) | true | `oapp`, no `propData` | — |
| `NSWorkspace.openApplication(at:)` | true | `oapp`, no `propData` | — |
| `open -a App.app <scheme>://…` (a link) | **false** | none | `GURL`, delivered **before** `didFinishLaunching` |
| `open -a App.app doc.txt` (a document) | **false** | none | `odoc`, delivered before `didFinishLaunching` |

(`open -u <scheme>://…` without `-a` failed with -10814: LaunchServices didn't bind the scheme to a
copy in a temporary folder; with `-a` it's the same launch a link makes.)

Findings:

1. A link or a document launch is told apart already: its URL arrives first, and macOS says it
   isn't a default launch. The updater's and the language restart's relaunch look exactly like a
   Finder launch (`oapp`, default): only the quiet-launch marker the app leaves before them tells
   them apart. A Siri or Shortcuts intent wasn't measured (it needs the app's intents registered);
   the app notes intents itself.
2. `NSApplicationLaunchIsDefaultLaunchKey` is also false for a launch that restores state, per its
   documentation, so it isn't used: the 5-second launch settle with "a URL or an intent came" is
   enough and covers intents too.

### TS-2: `SMAppService.mainApp` for an ad hoc signed copy

| Step | `status` |
| --- | --- |
| never registered | 3 (`notFound`) |
| `register()` — returned without error | 1 (`enabled`) |
| next launch | 1 |
| replaced in place by another build (another code hash, CFBundleVersion 2; the old copy moved aside and the new one moved in, as `UpdateInstaller` does), opened with `/usr/bin/open <path>` | 1 |
| the app moved to another folder and opened there | 1 |
| `unregister()` | 0 (`notRegistered`) |
| next launch | 0 |

Findings:

1. Registering works for an ad hoc signed copy with the hardened runtime: `register()` returned
   without an error and without a question. Whether macOS showed its "login item added"
   notification wasn't recorded.
2. The status stays `enabled` after an in-place replacement with another code hash and after a
   move: nothing to re-register after an update.
3. Not measured here: a Developer ID copy (the release), the user turning it off in System
   Settings → General → Login Items (`requiresApproval` is expected; the pane says so and links
   there), and whether macOS really opens a replaced or moved copy at the next login — all need a
   logout or a signed build: **manual gates** for PR 2 (below).

### TS-3: telling a login

1. The console session start reads correctly without any permission: 2026-10-22 15:35:56 UTC, as
   `who` shows for `console`. A launch's distance from it is what "at login" can rest on.
2. Whether `keyAELaunchedAsLogInItem` arrives for `SMAppService.mainApp` and for a Login Item added
   by hand couldn't be measured without logging out: **manual gate**.

### Decisions for PR 2

- Open at Login is `SMAppService.mainApp`, offered for every copy (ad hoc ones too: TS-2 showed it
  works); it's only ever changed by the user's click, and its status is read again when Settings →
  Triggers shows and when the app becomes active. No re-registration after updates.
- The launch is told 5 seconds after `applicationDidFinishLaunching`
  (`LaunchClassifier`): a URL or an intent during that time → quiet; otherwise a login when the
  open-application event says login item, or when the launch is within −60 s … 5 minutes of the
  console session start (the session start is the login's identity, so At Login runs once per
  session); otherwise normal. The quiet-launch marker (2 minutes, written right before the
  updater's and the language restart's relaunch) comes on top.
- `NSApplicationLaunchIsDefaultLaunchKey` isn't read.

## TS-10: a Shortcuts automation starting a group while the app is quit (PR 2, manual)

Not run: it needs a Shortcuts automation made in the Shortcuts app's interface (Automation → Time of
Day → Run Immediately → Start Group) and a wait for it to fire, which a script can't set up. Until
it's recorded, the README's recipe and Settings → Triggers only say an automation *can* start a
group on macOS 26 and later.

## TS-5, TS-6: display identity and displays across sleep (PR 3)

- **Date:** 2026-10-25. **Mac:** Mac16,11 (Mac mini, no built-in display) on macOS 27.0.1 with one
  external monitor; display sleep was held off by other apps (`pmset -g`: "display sleep prevented
  by …"), so nothing slept during the runs.
- **Method:** a throwaway command-line tool (nothing of it is in the repository) read, twice a
  second apart: `NSScreen.screens` with each screen's `NSScreenNumber`, `localizedName`,
  `CGDisplayVendorNumber`, `ModelNumber`, `SerialNumber`, `IsBuiltin`, `IsAsleep`, `IsInMirrorSet`,
  `MirrorsDisplay`, `IsMain`, `IsOnline`, `IsActive`, and `CGGetOnlineDisplayList` /
  `CGGetActiveDisplayList`.

### Findings

1. The monitor reads as `VX2776-4K-mhd`, vendor 23139, model 28983, serial 16843009 (0x01010101 —
   the placeholder `DisplayIdentity` drops), not built in, not in a mirror set; the same both times,
   and the online and active lists hold the same one display. No prompt, no permission.
2. With the placeholder serial, the identity is vendor + model + name: two of these monitors would be
   two of the same kind (`DisplayArrangement` counts them; the chooser offers them once).
3. **Not measured here — manual gates:** unplugging and plugging it again, through a dock and
   another port; a second, identical monitor; a MacBook's built-in display and clamshell mode;
   Sidecar and AirPlay displays (whether `NSScreen` lists them, and as built in or not); mirroring
   (whether `NSScreen` lists a mirror set's displays, which These Displays counts); and TS-6, whether
   an external monitor leaves and rejoins the screen list when the screens sleep and wake. Display
   sleep can't be started here without putting the user's screen to sleep.

### Decisions for PR 3

- `DisplaySource` reads `NSScreen.screens` (the `NSScreenNumber` of each, then the four CoreGraphics
  numbers and `localizedName`) 2 seconds after the last `didChangeScreenParameters`; an empty list is
  "unknown", never "every display disconnected".
- TS-6 isn't measured, so the spec's fallback is in from the start: nothing is read while the
  screens or the Mac sleep (`screensDidSleep`, `willSleep`), and after `screensDidWake` / `didWake`
  nothing is read for 5 seconds, however the screen list changes meanwhile. The reading after the
  wake is compared with the set kept from before the sleep (per trigger, in `trigger-state.json`),
  so a monitor that rejoined makes no edge.
- The source runs only while a display trigger can run (`TriggerSourceNeeds`).

## Manual gates still open (record before 0.11.0)

1. **TS-1 on battery:** a MacBook on battery, the lid open, the app idle for an hour before a due
   time: how late the timer fires. Over 60 s late → the 90-second activity before due times.
2. **TS-2:** a Developer ID copy: Open at Login on → log out and in → the app opens. Turn it off in
   System Settings → General → Login Items → Settings → Triggers shows it off or "needs your
   approval". After an update installed by the app and after moving it: still opens at login.
3. **TS-3:** with Open at Login on, log out and in: At Login runs once; reopening the app later
   doesn't run it. With the app added by hand to Login Items: same. Log in with the app quit and open
   it 10 minutes later: When … Opens runs, At Login doesn't.
4. **TS-4:** a Siri or Shortcuts request that launches the quit app: no When … Opens trigger.
5. **TS-10:** macOS 26 or later, the app quit, a Time of Day automation with Start Group on a
   hide-only group: does it open the app and start the group without a dialog? If not, the README
   recipe says to keep the app open.
6. **TS-5:** an external monitor unplugged and plugged in again — directly, through a dock, into
   another port: When a Display Connects / Disconnects run once each; the chosen display is still
   chosen. Two identical monitors; These Displays with both. A MacBook: clamshell (lid closed with a
   monitor) is no "disconnects" of the built-in display; Sidecar and AirPlay: record how they count.
   Mirroring on: These Displays still matches.
7. **TS-6:** with display triggers on, `pmset displaysleepnow` and wake after 1 and after 10 minutes;
   Mac sleep with the monitor on; the monitor's own power button. No edge unless a display really
   changed; if a monitor rejoins later than 5 seconds after the wake, lengthen `wakeSettle`.
