# Per-trigger delays

Status: implemented; not released. "Run what was missed" (catch-up beyond the existing 30-minute
window for times) is **not** part of this work: it needs its own design.

Related: [triggers-spec.md](triggers-spec.md) (§1.7 notice, §1.8 reducer, §1.9 echo, budget and
pause), [app-presence-trigger-spec.md](app-presence-trigger-spec.md) (generation and revision
rules), [app-presence-session-lock-trigger.md](app-presence-session-lock-trigger.md) (lock revision),
[app-presence-threat-model.md](app-presence-threat-model.md).

## 1. What it is

A trigger can wait a number of seconds after it is **accepted** and before its action **runs**:
`GroupTrigger.delaySeconds`, an integer `0…3600` (`GroupTrigger.delayRange`); `0` (the default) is
no delay and behaves exactly as before.

- A trigger that shows a notice or asks first: the notice comes first; only after the user lets it
  run (or the countdown ends) does the delay start. Order: **notice → wait → run**. Not Now, no
  answer or a replaced notice end it as before; nothing waits.
- A trigger that runs right away (Show the Popup, lock and screens-sleep triggers, Run Right Away):
  **accepted → wait → run**.
- Everything before acceptance is unchanged: evaluation and its gates (cooldown, At most once a day,
  echo window, pause), the 2-second settle, the reducer, the catch-up window, the notice and the
  checks around it (`TriggerCoordinator.carryOut`). The firing waits only once all of them passed,
  right where the action would otherwise start.
- "Finish when it ends" is one of the trigger's actions: it waits the same delay.
- The wait is in memory only (never saved): quitting the app ends it and nothing runs later.
- A waiting firing doesn't hold the queue up: other triggers go on, with their own notices, while
  one waits (a 3600-second delay would otherwise block every trigger for an hour).

## 2. Cancellation matrix (fail-closed)

While it waits, the firing is looked at again whenever something it depends on may have changed
(`checkDelayedFirings`: on every signal, rule change, pause, application-observation invalidation,
identity-verdict change, and the controller's group changes), and once more — with everything
below — when the delay is over (`carryOutDelayed`), right before the handler is called. Whatever
cancels it removes it and records why; nothing of it runs later.

| What changed | When it's seen | Recorded |
| --- | --- | --- |
| The rule changed in any way (revision: any field, its group, its app approval), was turned off, or can't run | at once (`rulesChanged`) and at the end | `cancelledBeforeRun` |
| The rule was deleted | at once | nothing (its entry is gone) |
| Its group archived or deleted | at once (controller `groupsChanged` → `revalidateDelayedFirings`) and at the end | `groupMissing` |
| Triggers paused by the user | at once (`pause`) | `paused` |
| The hourly budget used up (by other runs meanwhile) | when its pause starts (any waiting firing), or at the end (`blocker` pauses) | `paused` / `budget` |
| A newer firing of the same trigger (the condition flapped, a newer lock edge, "finish when it ends" after its Start) | at once | `cancelledBeforeRun` (the newer one goes on) |
| The screen lock changed or became unknown (lock and unlock triggers) | at once (lock revision) | `cancelledBeforeRun` |
| The application observation it came from is outdated (new generation: tracker restarted, rules changed, sleep/wake; or an uncertain snapshot) | at once | `cancelledBeforeRun` |
| An authorized application trigger's running code no longer confirmed (`unavailable`, check failed) | at verdict changes and at the end | `applicationNotConfirmed` |
| An application trigger needing re-approval (`needsReapproval`) | at once (it's a rule change) | `cancelledBeforeRun` |
| The screens slept (or the Mac is going to sleep: a repeated "asleep"), or woke | at once | `cancelledBeforeRun` |
| The session stopped or started being the active one (fast user switching) | at once | `cancelledBeforeRun` |
| Echo window: an automatic action ran less than 15 s before the end (display/network/app changes only) | at the end | `rightAfterAutomaticAction` |
| Cooldown / At most once a day (it ran meanwhile) | at the end (defence in depth: a newer firing already cancels it) | `cooldown` / `alreadyRanToday` |
| Finish: the group isn't current any more; "finish when it ends": not started by this trigger | at the end (`blocker`) | `notCurrentGroup` / `notStartedByTrigger` |

Exception, on purpose: a **When the Screen Locks** trigger's Finish keeps waiting while the displays
sleep — the lock screen is what it's for; its lock revision (an unlock, sleep, another session)
still cancels it. A **When the Screens Sleep** trigger's Finish is cancelled when they wake.

A cancellation records `TriggerSkipReason.cancelledBeforeRun` ("Skipped today at 9:00: it was
cancelled before it ran.") unless a reason above says more. An action already started is not
undone.

## 3. Files and compatibility

- `triggers.json` stays format 1. `delaySeconds` is a top-level field of a trigger, written **only
  when it isn't 0** (files without delays don't change by a byte). A missing field reads as 0.
- Decision for unreadable values: never clamp, never read as 0 — that would run the action sooner
  than the file says. A whole number out of range (negative, over 3600) is kept as it is; anything
  else (a string, a fraction, `null`, `true`) is kept raw (`unreadableDelay`) and written back
  unchanged. Either way the trigger is **not runnable** ("Can't run: fix or remove it.") until the
  editor gives it a valid delay. A whole number written as `30.0` reads as 30.
- `trigger-state.json`: the new outcome `{"skipped":"cancelledBeforeRun"}`. Older versions can't
  read it and keep no outcome for that entry (their lenient reading); nothing else changes.
- Backups carry the field with the trigger; imported triggers come in turned off, as before.

### Risk: sharing the file with an older version

Versions before this one encode only the top-level fields they know: **opening and saving a
delayed trigger in an older version (an edit, a toggle, a restore that re-saves) drops
`delaySeconds`**, and that version runs the trigger at once — earlier than the user set — and
writes it back without the delay. Observed on `GroupTrigger.swift` of 0.11.1 with a synthetic
file (`24_TETIKLEYICI_012_TASARIM_ADAYI.md`). Not changed here: a format bump would make older
versions refuse or lose the whole file, a worse failure for a convenience field. Mitigation is a
release note and the existing pre-downgrade copy; a real downgrade with signed builds is a manual
gate before release.

## 4. User interface

- Editor (`TriggerEditorSheet`): a **Delay** row (label reused from the item launch options) with a
  number field and a stepper (0…3600), and a hint. Anything else — empty, negative, over 3600, not
  digits — can't be saved: the hint turns orange and Save is disabled. Reopening shows the saved
  value; a value this version can't read shows empty.
- Trigger row (`GroupTriggersSection`): a delayed trigger shows "After 30 s" under its status line
  (a timer symbol); while a firing waits, the same line counts down the time left ("After 27 s",
  an hourglass, accent color). Texts reused from `item.launch.row.delay`; no new key for the row.

## 5. Localization

Two English-only keys (in `LocalizationTests.awaitingTranslation` and the *English only for now*
section of `docs/l10n-keys.md`):

| Key | English |
| --- | --- |
| `core.trigger.skip.cancelledBeforeRun` | it was cancelled before it ran |
| `triggers.editor.delay.hint` | Seconds to wait, 0 to 3600, before the action runs (after the notice, if it shows one). If anything changes meanwhile — the trigger, its group, a pause, the screen lock, the Mac sleeping — nothing runs. |

## 6. Tests

`Tests/DockGroupsCoreTests/TriggerDelayTests.swift` (fake sleeper and clock, nothing really waits):
JSON (0 not written, >0 round trip, out-of-range and unreadable values kept and not runnable, the
store), the editor draft (accepted and rejected input, saved and reopened), the row texts; the
coordinator: no delay unchanged, the action after the delay, other triggers not held up, notice
then delay, Not Now, rule changed / turned off / deleted, a change only the final check sees, group
archived or gone at the end, pause, budget, screens sleep, session change, lock change, a lock
Finish through display sleep, a newer firing taking the place, a new observation generation, an
uncertain snapshot, code not confirmed, re-approval, echo window, "finish when it ends", Finish of a
group no longer current. `Tests/CybokronDockGroupsAppTests/TriggerDelayRowTests.swift`: the
countdown rounding and the controller publishing the wait and cancelling it when the group is
archived.

## 7. Remaining risks and next steps

- Older versions drop the field (§3).
- A When the Screens Sleep trigger whose displays sleep and whose Mac goes to sleep within the same
  2-second settle: both reports come before it's accepted, so its wait goes on across the sleep; if
  the displays are still asleep after the wake, its Finish (hiding only) can run then. Any later
  "asleep" report, or the displays waking, cancels it.
- Waits use `Task.sleep` (continuous clock); a long wait across a sleep is cancelled by the sleep
  itself, so clock drift doesn't matter.
- Next, separately: "run what was missed".
