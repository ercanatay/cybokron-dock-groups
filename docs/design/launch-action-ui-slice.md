# Slice: launch actions in the group window (slice 4, editor and rows)

Status: the group window can now **show, set, change, remove and turn on** a website item's
browser-profile action. Nothing about how an action runs changed: the launcher and its runner
([launch-action-runner-slice.md](launch-action-runner-slice.md)) check everything again at launch
time, refuse a running browser and open only for the user's own click. No new permission,
entitlement, file access, `formatVersion` or approval store. This is slice 4 of the
[launch actions threat model](launch-actions-threat-model.md#10-open-decisions-effort-and-slice-order)
(§7 "Confirmation and visibility"), without the restore summary line (the import count already
exists in Core, `disabledLaunchActionCount`) and without agent support (slice 5).

## Screens and states

### Details editor (website items only)

Opened as before from a row's ⓘ button, Edit Details… or the popup. Below "Open with" in the
Opening part:

1. **Open in Browser Profile** toggle. Off by default. It can't be turned on when none of Chrome,
   Edge, Brave and Firefox is on this Mac. Turning it on picks the action's own browser when it is
   installed, otherwise the first installed one.
2. **Browser menu** (left column): Chrome, Edge, Brave, Firefox. A browser that isn't on this Mac
   is listed as "Chrome (not on this Mac)" (`item.launch.choice.notOnThisMac`) and can't be chosen
   (`selectionDisabled`, and `ItemDetailsDraft.chooseBrowser` refuses it). The installed set is
   asked of LaunchServices **once**, when the editor opens (`items.catalog`), like the Open With
   menu.
3. **Profile name field** with an example as its placeholder ("Profile 1" for Chromium,
   "default-release" for Firefox) and the **hint** below it: Chromium wants the *directory name*
   (the last part of "Profile Path" in `chrome://version`: `Default`, `Profile 1`); Firefox the
   *profile name* in `about:profiles`.
4. **Invalid name:** the hint is replaced, in orange, by what a name may hold (the grammar of
   [launch-action-core-slice.md](launch-action-core-slice.md#profile-name-grammar): ≤ 64
   characters, no control/invisible/bidi characters, no leading `-` or space, no trailing space, no
   `..`, none of `` / \ ~ $ ` ; | & > < * ? " ' = : ``). **Done is off** (as Save is in the
   template sheet for a name that can't be used). Return in a field does nothing then.
5. While a browser profile is chosen, **"Open with" isn't shown**: the profile's browser opens the
   website. When an action is turned on, the store drops the item's Open With app
   (`GroupStore.updateItem`, `LaunchActionEdit.enable`), so the launcher can't be handed a browser
   outside the action's family.

### Review (`.needsReview(.imported)` / `.needsReview(.invalid)`)

- **Row:** an orange warning line "Browser profile needs review: the item won't open until you turn
  it on." (`LaunchActionCaption.needsReview`). The ⓘ button is filled.
- **Editor:** an orange note under the toggle: the action came in with a backup or can't be used
  as saved, so the item won't open until it is checked and turned on.
  - *Imported:* the toggle is on and the fields show the imported browser and name. **Turn On**
    (only when the browser is installed and the name valid) opens the confirmation. **Done without
    Turn On keeps it under review**; turning the toggle off removes it; editing the fields makes
    Done ask too.
  - *Invalid:* nothing of it can be shown (the reason holds no text from the file). The toggle is
    off; the user sets a browser and a name, then Turn On or Done asks. Leaving it off keeps it as
    it is (not opened). Turning the toggle on and off again removes it.
- The launcher keeps refusing the item until the setting is `.enabled`
  (`plan(.actionDisabled)` / `plan(.actionNeedsReview)`), unchanged from slice 3.
- Both review states are **written** (`"status": "review"`, `"reason": "imported"` / `"invalid"`)
  and survive a restart: the item stays unopened and the row keeps its warning
  ([launch-action-review-persistence.md](launch-action-review-persistence.md)).

### Confirmation (every time an action is set or turned on)

Done (with a new or changed action) and Turn On show one alert:

- **Title:** "Open “GitHub” in Chrome with the profile “Work”?" (`LaunchActionSummary.title`).
- **Message (not localized):** the full address and the browser app with its bundle identifier:
  `https://github.com/cybokron` / `Google Chrome (com.google.Chrome)`.
- **Turn On** records the confirmation in the draft and closes the editor, saving once:
  `LaunchActionSetting.enabled` is written (`"status": "enabled"`). **Cancel** closes only the alert: nothing changes and
  the editor stays open.
- Closing the popover another way (a click elsewhere) saves the other fields but **not an
  unconfirmed action**: the item's action stays as it was.
- Removing an action (toggle off) needs no confirmation: it can only make the item open plainly
  in the default browser, which needs no review.
- ~~No record of the confirmation is kept (D9 deferred)~~: since
  [launch-action-approvals.md](launch-action-approvals.md) Turn On writes the action's digest to
  `launch-action-approvals.json`, and only an action with its digest there runs.

### Row caption (`LaunchActionCaption`)

For an enabled action, a line "Chrome · Work" (brand and profile names, not localized). While that
browser runs (the launcher's browser: the item's Open With app or the template's bundle ID, checked
against `RunningAppsMonitor`, which updates on launch/quit notifications), a second line: "Chrome is
running: the item opens only after you quit it." (D7/T6: the runner refuses a running browser, so
the page would otherwise never open). Items without an action show neither line.

## Draft rules (`ItemDetailsDraft`)

| Started from | User does | Done / dismissal saves |
| --- | --- | --- |
| no action | turns on, valid name, confirms | `.enable(action)` |
| no action | turns on, valid name, cancels the alert or dismisses | nothing |
| any | invalid name | Done off; dismissal saves no action |
| `.enabled(A)` | nothing | nothing |
| `.enabled(A)` | changes browser/name, confirms | `.enable(B)` |
| `.enabled(A)` / `.imported(A)` | toggle off | `.remove` |
| `.imported(A)` | Done only | nothing (still under review) |
| `.imported(A)` | Turn On, confirms | `.enable(A)` |
| `.invalid` | sets browser + valid name, confirms | `.enable(action)` |
| `.invalid` | nothing | nothing (still under review, also after a restart) |
| `.invalid` | toggle on, then off | `.remove` |
| any | Cancel | nothing |

A confirmation counts only for the exact action chosen; changing a field afterwards asks again. A
browser not on this Mac can't be chosen; an unchanged action whose browser is gone is kept, a
changed one can't be saved.

## Localization keys (8, English only for now)

`LocalizationTests.awaitingTranslation` = `item.launch.profile.`; listed in
[l10n-keys.md](../l10n-keys.md) under "A website's browser profile".

| Key | Where | English |
| --- | --- | --- |
| `item.launch.profile.toggle` | editor (also the menu's and field's accessibility label) | Open in Browser Profile |
| `item.launch.profile.hint` | editor | Opens the website in this profile when you open it yourself and the browser isn't running. Chrome, Edge, Brave: the folder name at the end of “Profile Path” in chrome://version, such as Default or Profile 1. Firefox: the profile's name in about:profiles. |
| `item.launch.profile.invalid` | editor | Type the name as the browser shows it: up to 64 characters, … none of / \ ~ $ \` ; \| & > < * ? " ' = : |
| `item.launch.profile.review` | editor | This browser profile came in with a backup or can't be used as it was saved, so the item won't open until you check it and turn it on. |
| `item.launch.profile.turnOn` | editor and alert | Turn On |
| `item.launch.profile.row.review` | row (Core) | Browser profile needs review: the item won't open until you turn it on. |
| `item.launch.profile.row.running` | row (Core) | %@ is running: the item opens only after you quit it. |
| `item.launch.profile.confirm.title` | alert (Core) | Open “%1$@” in %2$@ with the profile “%3$@”? |

Reused: `item.launch.choice.notOnThisMac`, `common.cancel`, `common.done`.

## Code

- Core: `Model/LaunchActionEditing.swift` (public `BrowserFamily` names and bundle ID,
  `LaunchAction.browser`/`profileName`/`isAcceptedProfileName`, `LaunchActionStatus`,
  `AppReference.launchActionStatus`, `LaunchActionEdit`, `LaunchActionSummary`,
  `LaunchActionCaption`); `Model/ItemDetailsDraft.swift` (browser profile fields and rules);
  `Store/GroupStore.swift` (`updateItem(…, launchAction:)`). `BrowserFamily` and `LaunchAction`
  became `public`; the setting, its review reasons, the grammar's reasons and the coding stay
  internal.
- App: `ItemDetailsEditor.swift` (rows, alert), `AppRowView.swift` (caption lines),
  `GroupDetailView.swift` (installed browsers, running state), `MainWindowController.swift` /
  `AppDelegate.swift` (the app's `RunningAppsMonitor` reaches the window), `L10n.swift`.
- The source scan (`LaunchActionExecutionScanTests`) now allows these group-window files, and a new
  check makes sure none of them mentions the runner, the plan, the launcher, `Process`,
  `OpenConfiguration` or `openApplication`; lines that mention an action are still checked against
  every execution token.

## Tests

`Tests/DockGroupsCoreTests/LaunchActionEditingTests.swift`: valid browser + name → saved
`.enabled` (and written as `launchAction`) only after confirmation, one save; invalid names (19
cases: injection flags, paths, `..`, control/bidi/zero-width characters, shell characters, too long)
→ not accepted, Done off, nothing saved even when "confirmed" or dismissed; valid names accepted;
browsers not on this Mac can't be chosen, no browser → toggle off; an unchanged action with a
missing browser is kept, a changed one can't be saved; only websites; enabled actions kept, changed,
removed; Open With dropped on enable; the store keeps a forged action as needing review; imported
→ shown, Done keeps it under review, Turn On + confirm → `.enabled`; invalid → needs a new action;
status mapping; row caption text, running note (and the bundle ID asked), review warning, none for
items without an action; summary title/details with the full address; and through
`GroupLauncher` with a fake workspace: an imported item isn't opened, after Turn On it is, with
`--profile-directory=Work`. The existing refusal tests (`LaunchActionLauncherTests`) are unchanged.

## Residual risk

- **Profile names can't be checked.** The app doesn't read `Local State` or `profiles.ini` (D3,
  TCC). A mistyped Chromium directory makes Chrome create a new empty profile (verified in slice 3);
  a mistyped Firefox name shows Firefox's own error or Profile Manager (unverified). The hint says
  where to read the real name; nothing more can be done without reading another app's files.
- **No approval record (D9 deferred).** *Done since [launch-action-approvals.md](launch-action-approvals.md).* The confirmation is UI only. A same-user writer of
  `groups.json` can still write an enabled action directly, as before this slice (the accepted
  model of option A); only imported (backup/template) actions are forced through review.
- ~~**Invalid actions vanish on restart.**~~ Fixed by
  [launch-action-review-persistence.md](launch-action-review-persistence.md): an imported or invalid
  action is written under review, so after a restart the item still isn't opened and the row still
  warns. A same-user writer can change `"review"` to `"enabled"` by hand; accepted (D9), as they
  could always write an enabled action.
- **Running state is a snapshot.** The row's running note follows `RunningAppsMonitor`; the
  launcher asks again right before starting, which is what counts.
- **Installed browsers are checked when the editor opens**, not live; a browser installed while the
  editor is open is offered the next time.
- **Restore summary:** Import Settings…'s confirmation doesn't yet say how many actions came in
  turned off (`disabledLaunchActionCount` is computed but not shown); the rows show it per item.
- 8 new texts are English only until translated.
