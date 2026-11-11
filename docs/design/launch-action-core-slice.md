# Slice: launch action core (model, strict decoder, validator)

Status: internal Core code, not connected to the app. **Nothing executes a launch action**: no
launcher, workspace call, process, UI, localization key, link, trigger or agent reads one. An item
with a launch action opens exactly as it does without one. This is slice 2 of the
[launch actions threat model](launch-actions-threat-model.md#10-open-decisions-effort-and-slice-order)
(option A, templates only, D1); slice 1 (browser spikes) has not run, so the template set and
grammar may still change before anything is executed.

## Scope

- `Sources/DockGroupsCore/Model/LaunchAction.swift` (all `internal`):
  - `BrowserFamily` — `chrome`, `edge`, `brave`, `firefox`. No Safari (T6, D2).
  - `LaunchAction` — one template: `.browserProfile(browser:profileName:)`. No case can hold a
    command, script, program, location, environment or raw argument.
  - `BrowserProfileName` — the profile-name grammar; `BrowserProfileNameRejection` and
    `LaunchActionRejection` say why something was refused, without holding any text from the file.
  - `LaunchActionSetting` — `.enabled(action)` or `.needsReview(.invalid(reason) | .imported(action))`.
  - `LaunchActionCoding` — the strict on-disk form.
- `GroupItem` (`AppReference`) gains `launchActionSetting` (stored) and `launchAction` (the enabled,
  re-validated action, or `nil`). A browser profile is allowed on **website** items only.
- `SettingsBackup` turns imported actions off; `AgentConfiguration` drops them.

## On-disk form

An optional item key, written only for an enabled, valid action:

```json
{ "bundleIdentifier": "https://github.com/cybokron", "kind": "website", "name": "GitHub",
  "url": "https://github.com/cybokron",
  "launchAction": { "template": "browserProfile", "browser": "chrome", "profile": "Work" } }
```

- Keys are exactly `template`, `browser`, `profile`. Any other key makes the action invalid.
  `environment`, `env`, `command`, `script`, `executable`, `shell`, `args`, `argv`, `arguments` and
  `path` (any case) are refused by name: never read, kept or written.
- `template` must be `browserProfile`; `browser` one of the four raw values (case-sensitive). All
  three are strings; a missing one, a wrong type (`null` included) or a non-object value is invalid.
- `formatVersion` (groups file, agent config) and the backup `schemaVersion` are **not** changed
  (threat model §8). Versions without launch actions ignore the key and drop it on their next save.

## Profile-name grammar

Refused, never trimmed, escaped or fixed. Checked in this order (first reason wins):

| Reason | Rule |
| --- | --- |
| `empty` | no characters |
| `tooLong` | more than 64 Unicode scalars (combining marks count) |
| `controlCharacter` | any Cc (NUL, tab, CR, LF, ESC, DEL…), U+2028, U+2029 |
| `bidiCharacter` | any bidi control (U+061C, U+200E/F, U+202A–E, U+2066–9) |
| `invisibleCharacter` | Cf (zero-width, BOM…), private use, surrogate, unassigned, any space other than U+0020 |
| `looksLikePath` | starts with `/`, `~` or `file:` (any case) |
| `leadingHyphen` | starts with `-` |
| `surroundingWhitespace` | starts or ends with a space |
| `parentReference` | contains `..` |
| `forbiddenCharacter` | contains any of `` / \ ~ $ ` ; \| & > < * ? " ' = : `` |

`=` and `:` go beyond the minimum list: `=` per threat model §6 rule 3, `:` so no URL scheme fits.

## Fail-closed behaviour in this slice

| Input | Result |
| --- | --- |
| No `launchAction` key | item as before (`launchActionSetting == nil`) |
| Valid action on a website | `.enabled`; round-trips unchanged |
| Valid action on an app, file or folder | `.needsReview(.invalid(.unsupportedItemKind))` |
| Any decoder or grammar refusal | `.needsReview(.invalid(reason))`; the rest of the item is read as usual |
| `.needsReview` of any kind | `launchAction == nil`; **not written** — the next save drops it |
| Enabled case built in code with a bad name | not used, not written (`launchAction` and encoding re-validate) |
| Backup read (`SettingsBackup.decode`): groups, archived groups, templates | `.needsReview(.imported(action))`, counted in `disabledLaunchActionCount` (D4, T11) |
| Restore / merge (`SettingsBackup.restore`, `merge`) | turned off again, also for a backup built in code; nothing reaches the groups or templates file |
| Standalone agent config (`AgentConfiguration`) | dropped on write and on read (D11: no agent support yet) |

"Needs review" is internal state only: no UI shows it and it isn't saved, so an imported or invalid
action is gone after the next save or restart. Rules 1 and 7 of threat model §6 ("not opened at
all") are **not** enforced yet, because nothing opens items with actions: today an item with an
invalid or imported action opens plainly, as an older version would (rule 10).

## Tests

`Tests/DockGroupsCoreTests/LaunchActionTests.swift` and `LaunchActionBackupTests.swift`: round
trips for all four browsers, every grammar refusal (each reason reachable), forbidden and unknown
keys (not written), unknown templates and browsers, wrong types, item kinds, files without the key,
unreadable actions not breaking an item or group, the groups file's `formatVersion`, backups,
restore, merge, templates and agents. `LaunchActionExecutionScanTests` scans `Sources/`: only the
model, `AppReference`, `SettingsBackup` and `AgentConfiguration` mention launch actions, and no such
line (nor `LaunchAction.swift` at all) mentions `Process`, `NSWorkspace`, `OpenConfiguration`,
`GroupLauncher`, `ApplicationWorkspace`, AppleScript or a shell.

## Next slice

The computing part of slice 3 is done: [launch-action-argv-slice.md](launch-action-argv-slice.md)
(argument plan and dry run; still nothing executes an action).

Slice 3 (launcher integration), after the slice 1 spike: build argv per template (Chromium
`--profile-directory=`, Firefox `-P`; the spike decides names vs. directories and may narrow this
grammar), pass it through `OpenConfiguration.arguments` with an empty environment, re-check at
delayed fire time, enforce "not opened" for invalid or needs-review actions, check the browser's
bundle ID set against the opener, log privacy. Then slice 4 (editor, caption, review, restore
summary, localization) and slice 5 (agents).
