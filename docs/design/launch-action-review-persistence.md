# Launch actions: the review status is saved

Status: done. Fixes a hole in D5 ("an action that needs review isn't opened at all") of the
[launch actions threat model](launch-actions-threat-model.md#10-open-decisions-effort-and-slice-order):
an action under review (imported with a backup, or refused) used to live in memory only. The next
save dropped it, so after a restart the item had **no** action and opened plainly in the default
browser, without the user ever reviewing it. Now the status is written with the action, and only
an action the file has **on** can run.

No new permission, user-facing text, localization key, `formatVersion` or backup `schemaVersion`.

## Status model

The item's `launchAction` object always carries a `status` when this version writes it:

| In memory (`LaunchActionSetting`) | On disk | Runs |
| --- | --- | --- |
| `.enabled(action)` | `{"status": "enabled", "template": "browserProfile", "browser": "chrome", "profile": "Work"}` | yes (the launcher and runner still check everything) |
| `.needsReview(.imported(action))` | `{"status": "review", "reason": "imported", "template": …, "browser": …, "profile": …}` | no (`plan(.actionDisabled)`) |
| `.needsReview(.invalid(reason))` | `{"status": "review", "reason": "invalid", …the object's other keys as read…}` | no (`plan(.actionNeedsReview)`) |
| none | no `launchAction` key | — (opens plainly) |

Reading (`LaunchActionCoding`), strict as before:

- `status` missing → a file written before statuses: a valid action is read as on (backward
  compatibility); an invalid one is under review as invalid.
- `"enabled"` → the template's keys must be exactly right, otherwise invalid.
- `"review"` + `"imported"` → imported when the keys are valid and the template fits the item kind;
  otherwise invalid.
- `"review"` + `"invalid"` → invalid (`markedInvalid`), whatever the other keys hold.
- Any other `status` or `reason` (other spelling, case, empty, or `review` without a reason) →
  invalid (`unknownStatus`); a non-string `status`/`reason` → `wrongValueType`; a `reason` next to
  `enabled` or without a status → `unknownKey`. None of them runs.
- A forbidden key (`environment`, `command`, `script`, `shell`, `args`, `path`, …) → invalid, as
  before.

What a refused object held is kept (`StoredLaunchAction.keptFields`, the `JSONValue` pattern that
triggers use for unsupported events) and written back unchanged — nested values, other types and a
newer version's keys included — next to `"status": "review", "reason": "invalid"`. Not kept:
`status` and `reason` themselves (rewritten), forbidden keys (threat model §6 rule 6: never read,
kept or written) and a value that isn't an object (it has nowhere to hold a status; written as
`{"status": "review", "reason": "invalid"}`). A refused value built in memory (for example a
profile name the grammar refuses, set in code) is never written: only `status` and `reason`.

## Transitions

| From | Event | To (memory and disk) |
| --- | --- | --- |
| none / any | backup restore or merge, template from a backup | enabled → `review/imported`; review stays review; kept fields kept |
| file read | object refused (keys, types, grammar, kind, status) | `review/invalid`, kept fields kept |
| `review/imported` | Turn On + confirm (editor) | `enabled` |
| `review/invalid` | a new browser + name, confirm | `enabled` (kept fields dropped) |
| `review/imported`, `enabled` | toggle off | key removed |
| `review/invalid` | toggle on, then off | key removed (the toggle starts off for an invalid action) |
| `review/*` | Done, dismissal or Cancel without the above | unchanged, still not opened |
| any | restart | unchanged |

Standalone agents still carry no action (D11).

## Backward compatibility

- Files without `status` (written by the unreleased slices before this one) keep working: a valid
  action stays on and gets `"status": "enabled"` on the next save.
- No released version knows `launchAction`; those versions ignore the key and drop it on their next
  save (threat model §8), as before.
- `formatVersion` and the backup `schemaVersion` are unchanged.

## Accepted risk

- **A status is no signature.** Anyone who can write `groups.json` (the same user, or a process
  running as them) can change `"review"` to `"enabled"` and the action runs. That writer could
  already write an enabled action directly (option A's model, D9: no approval store, no Keychain
  HMAC). Nothing is added against it; `LaunchActionReviewPersistenceTests.aStatusEditedByHandIsTaken`
  records the behaviour.
- **A refused object stays in the file** (minus forbidden keys) until the user sets a new action or
  removes it. It's inert: it's never read as an action again.
- **An invalid action marked by a newer version as something else** is rewritten as
  `review/invalid` by this one: the newer version sees it refused too and the user sets it again.

## Code and tests

- `Model/LaunchAction.swift`: `LaunchActionCoding` (status, reason, kept fields),
  `StoredLaunchAction`, `LaunchActionRejection.unknownStatus` / `.markedInvalid`.
- `Model/AppReference.swift`: stores `StoredLaunchAction`; `launchActionSetting` reads and sets it.
- `Model/ItemDetailsDraft.swift`: toggling an invalid action on and off removes it.
- `Tests/DockGroupsCoreTests/LaunchActionReviewPersistenceTests.swift`: through a real groups file
  and a new store (a restart) and the launcher with a fake workspace: enabled round trip runs;
  `review/imported` and `review/invalid` round trips don't, and the window still shows them for
  review; files without a status; 19 refused statuses; import, restore and merge; Turn On; toggle
  off; kept fields; the accepted risk. `LaunchActionTests` and `LaunchActionBackupTests` were
  changed where they asserted the old "not written" behaviour (each such test says so).
