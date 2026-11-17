# Design: Local Suggestions

- **Status:** draft for review (2026-11-15). Design only: no code, no strings added yet.
- **Baseline:** `main` at `a28bdc4` (version 0.19.1, `project.yml` `MARKETING_VERSION: "0.19.1"`),
  26 `*.lproj` folders, `LocalizationTests.awaitingTranslation` empty.
- **Roadmap item:** 6, *Local Suggestions*: "suggest groups and items from usage patterns; the data
  stays local, no network."
- **Builds on:** Most Used (`DockGroupsCore/Usage/*`, `Store/UsageStore.swift`,
  `Persistence/UsagePersistence.swift`, `CybokronDockGroups/Support/UsageMonitor.swift`) and the
  Capture review sheet (`docs/design/capture-spec.md`, `Capture/CapturePlanner.swift`,
  `Capture/CaptureSelection.swift`, `CybokronDockGroups/Capture/CaptureSheet.swift`).
- Paths are relative to `Sources/` unless they start with `Tests/`, `docs/` or name a root file.

---

## 1. Problem and goal

Making a group today means choosing its apps by hand (Add Apps…) or capturing what is open right
now (Capture, 0.10.0). Neither notices that the user opens the same few apps together day after
day. The app already counts this for Most Used, and keeps that count only on this Mac.

**Goal.** With the user's explicit consent, turn that existing local count into a few concrete
proposals that the user reviews:

- **New group:** "You often open Xcode, Simulator, Figma and Terminal together. Make a group?"
  (3 to 6 apps that are opened together often).
- **Add to group:** "You often open Figma with the apps in *Design*. Add it?" (one app that is
  opened with most of an existing group's apps but isn't in the group).

A suggestion only ever opens a review sheet. The user changes the selection and the name, then
creates the group or adds the app. Nothing happens without that click.

**Not in this design (first release):**

- **Time-of-day or weekday suggestions** ("bring forward the group you start on Friday mornings").
  The data doesn't exist: `usage-stats.json` keeps one `lastLaunchedAt` per app, not per-launch
  timestamps, and group starts (`Switching/ContextSession.swift`) are kept in memory only, at most
  8, with no times saved. §3.5 says what this would need. It is deferred and would need its own
  review and its own opt-in.
- Suggesting websites, files or folders. Usage tracking never records them
  (`UsageTracker.isTracked`), so there is nothing to suggest from.
- Suggesting removals, reordering, triggers, shortcuts, layouts or launch actions.
- Automatically creating, changing, opening, hiding or quitting anything (§5).

**Never, in any release:**

- Telemetry, analytics, crash-report enrichment or any network request for suggestions.
- A server, a cloud model, an LLM call or iCloud sync of usage data or suggestion state.
- A user profile, an "interest" model or any inference beyond "these apps were launched together N
  times".
- Putting usage data or suggestion state in a `.dockgroups` backup or in Export Diagnostics.

## 2. Data and privacy

### 2.1 What exists today (read-only for this feature)

`~/Library/Application Support/Cybokron/DockGroups/` (`JSONFileSupport.directoryURL`):

| File | Shape (format version 1) | Core type |
|---|---|---|
| `usage-stats.json` | `{"formatVersion": 1, "apps": [{"bundleIdentifier", "name", "path", "launchCount", "lastLaunchedAt"}]}`, `lastLaunchedAt` = seconds since 1970 | `UsageStats.apps: [String: AppUsage]`, keyed by lowercased bundle identifier |
| `usage-cooccurrence.json` | `{"formatVersion": 1, "pairs": {"<bundle id>": {"<bundle id>": <count>}}}` | `UsageStats.cooccurrence: [String: [String: Int]]`, symmetric |

What the counts mean (`Usage/UsageTracker.swift`):

- `launchCount` goes up by one for each launch of a regular app (`NSRunningApplication.activationPolicy
  == .regular`), however it was opened. Finder, Spotlight, SystemUIServer, WindowManager,
  NotificationCenter, WebKit/Security/Accessibility helpers, this app and its standalone agents are
  never recorded.
- `cooccurrence[a][b]` goes up by one when `a` is launched while `b` is still in the *session*: a
  sliding window of `mostUsedSessionSeconds` (default 600 s; offered 120–3600 s) since `b`'s last
  launch or activation. An app launched again inside its own session isn't paired again. The
  session itself (`UsageTracker.session`) is never saved.
- Recording happens only while `PopupPreferences.showsMostUsed` is on (default **on**).
  `UsageStore.clearHistory()` (Settings → Most Used → Clear History…) empties both files.
- Neither file has a first-recorded date, a per-day count or per-launch timestamps. **Retention is
  unlimited** until Clear History.

What does **not** exist and this design does **not** assume: a persistent group-open/start history,
per-launch times, weekday/hour buckets, app category data, window titles or document names.

### 2.2 New, minimal state: `suggestions-state.json`

The algorithm needs two facts the usage files don't have: how long the feature has been watching
(cold start) and what the user has turned down. Proposed file in the same folder, written with
`JSONFileSupport.write`, read leniently like the other files (unknown fields ignored; a file that
can't be read is moved aside and the state starts empty, which means *no suggestions* until the
observation window passes again):

```json
{
  "formatVersion": 1,
  "enabledAt": 1794000000,
  "activeDays": 9,
  "lastActiveDay": "2026-11-15",
  "dismissed": [
    {"kind": "newGroup", "apps": ["com.apple.dt.xcode", "com.figma.desktop"], "until": null},
    {"kind": "addToGroup", "group": "<UUID>", "apps": ["com.figma.desktop"], "until": 1796000000}
  ]
}
```

- `enabledAt`: when the user turned Suggestions on. Reset each time it's turned on again.
- `activeDays` / `lastActiveDay`: the number of distinct local calendar days, since `enabledAt`,
  with at least one recorded launch. Only the count and the last day are kept, never a list of days.
- `dismissed`: sets of lowercased bundle identifiers (already present in `usage-stats.json`) the user
  rejected; `until == null` means "don't suggest again", a date means "not before". At most 200
  entries; the oldest timed-out entries go first.

The file isn't part of backups and isn't read by standalone agents.

### 2.3 Consent: off by default

- New preference `PopupPreferences.showsSuggestions: Bool`, **default `false`**. Decoded leniently:
  only `true` turns it on (security rule 5 in `06_GUVENLIK.md`), so a crafted or older
  `preferences.json` can't turn it on.
- Suggestions depend on usage recording. While `showsMostUsed` is off, nothing is recorded, the
  Suggestions toggle is disabled and the setting says why ("Suggestions use the Most Used history.
  Turn on Most Used to use them."). This design doesn't add a separate recording switch (open
  decision D3).
- The first time the toggle is turned on, a one-time explanation says what is used ("which apps you
  open, and which ones you open within the same session"), where it stays ("on this Mac, in
  Application Support"), and that nothing is created without the user's click.

### 2.4 What the user sees and how they delete it

- **Settings → Most Used** (existing pane) gets a *Suggestions* section: the toggle, a status line
  ("Watching: 3 of 5 days", "No suggestions right now", "2 suggestions"), **Reset Dismissed
  Suggestions…** and the storage note naming `suggestions-state.json`.
- **Turning Suggestions off** stops computing and showing suggestions at once. The state file is
  kept, the same way turning Most Used off keeps its history (open decision D4).
- **Clear History…** (existing) also deletes `suggestions-state.json`. Its confirmation message
  mentions suggestions when the feature is on.
- **Reset Dismissed Suggestions…** empties `dismissed` only.
- README "Most Used" and the Application Support file list document the new file. SECURITY.md
  states that suggestions make no network traffic.

### 2.5 Logging rule

- Suggestion code logs **counts and outcomes only**: "computed 2 suggestions", "dismissed
  (newGroup, 4 apps)", "created group <UUID>". No bundle identifiers, app names, paths or pair
  counts, at any log level, including `.debug`.
- Group identifiers may be logged with `privacy: .public`, as `CaptureController.commit` already
  does. App names never are.
- Export Diagnostics adds one line: `Suggestions: on|off`, plus the number of dismissed entries.
  No apps.
- Existing gap, flagged and not fixed here: `UsageMonitor.launched` logs
  `"Launch recorded: <bundle id>"` at `.debug` with `privacy: .public`. Open decision D7 proposes
  making it `.private` or removing it before Suggestions ships.

## 3. Algorithm (pure Core, no I/O)

A new `SuggestionPlanner` in `DockGroupsCore/Suggestions/`. It is a pure function of
`(UsageStats, groups, ProtectedApps, SuggestionState, now, isInstalled)` and returns
`[Suggestion]`, so it can be tested without a clock or disk, like `UsageTracker` and
`CapturePlanner`.

### 3.1 Cold start: no data, no suggestions

All of these must hold, or the result is empty:

| Gate | Default |
|---|---|
| `showsSuggestions && showsMostUsed` | both `true` |
| Days since `enabledAt` | **≥ 7** |
| `activeDays` | **≥ 5** |
| `UsageStats.totalLaunchCount` | **≥ 50** |

History recorded *before* opt-in is used for the counts (it already drives Most Used), but the
7-day window starts at opt-in. Counts can't be dated, so the window is the only way to check that
the routine is current (open decision D2).

### 3.2 Eligible apps

An app key `k` is eligible only if:

1. `UsageTracker.isTracked(bundleIdentifier: k)`;
2. `apps[k].launchCount ≥ 5`;
3. `apps[k].lastLaunchedAt` within the last **14 days** (stale routines aren't suggested);
4. it is installed (`AppIconProviding.isInstalled`, the same check Most Used uses);
5. it is **not protected**: not in `PopupPreferences.protectedApps` (`ProtectedApps.lists(identity:)`)
   and not `ProtectedApps.isAlwaysProtected(identity:action:)` for either action (host app,
   agents, Finder);
6. it passes `AppItemPolicy.sanitized` as an app `GroupItem` built from `apps[k].app`, the same
   gate Capture and Add Apps use.

### 3.3 Pair strength

For eligible `a`, `b` with `n = cooccurrence[a][b]`:

- **Support:** `n ≥ 5`.
- **Mutual strength:** `n / max(launchCount(a), launchCount(b)) ≥ 0.35`, clamped to 1.

The *max* in the denominator is the false-positive guard against "hub" apps (a browser, mail or
chat app launched with everything). A hub with 300 launches paired 20 times with a 25-launch app
scores 0.07 and is dropped, even though 20 of the small app's 25 launches were with it. The existing
counts can't support a proper lift calculation, because the number of sessions isn't stored.

### 3.4 Building suggestions

**New group** (greedy clique, deterministic):

1. Sort strong pairs by `n` descending, ties by key.
2. Seed with the strongest unused pair; repeatedly add the eligible app whose *weakest* strong link
   to every current member is highest, provided it has a strong pair (§3.3) **with every member**.
   Stop at 6 apps.
3. Keep the set only if it has **≥ 3 apps**. Two-app groups are too weak a signal.
4. Drop it if an existing (non-archived) group already contains **≥ 75 %** of its apps, or if it
   matches a dismissed set (§3.6).
5. Mark the apps as used and repeat from step 2. Keep at most **2** new-group suggestions.

**Add to group** (one app per suggestion):

- For each non-archived, non-empty group `G` with ≥ 2 apps, and each eligible app `x ∉ G`: `x` is
  suggested if it has a strong pair with **at least 2/3 of `G`'s apps** (rounded up) that are
  themselves eligible, and with **at least 2** of them. Pick the best `x` per group by summed `n`.
- Keep at most **2** add-to-group suggestions overall, strongest first.

**Total shown:** at most **3**, new-group first. Recomputed when the menu opens (cheap: at most
a few hundred tracked apps). The result is never cached on disk.

### 3.5 Seasonality (weekday/hour): not in v1

The current data can't support it (§2.1). Supporting it later would need a new, separately opted-in
aggregate, such as per-group start counts in 7 × 4 buckets (weekday × part of day) with no
timestamps. It would only *highlight* a group in the menu, never start it; triggers already do
that, with their own consent. This is out of scope until that data design is reviewed.

### 3.6 Repeat suppression

- A dismissal matches a candidate of the same kind when the Jaccard overlap of their app sets is
  ≥ 0.75. For add-to-group, it must also be the same group and the same app.
- "Not now" sets `until` to **now + 7 days** (default) or **now + 30 days**. "Don't suggest this
  again" sets `until: null`.
- Creating the group, or adding the app, removes the suggestion naturally (step 4 / `x ∈ G`).
- If the user cancels the review sheet, that counts as "Not now, 7 days", so a suggestion that is
  opened and closed doesn't come back the next time the menu opens.

### 3.7 Thresholds as constants

All numbers above are `public static let` on `SuggestionPlanner` (like
`MostUsedRanking.cooccurrenceWeight`), covered by tests, and not user-editable in v1.

## 4. UX

### 4.1 Where

- **Menu bar menu:** a *Suggestions* section right after the Most Used section
  (`StatusBarController.addMostUsedSection`), shown only when there is at least one suggestion.
  One row per suggestion:
  - "New group: Xcode, Simulator, Figma +1"
  - "Add Figma to Design"
  - Each row's tooltip says why: "Opened together 14 times in the last weeks". Counts only.
- **Settings → Most Used → Suggestions:** the toggle and status (§2.4).
- **Not in v1:** the popup (it shows one group's contents; adding a row there conflicts with
  the read-only Most Used popup), standalone agents, Siri/Shortcuts intents, links, CLI. None of
  these can create a group from a suggestion.

### 4.2 Preview and review (nothing is created before this)

Clicking a row opens the **Capture review sheet**, which already previews a group before it
exists: a checklist, a name field and a target. It runs with a plan built from the suggestion
instead of from the open apps:

- New group: target `CaptureTarget.newGroup`, the suggested apps listed and preselected, name
  prefilled with `CapturePlanner.suggestedName`.
- Add to group: target `CaptureTarget.group(id)`, the group's existing apps shown as *In this group*
  (not selectable, `CaptureCandidate.Note.inGroup`), and the suggested app preselected.
- The commit goes through the existing `CaptureController.commit` →
  `CaptureSelection.capture(_:into:named:)`, so the item gate, name deduplication, the
  archived/deleted-group check (`.unavailableGroup`) and logging are the existing ones.
- The sheet's secondary buttons are **Not Now** (menu: *For a Week* / *For a Month*) and **Don't
  Suggest This Again**. Cancel/Escape counts as *For a Week* (§3.6).
- The sheet's header says it is a suggestion and that nothing is opened ("Suggested from apps you
  open together. Creating the group doesn't open any apps.").

### 4.3 Strings and the 26 languages

Estimated **~20 new keys** under `menu.suggestions.*`, `settings.suggestions.*` and
`capture.suggestion.*`, with plural forms following the existing `.one` / `.other` pattern
(`L10n.Settings.MostUsed.launchCount`). Each is translated into all 26 `*.lproj`
`Localizable.strings` files, following the repository's translation workflow, before the UI PR
merges. `LocalizationTests.awaitingTranslation` stays empty at merge.

## 5. Fail-closed and safety rules

1. **A suggestion never acts on its own.** It never creates or edits a group, adds an item, opens,
   hides or quits an app, starts/finishes a group, installs an agent or changes a setting. The only
   path to a change is the review sheet's commit button.
2. **No automation surface.** No intent, `cybokron-dock-groups://` link, CLI command, trigger or
   Focus filter can accept a suggestion. Siri/Shortcuts capture keeps working only from open apps,
   as today.
3. **Protected apps never appear** in a suggestion (§3.2 rule 5), even though Capture lists them
   unselected. Because the review sheet lists only the suggested apps, the user can't pick one there
   either.
4. **Too little or doubtful data means no suggestion.** That covers: cold-start gates not met,
   either usage file or `suggestions-state.json` unreadable (moved aside), a newer `formatVersion`,
   `showsMostUsed` or `showsSuggestions` not exactly `true`, any app not installed or failing
   `AppItemPolicy`, and any computation error. In each case the planner returns `[]`. It never
   falls back to "show something".
5. **Crafted files can't cause actions.** A hand-edited `usage-stats.json` /
   `usage-cooccurrence.json` can at worst make a suggestion appear. The suggestion still goes
   through the eligibility gates, the item policy and a user click. Pair counts are decoded as they
   are today (non-positive and self-pairs dropped). `suggestions-state.json` can only *hide*
   suggestions. Its `apps` values are compared, never launched or resolved to paths.
6. **Backups don't carry it.** Importing a backup can't turn Suggestions on: `showsSuggestions` is
   reset to `false` when imported, like triggers coming in turned off.
7. **Standalone agents** don't read usage or suggestion files.

## 6. Test plan

### 6.1 Unit tests (`Tests/DockGroupsCoreTests/SuggestionPlannerTests.swift`, Swift Testing)

Cold start and gates:
- empty when `enabledAt` < 7 days, `activeDays` < 5, or `totalLaunchCount` < 50; non-empty
  exactly at each threshold;
- empty when `showsSuggestions` or `showsMostUsed` is off, and when state is missing.

Eligibility:
- excludes apps below 5 launches, last launched > 14 days ago, not installed, untracked
  identifiers, user-protected apps, the host app, agent prefixes and Finder; apps failing
  `AppItemPolicy`.

Algorithm:
- pair support < 5 or mutual strength < 0.35 → no pair; hub app (high launches) not pulled into
  sets;
- clique rule: an app strong with only some members isn't added; max 6, min 3; deterministic
  order and tie-breaks;
- ≥ 75 % overlap with an existing group suppresses; archived groups are ignored;
- add-to-group: the 2/3 rule, the "at least 2" rule, one app per group, global cap 2; total cap 3.

Suppression:
- `until: null` suppresses permanently; a future `until` suppresses until that moment and not
  after; Jaccard ≥ 0.75 matches, < 0.75 doesn't; add-to-group matches only the same group and app;
- dismissal list capped at 200, oldest timed-out entries pruned first.

Persistence (`SuggestionStatePersistenceTests`):
- lenient decode; unknown fields ignored; newer `formatVersion` → error → empty state; unreadable
  file moved aside; `activeDays` counts a day once and doesn't count days before `enabledAt`.

Safety:
- the planner has no side effects (value in, value out); the crafted usage file with huge counts,
  self-pairs or negative counts yields only gated suggestions; `showsSuggestions` decodes as
  `false` for anything but `true`; an imported backup resets it to `false`; Clear History deletes
  the state file; Diagnostics contains no bundle identifiers.

Localization: the existing `LocalizationTests` cover the new keys in all 26 languages.

### 6.2 Manual gates (to add to `10_MANUEL_TEST_KAPILARI.md`)

- [ ] Fresh install: Suggestions are off; the menu has no Suggestions section; no prompt.
- [ ] Turn on: explanation shown once; status reads "Watching: 0 of 5 days".
- [ ] With a prepared usage file and a moved clock (debug build only), a suggestion appears; the
      review sheet shows only the suggested apps; nothing launches when the sheet opens or commits.
- [ ] Not Now (week/month), Don't Suggest Again, Cancel: the suggestion doesn't come back early.
- [ ] Protected app opened alongside a routine never appears in a suggestion.
- [ ] Most Used off → toggle disabled, no section; Clear History deletes `suggestions-state.json`.
- [ ] Little Snitch / `nettop`: no network traffic when computing or showing suggestions.
- [ ] Console.app, all levels incl. debug: no app names or bundle identifiers from suggestion code.
- [ ] Export Diagnostics: only `Suggestions: on/off` + dismissed count.
- [ ] Backup export/import: file not included; imported backup leaves Suggestions off.
- [ ] VoiceOver reads the menu rows and the sheet header; check a long-text language (de, ru) and
      RTL (ar, fa) in the menu and sheet.
- [ ] Downgrade to 0.19.x: the extra file and the preference are ignored without errors.

## 7. Effort and slices

| # | Slice | Size | Content |
|---|---|---|---|
| 1 | Data layer | **S** | `SuggestionState` + `JSONFileSuggestionStatePersistence`, `activeDays` update hook in `UsageStore.recordLaunch`, `showsSuggestions` preference (lenient, backup reset), Clear History deletes the file, D7 log fix. Tests. |
| 2 | Algorithm | **M** | `SuggestionPlanner` (gates, eligibility, pairs, clique, add-to-group, suppression). Thresholds as constants. The bulk of the unit tests. |
| 3 | UI | **M** | Settings section, menu section, Capture sheet fed from a suggestion plan, Not Now/Don't Suggest buttons, Diagnostics line. en strings only, behind `awaitingTranslation`. |
| 4 | Localization + docs | **S** | ~20 keys × 26 languages, README / SECURITY / Application Support list, manual gates. `awaitingTranslation` emptied. |

Order: 1 → 2 → 3 → 4, one PR each. Slices 1 and 2 ship no visible change. The feature becomes
visible only when slice 3 merges, and is released only after slice 4. Overall: **M** (about
3 working sessions plus translation and manual testing).

**Risks**

- *Weak signal:* the counts aren't dated, and co-occurrence depends on the session length setting.
  Suggestions may be rare or stale. Mitigated by the 14-day `lastLaunchedAt` rule and conservative
  thresholds. Rare is acceptable; wrong is not.
- *Hub apps / login items:* apps launched at login pair with each other every day and may form a
  "suggested group" of login items. The mutual-strength rule reduces this but doesn't remove it.
  Watch it in dogfooding and consider D6.
- *Capture sheet reuse:* the sheet is built around `OpenAppsSnapshot`. A suggestion needs its own
  plan constructor. The risk is coupling, so keep the planner output a plain `CapturePlan`.
- *Perception:* even local, "the app watches what I open" can feel invasive. This is why the
  feature is off by default, has an explicit explanation, never sends anything over the network,
  and is cleared by one action.

## 8. Open product decisions (with proposed defaults)

Status: accepted 2026-11-17 with the proposed defaults (D1–D10).

| # | Question | Proposed default |
|---|---|---|
| D1 | Opt-in or on by default? | **Off by default, explicit opt-in.** Turned off on backup import. |
| D2 | Use the history recorded before opt-in? | **Yes** for counts, but suggestions only after 7 days / 5 active days since opt-in and only for apps launched in the last 14 days. |
| D3 | Separate recording switch from "Show Most Used"? | **No** in v1. Suggestions require Most Used on, and the UI explains this. |
| D4 | Turning Suggestions off: keep or delete `suggestions-state.json`? | **Keep** (consistent with Most Used). Clear History deletes it. |
| D5 | Where shown? | **Menu bar section + Settings** only. Not in the popup, agents, Siri, links or CLI. |
| D6 | Add a "Never suggest these apps" list separate from Protected Apps? | **Not in v1.** Protected apps and "Don't Suggest This Again" cover it. Revisit if login-item noise shows up. |
| D7 | Fix the existing `.debug` public bundle-id log in `UsageMonitor`? | **Yes**, in slice 1: `.private` or removed. |
| D8 | Group size range / max suggestions | **3–6 apps; at most 2 new-group + 2 add-to-group, 3 shown.** |
| D9 | Snooze lengths | **7 days** (default, also on Cancel) and **30 days**. |
| D10 | Weekday/time suggestions | **Deferred.** They need a new, separately opted-in aggregate (§3.5) and a separate review. |
