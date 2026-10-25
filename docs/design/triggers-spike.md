# Spike: triggers (phase 4b)

Results of the spikes in `docs/design/triggers-spec.md` §2.3 (TS-1 … TS-11). Each PR adds the ones it
needs; PR 1 ran TS-1.

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
