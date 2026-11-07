# Screen lock and unlock triggers (TS-11)

Status: implemented as **best effort**. macOS documents no screen-lock signal; this design uses
two long-standing but undocumented distributed notifications and says so in the editor. Per-trigger
delays and "run what was missed" are out of scope (next work items).

Related: [triggers-spec.md](triggers-spec.md) §2.3 (TS-11 row), [app-presence-trigger-spec.md](app-presence-trigger-spec.md)
(application triggers, generation and revision rules), [app-presence-threat-model.md](app-presence-threat-model.md).

## 1. Signal evidence

### 1.1 What was observed

A throwaway, unsigned probe (`NSApplication.run`, activation policy `.prohibited`) logged only
notification names, timestamps and three flags read at each notification: the
`CGSSessionScreenIsLocked` key of `CGSessionCopyCurrentDictionary()`, `kCGSessionOnConsoleKey` and
`CGDisplayIsAsleep(CGMainDisplayID())`. No application names, paths or user data were recorded.
Mac: macOS 27.2 (26B123), "require password" set to *immediately* (`sysadminctl -screenLock status`
→ `screenLock delay is immediate`). Times are UTC, 2026-11-07.

| # | What the user / test did | Notifications, in order | Session key at the notification |
| --- | --- | --- | --- |
| 1 | `pmset displaysleepnow`, then a key press and the password | `com.apple.screenIsLocked` (displays already asleep) · 16 s later `com.apple.screenIsUnlocked` | locked: `CGSSessionScreenIsLocked = 1`; unlocked: key absent |
| 2 | the same again (probe with `NSApplication.run`) | `NSWorkspaceScreensDidSleepNotification` (line partly overwritten in the log, see below) · `com.apple.screenIsLocked` ~1 s after `pmset` · `NSWorkspaceScreensDidWakeNotification` · `com.apple.screenIsUnlocked` 7 s after the wake | locked: `1` (display asleep); after wake, before the password: still `1`; unlocked: absent |
| 3 | Control-Command-Q (lock without the displays sleeping), password after ~5 s | `com.apple.screenIsLocked` · `com.apple.screenIsUnlocked` — **no** `sessionDidResignActive` / `sessionDidBecomeActive`, no screens notification | locked: `1` (display awake); unlocked: absent |

In round 2 an older probe process was still writing to the same log file and overwrote part of one
line; the fragment `…displayAsleep=1` right before the lock line is the screens-sleep notification.
The order "screens sleep, then lock" is therefore probable, not proven; the design doesn't depend
on it (§3.4).

Observed facts:

- `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` arrived for both a display-sleep lock
  and a Control-Command-Q lock, once each, with no user info needed.
- `NSWorkspace.sessionDidResignActive/BecomeActive` did **not** fire for a lock. They are about fast
  user switching (the session leaving the console), not about the lock screen; using them as a lock
  signal would miss every ordinary lock.
- Screens sleeping is not a lock: with a delayed "require password" setting the displays sleep
  without locking. Screens waking is not an unlock: in round 2 the displays woke 7 s before the
  unlock, on the lock screen.
- The undocumented session key matched the notifications every time (present and `1` while locked,
  absent while unlocked), including right after a wake on the lock screen.

### 1.2 Not verified

These were not run (they need another account, would suspend the machine running the work, or
weren't done by the user) and are documented as unknown:

- the screen saver starting and stopping, with and without a password delay;
- fast user switching (another user's session coming in, then back);
- `pmset sleepnow` / lid close: whether the lock notification comes before the sleep, after the
  wake, or both;
- a delayed "require password" setting (5 s, 1 min …), Touch ID / Apple Watch unlock, screen
  sharing, an MDM-forced lock;
- other macOS versions than 27.2.

### 1.3 What can't be guaranteed

- The notifications aren't API: a macOS release can rename, drop or reorder them, and no error tells
  the app. A trigger then simply never runs (it can't run wrongly from silence).
- Any process of the same user can post a distributed notification with these names. A fake
  "unlocked" could make an unlock trigger run its group's own action (Show the Popup, Open All,
  Start — through the normal notice, cooldown, budget and pause) and a fake "locked" a Finish that
  hides apps. This is the threat model's attacker A1 (a malicious process in the same user
  session, `app-presence-threat-model.md` §2); the triggers spec's T-S1 and T-S2 bound the damage:
  a trigger never runs anything but its group's own items, never quits, and Start and Finish stay
  `TransitionTrigger.automation`. It's stated, not prevented.
- Nothing is seen while Cybokron Dock Groups isn't running, and a lock or unlock very close to a
  sleep, a wake or a session switch can be missed (§3.4).

## 2. Semantics

- **When the screen locks** (`TriggerEvent.screenLocks`, JSON `{"kind":"screenLocks"}`): the lock
  reading changed from *unlocked* to *locked*. Allowed action: **Finish** only (hides; never quits),
  carried out **right away** whatever the run mode says — nobody can answer a notice on the lock
  screen — even while the displays sleep, as the existing "When the screens sleep" trigger does.
- **When the screen unlocks** (`TriggerEvent.screenUnlocks`, JSON `{"kind":"screenUnlocks"}`): the
  reading changed from *locked* to *unlocked*. Allowed actions: Show the Popup, Open All, Start,
  with the trigger's run mode (notice, Ask First, right away), like "When the screens wake".
- Neither is an *edge* in the echo-window sense: an automatic action can't lock or unlock the
  screen, so the 15-second echo window doesn't hold them back. The 60-second cooldown, At most once
  a day, the pause, the hourly budget, the reducer (one Start wins) and archived/deleted group rules
  apply unchanged.

## 3. Readings, baseline and fail-closed rules

### 3.1 The signal is a reading

`TriggerSignal.screenLock(locked: Bool?)` carries the lock *as the source reads it*: `true`,
`false`, or `nil` (can't tell). `TriggerEnvironment.screenLocked` keeps the last one, in memory only
(never saved, unknown at launch). The evaluator fires only on a change **between two known
readings**:

| previous | new | result |
| --- | --- | --- |
| `nil` | `true` / `false` | baseline, nothing fires |
| `false` | `true` | **lock** |
| `true` | `false` | **unlock** |
| same | same | nothing (a repeated notification) |
| any | `nil` | unknown, nothing fires |

So a notification alone never fires: it must contradict a known previous reading. Unknown is never
read as "unlocked" or "locked".

### 3.2 Where readings come from (`ScreenLockSource`, app target)

- `com.apple.screenIsLocked` → `true`; `com.apple.screenIsUnlocked` → `false`.
- **Baseline** when the source starts, after `NSWorkspace.didWake` and after
  `sessionDidBecomeActive`: first `nil` (forget what came before the gap), then the session
  dictionary — on the console and `CGSSessionScreenIsLocked == true` → `true`; on the console and
  the key `false` or absent → `false`; a dictionary that can't be read, a session not on the
  console, or a key of another type → `nil`. The key is undocumented, so it's only a baseline: it
  decides what the next notification is compared with and never fires anything itself. A wrong
  baseline can only turn the next real notification into a missed one (e.g. a baseline "locked"
  while unlocked makes the next lock a repeat), never into an extra run.
- `NSWorkspace.willSleep` and `sessionDidResignActive` → `nil`. The evaluator also sets the lock to
  unknown on `.session(active: false)` from the workspace source, so whichever arrives first wins.
- Stopping the source → `nil`.
- The source runs only while a lock or unlock trigger can run (`TriggerSourceNeeds.screenLock`: on,
  runnable, group not archived); no permission, no polling, no timer.

### 3.3 Generations: stale firings never run

Every change of `screenLocked` (to unknown too) increments `TriggerEnvironment.screenLockRevision`
(a repeat doesn't). A lock or unlock firing records the revision it came with
(`TriggerFiring.screenLockRevision`). The coordinator carries it out only while the revision is
unchanged, checked:

1. as soon as a signal changes the revision: stale pending and queued lock/unlock firings are
   dropped, and a notice showing for one is dismissed;
2. before the reduction (a stale firing can't win over a live one);
3. when it's taken from the queue, after its notice is answered, and as the last check before the
   handler is called.

Stale firings are dropped without a recorded outcome (like an outdated application observation).
A lock-kind firing without a revision never runs. Rule changes (off, deleted, group or event
changed) drop firings through the existing `rulesChanged` path.

Consequences for quick repeats: lock → unlock inside the 2-second settle runs only the unlock; unlock
→ lock runs only the lock; an unlock whose notice is counting down when the screen locks again
runs nothing. The cooldown limits a trigger to one run a minute.

### 3.4 Sleep, wake and sessions

- Display sleep doesn't touch the lock reading: in the observed order (screens sleep, then lock)
  the lock trigger still fires and its Finish runs while the displays sleep.
- The Mac going to sleep makes the lock unknown; after the wake the baseline is read again. If the
  session key says "locked" (observed after a display-sleep wake), the user's unlock then fires.
  A lock immediately followed by sleep (lid close) usually doesn't run: its firing is still settling
  when `willSleep` makes it stale. Whether the lock notification arrives before or after a real
  system sleep was not verified (§1.2).
- Another session becoming active makes the lock unknown, and the waiting firings stale; coming back
  reads the baseline again, so another user's lock screen is never this session's unlock.
- An unlock firing waits, like the others, until the screens are awake and the session is active,
  at most the 30-minute window; the existing application-trigger sleep/session resets are unchanged
  (lock changes don't stop the application tracker or reset its verifier).

## 4. Files and compatibility

- `triggers.json` format stays 1. The events are `{"kind":"screenLocks"}` and
  `{"kind":"screenUnlocks"}` with **no other field**: an object with an extra field (a newer
  version's option) is kept as `.unsupported`, written back unchanged and never run.
- Versions before this one read both kinds as `.unsupported`: kept, written back, never run (their
  `default:` branch, covered by the existing unknown-kind tests). Imports and backups bring the
  triggers in turned off, as every trigger.
- No new state file field; the lock reading is memory only.

## 5. Localization

Six English-only keys (listed in `LocalizationTests.awaitingTranslation` and the *English only for
now* section of `docs/l10n-keys.md`):

| Key | English |
| --- | --- |
| `core.trigger.summary.screenLocks` | When the screen locks |
| `core.trigger.summary.screenUnlocks` | When the screen unlocks |
| `triggers.editor.event.screenLocks` | When the Screen Locks |
| `triggers.editor.event.screenUnlocks` | When the Screen Unlocks |
| `triggers.editor.hint.screenLocks` | Nobody can answer a notice while the screen is locked, so this trigger finishes the group right away. |
| `triggers.editor.screenLock.note` | macOS doesn't document when the screen locks, so a lock or an unlock can be missed, for example right after the Mac sleeps or when another user switches in. Nothing runs when it can't be told. |

The editor offers both in the When pop-up's moments (after When the Screens Sleep), with the hint
and the note; the trigger rows use the `lock` / `lock.open` symbols.

## 6. Tests

- `TriggerScreenLockTests.swift` (Core): readings → firings (baseline, repeats, unknown gaps,
  inactive session, display sleep in between), revisions, off/archived rules, cooldown and pause,
  other triggers unaffected, source needs; the coordinator with fakes: unlock runs (right away and
  with a notice), lock finishes right away without a notice panel while the displays sleep, quick
  lock/unlock and unlock/lock, a queued unlock dropped when the lock changes, a stale notice
  dismissed with nothing run or recorded, unknown readings running nothing, another session
  dropping a waiting unlock, rule changes, other and application-presence firings unaffected;
  JSON round trips, strict decoding, a file with lock triggers and a newer kind through the store,
  backups turned off, the editor draft, the row text.
- `ScreenLockSourceTests.swift` (app, SwiftPM): the session-dictionary baseline parser, start/stop
  readings with an injected reader, the source driving a coordinator. No test posts the real
  distributed notifications (they would reach every app of the user).

## 7. Remaining risks and next steps

- Undocumented notification names and session key (§1.3); macOS can change them silently.
- Same-user spoofing of the notifications (§1.3).
- Unverified cases (§1.2), especially system sleep, the screen saver and fast user switching; these
  are manual gates before a release.
- A lock right before system sleep doesn't run its Finish (§3.4).
- Next, separately: per-trigger delays and "run what was missed".
