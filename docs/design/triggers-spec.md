# Design spec: automatic group triggers

- **Status:** phase 4b shipped in **0.11.0**; retained as a historical design spec.
- **Original design status:** design for review (2026-10-25). Design only: no code. The questions the user had to
  decide are answered in DECISIONS (§9); this spec is written around those answers.
- **Baseline:** `main` at `4aaddc8` (version 0.10.0, `project.yml` `MARKETING_VERSION: "0.10.0"`),
  1143 `@Test` functions, 827 `en.lproj` keys, `LocalizationTests.awaitingTranslation` empty.
- **Feature:** phase 4b, **Triggers**: a group starts, opens or shows itself when something happens
  — a time of day, a login, a display, a network. Target: **0.11.0**.
- **Builds on:** `docs/design/group-items-and-tags-spec.md` (A+F, 0.7.0),
  `docs/design/context-switching-spec.md` (C+D+E, 0.8.0; its Focus filter is the first automatic
  trigger), `docs/design/group-shortcuts-and-templates-spec.md` (G+I, 0.9.0) and
  `docs/design/capture-spec.md` (0.10.0). Their Core/App split, lenient JSON rules, separate-file
  precedent (`templates.json`), backup sanitizing, agent snapshot normalization, downgrade copies,
  link gate and PR format are reused.
- **Clean room:** behavior comes from the written acceptance criteria and this repository only.
  Claims about current code cite `file:line` at `4aaddc8` (paths relative to `Sources/` unless they
  start with `Tests/`, `docs/` or name a file at the repository root). Claims about macOS cite the
  macOS 27.0 SDK headers (Xcode 27.1, 27A9275) or Apple's documentation; what neither settles is
  marked **spike** (§2.3, TS-1…TS-11) and decided by the PR that needs it.

> **As shipped (0.11.1, 2026-10-26):** time, login/app-opening, display, screen sleep/wake,
> Ethernet and opt-in Wi-Fi triggers run only while the app runs; they never quit apps. VPNs are
> not watched or offered (TS-8), despite the conditional VPN design below. Triggers on another app
> opening or quitting remain deferred to the proposed 0.12.0 wave (Decision 7), not implemented.
> The baseline, decisions and PR plan are historical. Manual time/login, display/sleep, network
> permission, pause/budget, archived-group and downgrade checks remain open.

## Acceptance criteria (behavior)

- **TR-1** A group can have triggers. A trigger is one event, one action and how it runs: the event
  is a **time** (a time and days of the week), **login**, **Cybokron Dock Groups opening**, a
  **display** connecting or disconnecting, a **set of displays** being connected, the **screens
  waking or sleeping**, or a **network** being joined or left (a Wi-Fi network by name, Ethernet,
  a VPN where macOS shows one reliably).
- **TR-2** The action is **Show the Popup**, **Open All**, **Start** or **Finish**. A trigger never
  quits, force quits or closes an app: a group set to quit apps hides them instead, as with a Focus
  (`TransitionTrigger.mayQuit`, `Switching/TransitionPlanner.swift:19-20`).
- **TR-3** Before Open All, Start or Finish, a notice says what is about to happen and can be
  cancelled (**Not Now**); a trigger can also ask first, or run right away. **Pause Triggers** in
  the menu bar menu stops all of them for an hour, until tomorrow, or until resumed.
- **TR-4** A trigger runs at most once per occurrence: a time once per day it's due, an edge (a
  display connecting) once per change, never twice within its cooldown, and never more than the
  app-wide budget allows. A trigger's own action can't set off a chain of triggers.
- **TR-5** Triggers run while Cybokron Dock Groups runs. **Open at Login** (Settings → Triggers)
  makes macOS open the app at login; a time missed while the Mac slept or the app wasn't open runs
  when it can, up to 30 minutes late, otherwise it's skipped. Settings and the README say so, and
  point to Shortcuts automations (macOS 26 and later) for when the app is quit.
- **TR-6** Triggers need no permission, except triggers that name a Wi-Fi network: macOS shows
  network names only to apps allowed to use Location Services. That permission is asked for only
  when such a trigger is added, and every other trigger works without it.
- **TR-7** Each trigger shows when it last ran and what happened ("Started “Work” today at 9:00",
  "Skipped: triggers were paused"). The group window lists a group's triggers; Settings → Triggers
  lists them all.
- **TR-8** Nothing read from a file makes a trigger run that the user didn't turn on on this Mac:
  triggers restored from a backup come in turned off. A trigger names a group and an action from a
  fixed list, never an app, path, link or command, and acts only through Start, Finish, Open All
  and Show Popup as they are.
- **TR-9** Version 0.10.0 reads everything 0.11.0 writes without errors and loses nothing: triggers
  live in files it never opens; `groups.json`, `preferences.json` and agent configurations don't
  change.

Non-goals (this wave): a LaunchAgent, daemon or helper that runs while the app is quit (§2.6);
triggers on an app opening or quitting (0.12.0, §9 Q7), a calendar event, a location, a Bluetooth device, a battery
level or a Focus (the Focus filter already exists); actions other than the four (Hide All, Close
All, capture); conditions combined with "and"/"or"; triggers in templates or in standalone groups'
own apps; Siri intents or links that change triggers.

---

## 0. Summary and scope

### 0.1 Summary

Groups open when the user asks: a click, a key, a link, Siri, a Focus. Triggers let the Mac ask:
"weekdays at 9:00, start Work", "when the LG display connects, show Coding", "when the Mac leaves
the office Wi-Fi, finish Work". Three decisions carry most of the weight:

1. **Triggers run inside the app, while it runs — no background helper** (§2.6). The main app
   observes the clock, the workspace, the displays and the network with notifications and one
   one-shot timer; nothing polls. A LaunchAgent or daemon (`SMAppService`) would have to be a second
   always-on process for every event but time, with a static plist that can't hold the user's
   times, re-registration after every update, user approval in Login Items and two processes to
   keep from acting twice — for what Shortcuts automations on macOS 26 can already do with the
   existing Start Group intent (TS-10). Instead: **Open at Login** (`SMAppService.mainApp`, no helper), a
   30-minute catch-up for missed times, and a documented Shortcuts recipe for the quit app.
2. **Triggers live in their own files, keyed by group identifier** (§2.7): `triggers.json` holds
   the rules (user intent, in backups), `trigger-state.json` the runtime state (last runs, pause,
   per-trigger condition states; a convenience like `update-state.json`). Neither `groups.json`
   nor `preferences.json` gains a key, so 0.10.0 keeps them byte for byte, agents see nothing
   (`AgentConfiguration` unchanged), and a trigger whose group isn't in `store.groups` — archived,
   deleted, unreadable — is inert by construction (fail closed).
3. **One funnel, modeled on the Focus coordinator, with a new non-quitting trigger** (§2.4, §2.5).
   Sources turn system changes into plain values; a pure Core `TriggerEvaluator` turns values,
   rules and state into firings (edges, catch-up, once a day, cooldowns); a `TriggerCoordinator`
   settles them for 2 seconds, reduces conflicting ones (one Start wins), applies pause and budget,
   shows the notice, and carries the rest out one at a time through `ContextSwitcher` and
   `GroupLauncher` with `TransitionTrigger.automation` (never quits, never asks). Loops are cut by
   per-trigger cooldowns, a 15-second echo window after every automatic action, `ContextSession`'s
   3-second repeat rule and an hourly budget that pauses triggers.

### 0.2 Scope

| In | Out (and where it would go) |
| --- | --- |
| Time: a time + days (weekdays, weekends, any set), catch-up up to 30 minutes (TR-1, TR-5) | Dates, intervals ("every 2 hours"), sunrise/sunset |
| At login; when Cybokron Dock Groups opens (not after an update or language restart) | When another app opens or quits (0.12.0, §9 Q7) |
| A display connects / disconnects (any external or one display); a set of displays is connected | Display positions or resolutions; mirroring; Sidecar/AirPlay as their own kind |
| The screens wake / sleep | Lock and unlock (no documented signal, TS-11) |
| Wi-Fi network joined / left (Location permission, opt-in); Ethernet connects / disconnects; VPN connects / disconnects if TS-8 passes | Router address, gateway hardware address or other ways around macOS's network name protection (§4.2 T-S9) |
| Show the Popup, Open All, Start, Finish (hiding only) | Hide All, Close All, quitting of any kind |
| Notice with Not Now, Ask First, Run Right Away; Pause Triggers; last run per trigger | System notifications (need a permission prompt) |
| Group window Triggers section; Settings → Triggers overview; menu bar pause | Per-trigger icons in the Dock; a menu bar countdown |
| Open at Login with `SMAppService.mainApp` | LaunchAgent/daemon helper (§2.6 options b, c) |
| `triggers.json`, `trigger-state.json`; backups carry triggers, imported off | iCloud sync of triggers |

### 0.3 Current-state inventory (what this wave builds on)

| Area | Where | What it does today |
| --- | --- | --- |
| Automatic trigger kind | `DockGroupsCore/Switching/TransitionPlanner.swift:5-25` | `userAction, link, intent, focus, shortcut`; `mayQuit` is false only for `.focus`; `asksBeforeQuitting` for link, intent, shortcut |
| Quitting becomes hiding | `Model/GroupSwitching.swift:57-63`, `TransitionPlanner.swift:115`, `:152` | `withoutQuitting` when the trigger may not quit |
| One transition at a time | `Switching/ContextSwitcher.swift:191-209` | `oneAtATime` queues Start/Finish in order, without polling |
| Repeat rule | `Switching/ContextSession.swift:14-17`, `:37-41` | a Start of the current group within 3 s does nothing, whoever asked |
| Who started the current group | `ContextSession.swift:24-26`, `:44-49` | `startedAt`, `startTrigger`; memory only, empty at launch |
| Focus funnel | `Switching/FocusRequestCoordinator.swift:53-202` | 1 s settle, last call wins, waits for the app, one at a time, "finish when it ends" only if still current and started by it, Open All/Show Popup repeat rule |
| Focus only while running | `CybokronDockGroups/Intents/GroupFocusFilter.swift:28-31`; `docs/design/focus-spike.md:39` | no App Intents extension: macOS doesn't launch the app to deliver the filter (D-A1) |
| Focus handler | `CybokronDockGroups/App/AppDelegate.swift:700-731`, `:263` | starts/finishes with the given trigger, Open All, Show Popup; handler set after launch |
| Wake handling | `CybokronDockGroups/Updates/AutoUpdater.swift:144-147`, `:166-178` | `didWakeNotification` re-checks; a repeating timer with 60 s tolerance |
| Workspace notifications | `CybokronDockGroups/Support/RunningAppsMonitor.swift:18-31` | launch, terminate, wake observers on `NSWorkspace.notificationCenter` |
| Relaunches | `AutoUpdater.swift:441-463`; `CybokronDockGroups/Support/AppLanguageSupport.swift:62-86` | update and language changes relaunch the app through `/usr/bin/open`, no argument |
| Reopen shows a popup | `AppDelegate.swift:276-289` | opening the running app again shows a popup: a helper must never "open" a running app |
| Second copies | `AppDelegate.swift:185-200`; `App/SecondCopyHandoff.swift` | a second copy hands its URLs over and quits before loading anything |
| Agents share the executable | `App/CybokronDockGroupsMain.swift:8-19` | the bundle identifier selects `AgentAppDelegate`; only `AppDelegate` runs the updater, capture, shortcuts |
| Separate-file precedent | `DockGroupsCore/Persistence/TemplatePersistence.swift:48-83` | `templates.json`: "a file versions without templates never open, so going back and forth keeps them" |
| State-file precedent | `DockGroupsCore/Updates/UpdateState.swift:3-5`, `:71-94` | `update-state.json`, apart from preferences "because it changes with every check"; missing = fresh |
| Groups document | `Persistence/GroupPersistence.swift:52-87` | `{formatVersion: 1, groups: […]}`, archived entries after active ones |
| Preferences coding | `Model/PopupPreferences.swift:155-239` | lenient keys; new keys written only when not default |
| Agent snapshot | `Standalone/AgentConfiguration.swift:17-34` | resets what agents don't use |
| Backups | `Persistence/SettingsBackup.swift:372-408`, `:186-201`; `Store/SettingsBackup+Stores.swift:25-77` | optional `templates` (written only when some), sanitized import; Replace All / Merge |
| Downgrades | `Updates/DowngradeProtection.swift:17-21`, `:100-115`; `Updates/ReleaseHistory.swift:39-47` | copies of `groups.json` + `preferences.json` before an older install; warnings by feature |
| Templates and duplicates | `Model/GroupTemplate.swift:10-11`, `:46-60`; `Store/GroupStore.swift:212` | blueprints drop the shortcut and standalone state |
| Archive | `Store/GroupStore.swift:103-107`, `:238`, `:252` | archived groups leave `groups` (and every consumer) but stay in the file |
| Menu bar menu | `CybokronDockGroups/MenuBar/StatusBarController.swift:84-129` | groups, Most Used, capture, Manage Groups…, Settings…, About, updates, Quit |
| Settings panes | `CybokronDockGroups/Settings/SettingsWindowController.swift:126-134` | Popup, Shortcuts & Siri, Switching, Most Used, Updates, Backup, Changelog, Support |
| Group window sections | `CybokronDockGroups/MainWindow/GroupDetailView.swift:96-102` | Group, Items, Start and Finish, Keyboard Shortcut, Dock Tile, Standalone, Popup |
| Non-activating panel | `CybokronDockGroups/Popup/PopupPanel.swift:10-19` | borderless `.nonactivatingPanel`: shows without taking the keyboard |
| Signing | `project.yml:24`, `:69`; `scripts/build-app.sh:191-195`; `Standalone/AgentInstaller.swift:226-235` | hardened runtime, no entitlements file; agents re-signed ad hoc |
| Login item | — | none today: the app has no "open at login" setting |

### 0.4 Rules carried over from earlier specs

- C+D+E §2.5: an automatic trigger nobody watches never quits and never asks a question (Focus).
  Triggers follow it with a trigger kind of their own, so the log, the session and the Focus rules
  tell them apart.
- C+D+E §3.6 and `focus-spike.md`: without an extension, the Focus filter reaches the app only
  while it runs, and the app says so instead of promising more. Triggers make the same promise.
- G+I §2.8: a feature whose data older versions must not drop gets its own file.
- G+I §2.10 and capture §2.10: a new setting is normalized out of `AgentConfiguration` unless agents
  use it. Triggers add no setting agents see.
- Capture CP-6 (no permission, no prompt) sets the bar: triggers ask for none, except the Wi-Fi
  part, which can't work without Location access, and only when the user adds such a trigger.

---

## 1. User behavior

### 1.1 Words used in this spec and in the app

| Term | Meaning |
| --- | --- |
| **Trigger** | "When this happens, do that to this group." Shown as "Triggers" in the group window and Settings. |
| **Event** | What a trigger waits for: a time, a login, a display, a network. |
| **Action** | Show the Popup, Open All, Start or Finish. |
| **Run** | A trigger acting. Shown as "ran", "Last ran". |
| **Notice** | The small panel that says what a trigger is about to do, with Not Now. |
| **Paused** | No trigger runs; occurrences while paused are skipped, not kept for later. |
| **Edge** | A change: a display connecting is the start of "the display is connected", disconnecting its end. |

### 1.2 What a trigger is

- A trigger belongs to one group and has: an **event** (§1.3–§1.5), an **action** (§1.6), **how it
  runs** (§1.7) — *Show a 5-second notice* (default for Open All, Start, Finish), *Ask First*, *Run
  Right Away* (default and only choice for Show the Popup) — and two options: **At most once a day**
  (off by default), and, for Start on an event that has an end, **Finish when it ends** (off by
  default, as the Focus filter's "Finish the Group When This Focus Turns Off").
- A trigger can be turned off without deleting it (a checkbox in its row).
- At most **10 triggers per group** and **100 in all** (`GroupTrigger.maximumPerGroup`,
  `.maximumCount`). Add Trigger… is disabled at the limit, with "A group can have up to 10
  triggers."
- Two triggers of one group with the same event and action are allowed (one may be off); the
  reducer runs the action once (§1.8).

### 1.3 Events: time and app lifecycle

| Event (en-US) | Fires | Details |
| --- | --- | --- |
| **At a Time** — "At 9:00 on weekdays" | when the wall clock reaches the time on one of the chosen days | minutes 0…1439 in the Mac's current time zone; days are an explicit set of weekdays; the **Weekdays**, **Weekends** and **Every Day** buttons fill it from the user's calendar (`Calendar.current` weekend days, so Friday–Saturday weekends work), but the stored set doesn't change when the region does |
| **At Login** | once per login session, when the app is opened at login | needs the app to open at login (Open at Login, or added by hand); the session is identified by its start time (TS-3) |
| **When Cybokron Dock Groups Opens** | each time the app is opened normally | not when it was opened to handle a link or a Siri/Shortcuts request, not after an update or a language restart (§2.5 quiet launch), not a second copy |
| **When the Screens Wake** | the displays wake (`NSWorkspace.screensDidWakeNotification`), after the Mac's wake too | 60 s cooldown: displays that wake twice in a row run it once |
| **When the Screens Sleep** | the displays sleep (`screensDidSleepNotification`) | Finish only (§1.6) |

**Daylight saving and clock changes.** A time that doesn't exist that day (02:30 when clocks spring
forward) runs at the next valid minute (03:00); a time that happens twice (01:30 when clocks fall
back) runs the first time only (`Calendar.nextDate(after:matching:matchingPolicy: .nextTime,
repeatedTimePolicy: .first)`). Changing the clock or the time zone re-plans the next due time; an
occurrence jumped over isn't run unless the catch-up rule (§1.10) covers it.

### 1.4 Events: displays

| Event | Fires | Details |
| --- | --- | --- |
| **When a Display Connects** — any external display, or a chosen one | an external display is added to the settled display set | the built-in display never counts as "a display connecting" (closing the lid isn't an event) |
| **When a Display Disconnects** — likewise | an external display leaves the settled set | |
| **When These Displays Are Connected** — the set chosen with **Use Current Displays** | the settled set becomes exactly the saved set (built-in included or not) | positions, resolution, mirroring and which display is main don't matter |
| …its end, **When These Displays Are No Longer Connected** | the set stops matching | |

- **Settled set.** Displays are read 2 seconds after the last `NSApplication.didChangeScreenParameters`
  notification, so a monitor that flickers on wake or a resolution change counts once or not at all.
  An edge is the difference between this settled set and the last settled set **kept across sleep
  and launches** (per trigger, §2.7): a monitor that stays connected through sleep isn't "connected"
  again on wake (TS-6).
- **A display's identity** is what CoreGraphics reports without permission: vendor, model and serial
  numbers, the name (`NSScreen.localizedName`) and whether it's built in. A serial of 0 or a
  placeholder (0x01010101, which this Mac's monitor reports) is ignored; then vendor + model + name
  identify it, and two identical monitors count as two of the same kind (§2.3, TS-5).
- The chooser lists the displays connected now; a saved display that isn't connected is shown by
  name, "not connected".

### 1.5 Events: network

| Event | Fires | Permission |
| --- | --- | --- |
| **When the Mac Joins a Wi-Fi Network** — by name | the Wi-Fi network name read after the network settled becomes the chosen one | **Location Services** (§2.3) |
| **When the Mac Leaves a Wi-Fi Network** — by name | it stops being the chosen one (another network, Wi-Fi off, Ethernet only) | Location Services |
| **When Ethernet Connects / Disconnects** | a wired interface starts / stops being used for the network path | none |
| **When a VPN Connects / Disconnects** | the primary network service becomes / stops being a tunnel | none; **only if TS-8 shows it's reliable**, else this event isn't offered in 0.11.0 |

- Network readings settle 5 seconds after the last change (roaming between access points, DHCP).
- **Unknown never makes an edge.** A Wi-Fi name the app can't read (no permission, permission taken
  back, macOS redacting it) is "unknown", not "left": a "leaves" trigger never runs because the app
  lost sight of the network. The same holds for displays and the VPN state.
- Names are matched exactly as macOS reports them (case-sensitive, since network names are). The
  chooser offers the current network ("Use Current Network", when readable) or a typed name (1–32
  bytes in UTF-8, no control characters).

### 1.6 Actions, and which events allow them

| Event | Show the Popup | Open All | Start | Finish |
| --- | --- | --- | --- | --- |
| At a Time | ✓ | ✓ | ✓ | ✓ |
| At Login, When Cybokron Dock Groups Opens | ✓ | ✓ | ✓ | — (no group is current right after launch, C+D+E §2.4) |
| When the Screens Wake | ✓ | ✓ | ✓ | — |
| When the Screens Sleep | — | — | — | ✓ (nobody sees a popup or opened apps while the screens sleep) |
| Display, displays, Wi-Fi, Ethernet, VPN: start or end | ✓ | ✓ | ✓ (+ Finish when it ends, on starts) | ✓ |

- **Show the Popup**: as the group's popup opens from a link (`popupController.show`), non-activating.
- **Open All**: as the Open All button, launch options and delays included.
- **Start**: as Start, with `TransitionTrigger.automation`: "Quit the previous group's apps" acts as
  hiding; never a question (C+D+E §2.5).
- **Finish**: only when the group is the current group; otherwise skipped ("“Work” wasn't the
  current group"). "Quit its apps" acts as hiding. Finish shows the previous group again as the
  group's "After finishing" setting says.
- **Finish when it ends** (Start on a start edge only): when the event's end comes, the group is
  finished — hiding only — **if it's still current and this trigger started it**, exactly the Focus
  rule (`FocusRequestCoordinator.swift:155-177`). If the user started another group meanwhile,
  nothing happens.
- A trigger never quits, force quits, closes or captures anything. It hides apps only through
  Finish and through Start's own "hide" settings, and protected apps are left alone as always.

### 1.7 How a trigger runs: notice, ask first, right away

- **Show a 5-second notice** (default for Open All, Start, Finish). A small panel appears at the top
  right of the screen with the menu bar: "Starting “Work” — At 9:00 on weekdays" and a 5-second
  countdown, with **Not Now** and **Start Now**. It doesn't take the keyboard (non-activating, as
  the popup, `PopupPanel.swift:19`). When the countdown ends, the action runs. Not Now skips this
  occurrence only.
- **Ask First**: the same panel without a countdown, "Start “Work”?" with **Not Now** and **Start**;
  it waits up to 2 minutes, then closes and the occurrence is skipped ("Nobody answered").
- **Run Right Away**: no panel. The only choice for Show the Popup, whose popup is its own notice.
- One notice at a time. A newer firing that replaces a waiting one (§1.8) replaces its notice; others
  wait their turn behind it.
- While the screens sleep or the user's session isn't the active one (fast user switching), the
  notice and the action wait until the screens wake and the session is active again, within the
  catch-up window (§1.10); then the countdown starts.
- VoiceOver announces the notice ("Cybokron Dock Groups will start Work in 5 seconds. Not Now,
  button."); the panel's buttons are reachable with the VoiceOver cursor.

### 1.8 When several triggers fire together

Firings that become due within one 2-second settle window are reduced before anything runs:

1. **Finish** of different groups run first, each group once.
2. **Start**: at most one — the latest occurrence (ties: the trigger listed first in Settings →
   Triggers). The others are recorded as "Skipped: another trigger started “Design”".
3. **Open All**: each group once; skipped for the group just started (Start opens it anyway).
4. **Show the Popup**: at most one, the latest; skipped when that group was just started or opened.

A Focus filter and a trigger asking for the same Start within 3 seconds start it once
(`ContextSession.repeatInterval`); a Shortcuts automation likewise.

### 1.9 Repeats, cooldowns, loops and pausing

- **Once per occurrence.** A time runs once on a given day; an edge once per change.
- **Cooldown:** a trigger doesn't run again within **60 seconds** of its last run (screens waking
  twice, a network flapping).
- **At most once a day** (option): after it ran, the trigger waits until the next calendar day
  (midnight in the current time zone).
- **Echo window:** for **15 seconds** after an automatic action finished, display and network edges
  are taken into the state but run nothing: an app the action opened (a VPN client, a display
  driver) can't set off another trigger. Logged: "ignored right after an automatic action".
- **Budget:** at most **12 automatic actions per hour** across all triggers. The 13th pauses all
  triggers for an hour; the menu bar menu and Settings say "Triggers paused for an hour: they ran
  12 times in an hour."
- **Pause Triggers** (menu bar menu): **For 1 Hour**, **Until Tomorrow** (next midnight), **Until I
  Resume Them**. The menu then shows **Resume Triggers** and the reason. Occurrences while paused are
  skipped ("Skipped: triggers were paused"), not run after the pause.

### 1.10 Missed times, sleep and the app not running

- A **time** whose moment passed while the Mac slept, the screens slept, the session was inactive or
  the app wasn't open runs as soon as it can (wake, session active, launch) **if it's at most 30
  minutes late**; otherwise it's skipped and shown as "Missed at 9:00: the Mac was asleep" or "…the
  app wasn't open". Only the latest missed occurrence of a trigger can run.
- **Edges** while the app wasn't open: the first settled reading after launch is compared with the
  last one kept from before; a difference is an edge. "Joined the office Wi-Fi since the app last
  looked" runs once; an unchanged state runs nothing. A trigger added just now has no earlier
  reading: its first reading is its baseline, and nothing runs until the next change.
- **The first launch of 0.11.0**, or a missing `trigger-state.json`: past occurrences of today count
  as handled; nothing catches up.

### 1.11 When the app isn't running

- Triggers are evaluated by the running app only (§2.6). The group window's Triggers section and
  Settings → Triggers say: "Triggers run while Cybokron Dock Groups is open." The Quit item's
  tooltip adds "Triggers don't run while it's quit." when any trigger is on.
- **Open at Login** (Settings → Triggers): a checkbox that registers the app itself as a login item
  (`SMAppService.mainApp`, §2.6). It's never turned on by itself; adding an At Login trigger while it
  is off shows "At Login triggers need Cybokron Dock Groups to open at login. [Turn On Open at Login]".
  When macOS needs the user's approval, the row says so with **Open Login Items Settings…**
  (`SMAppService.openSystemSettingsLoginItems()`).
- **When the app is quit** on macOS 26 and later, the Shortcuts app's own automations (Time of Day,
  Wi-Fi, Display, App, …) can run the existing **Start Group**, **Launch Group** or **Show Group**
  actions; Settings → Triggers and the README describe it, as the README already does for Focus
  (`README.md:67-70`). Whether such an automation opens the quit app is TS-10.

### 1.12 Groups: archived, deleted, renamed, duplicated, templates, standalone

- **Renamed**: triggers follow (they name the group by identifier).
- **Archived**: its triggers stay but don't run: they're looked up in `store.groups`, which has no
  archived groups. The archived group's page says "2 triggers (they don't run while the group is
  archived)"; **Restore** brings them back working, as a shortcut comes back.
- **Deleted** (or deleted from the archive): its triggers are deleted with it, once the group list
  was read without problems (an unreadable `groups.json` never deletes triggers).
- **Duplicate** and **Save as Template** don't copy triggers (as the keyboard shortcut,
  `GroupTemplate.swift:10-11`): two groups starting at 9:00 by accident would be worse than adding
  the trigger again.
- **Standalone groups**: triggers run in the main app; Show the Popup shows the main app's popup of
  the group, as Focus does. The group's own app knows nothing of triggers.

### 1.13 Backups and other versions

- **Export** includes the triggers (rules only, not their last runs).
- **Import, Replace All**: when the backup has triggers, they replace the current ones, **all turned
  off**; the summary says "It has 3 triggers. They come in turned off: turn them on in Settings →
  Triggers." Without triggers in the backup, current triggers of groups that still exist stay.
- **Import, Merge**: the backup's triggers of the groups the merge adds come in, turned off.
- **0.10.0 and earlier** never open `triggers.json`; nothing is lost going back and forth. The
  downgrade question gains one line when any trigger is on: "Version 0.10.0 doesn't run triggers.
  They're kept and run again after you update." and, when Open at Login is on, "Cybokron Dock Groups
  still opens at login; turn that off in System Settings → General → Login Items."

### 1.14 en-US text drafts

| Where | Text |
| --- | --- |
| Group window section | "Triggers" · footer "Triggers run while Cybokron Dock Groups is open. They never quit apps." |
| Empty section | "No triggers. A trigger starts, opens or shows this group when something happens." |
| Buttons | "Add Trigger…" · "Edit…" · "Remove" · "Turn On" |
| Sheet titles | "New Trigger for “%@”" · "Edit Trigger" |
| When pop-up | "At a Time" · "At Login" · "When Cybokron Dock Groups Opens" · "When the Screens Wake" · "When the Screens Sleep" · "When a Display Connects" · "When a Display Disconnects" · "When These Displays Are Connected" · "When These Displays Are No Longer Connected" · "When the Mac Joins a Wi-Fi Network" · "When the Mac Leaves a Wi-Fi Network" · "When Ethernet Connects" · "When Ethernet Disconnects" · "When a VPN Connects" · "When a VPN Disconnects" |
| Time controls | "Time" · "Days" · "Weekdays" · "Weekends" · "Every Day" |
| Display controls | "Any External Display" · "Use Current Displays" · "%@ (not connected)" |
| Wi-Fi controls | "Network Name" · "Use Current Network" · "macOS shows Wi-Fi network names only to apps allowed to use Location Services." · "Allow…" |
| Do pop-up | "Show the Popup" · "Open All" · "Start" · "Finish" |
| How pop-up | "Show a 5-Second Notice" · "Ask First" · "Run Right Away" |
| Options | "At most once a day" · "Finish when it ends" |
| Summaries | "At 9:00 on weekdays: start" · "At login: show the popup" · "When “LG UltraFine” connects: open all" · "When the Mac leaves “Office”: finish" |
| Last run | "Last ran today at 9:00: started “Work”." · "Skipped today at 9:00: triggers were paused." · "Skipped: you chose Not Now." · "Missed at 9:00: the Mac was asleep." · "Not run yet." · "Waiting for Location access." · "Doesn't run while the group is archived." |
| Notice | "Starting “%@”" · "Opening “%@”" · "Finishing “%@”" · "Start “%@”?" · "Not Now" · "Start Now" · "Open Now" · "Finish Now" |
| Menu bar | "Pause Triggers" ▸ "For 1 Hour" · "Until Tomorrow" · "Until I Resume Them" · "Resume Triggers" · "Triggers paused until %@" |
| Budget | "Triggers paused for an hour: they ran %ld times in an hour." |
| Settings pane | "Triggers" · "Open at Login" · "Opens Cybokron Dock Groups when you log in, so At Login and other triggers can run." · "macOS needs your approval in Login Items." · "Open Login Items Settings…" · "When Cybokron Dock Groups is quit, the Shortcuts app's automations can still start a group (macOS 26 and later)." |
| Location | "Location Access" · "Allowed" · "Not allowed: Wi-Fi triggers can't see network names." · "Open Privacy Settings…" |
| Limits | "A group can have up to 10 triggers." · "You can have up to 100 triggers." |
| Backup | "It has 1 trigger. It comes in turned off…" / "It has %ld triggers. They come in turned off: turn them on in Settings → Triggers." |
| Info.plist | `NSLocationUsageDescription`: "Cybokron Dock Groups reads the name of the Wi-Fi network your Mac is on, only to run the triggers you set for Wi-Fi networks. macOS treats network names as location information. Your location is never read, kept or sent anywhere." |

---

## 2. Architecture

### 2.1 Layers and files

| Layer | New or changed | Purpose |
| --- | --- | --- |
| Core model | `Model/GroupTrigger.swift` (new) | `GroupTrigger`, `TriggerEvent`, `TriggerSchedule`, `TriggerCondition`, `TriggerAction`, `TriggerRunMode`; rules and limits; lenient coding with unknown kinds kept |
| Core model | `Model/DisplayIdentity.swift`, `Model/WiFiNetworkName.swift` (new) | display identity and matching; a validated network name |
| Core triggers | `Triggers/TriggerSignals.swift` (new) | plain values the sources deliver: clock, launch kind, screens, session, displays, network |
| Core triggers | `Triggers/TriggerScheduling.swift` (new) | next and latest occurrence of a schedule (`Calendar`, DST policies) |
| Core triggers | `Triggers/TriggerEvaluator.swift` (new) | pure: signal + rules + state + now → firings and the new state (edges, catch-up, cooldowns, once a day) |
| Core triggers | `Triggers/TriggerReducer.swift`, `Triggers/TriggerBudget.swift` (new) | §1.8 precedence; pause, budget, echo window |
| Core triggers | `Triggers/TriggerCoordinator.swift` (new) | settle, reduce, notice, carry out one at a time, write state (modeled on `FocusRequestCoordinator`) |
| Core persistence | `Persistence/TriggerPersistence.swift`, `Persistence/TriggerStatePersistence.swift` (new) | `triggers.json`, `trigger-state.json` |
| Core store | `Store/TriggerStore.swift` (new) | published triggers, add/update/delete/enable, limits, pruning, flush on quit |
| Core switching | `Switching/TransitionPlanner.swift` (changed) | `TransitionTrigger.automation` |
| Core backup | `Persistence/SettingsBackup.swift`, `Store/SettingsBackup+Stores.swift` (changed) | optional `triggers`, imported off; summary notes |
| Core updates | `Updates/ReleaseHistory.swift`, `Updates/DowngradeProtection.swift` (changed) | `firstTriggersVersion`, warning lines |
| Core diagnostics | `Diagnostics/DiagnosticsReport.swift` (changed) | counts, pause, login item, location status |
| App | `Triggers/TriggerController.swift` (new) | owns sources, wiring, App Nap activity before due times, login and launch kind |
| App | `Triggers/ClockSource.swift`, `WorkspaceSource.swift`, `DisplaySource.swift`, `NetworkSource.swift`, `WiFiSource.swift` (new) | system → `TriggerSignal` |
| App | `Triggers/LoginItem.swift`, `Triggers/LocationAccess.swift` (new) | `SMAppService.mainApp`; Location authorization only (never location updates) |
| App | `Triggers/TriggerNoticePanel.swift` (new) | the notice (§1.7) |
| App | `MainWindow/GroupTriggersSection.swift`, `MainWindow/TriggerEditorSheet.swift` (new); `GroupDetailView.swift`, `ArchivedGroupView.swift` (changed) | per-group list, editor, archived note |
| App | `Settings/TriggersSettingsView.swift` (new); `SettingsWindowController.swift` (changed) | `SettingsPane.triggers` |
| App | `StatusBarController.swift`, `AppDelegate.swift`, `AutoUpdater.swift`, `AppLanguageSupport.swift`, `SettingsBackupController.swift`, `UpdatesSettingsView.swift`/`OtherVersionsView.swift` (changed) | pause menu, `AutomationHandling`, quiet-launch marker, backup and downgrade notes |
| Bundle | `Resources/Info.plist`, `Resources/CybokronDockGroups.entitlements` (new), `project.yml`, `scripts/build-app.sh` (changed, PR 4 only) | `NSLocationUsageDescription`; `com.apple.security.personal-information.location` |

### 2.2 Core types

```swift
/// "When this happens, do that to this group." Names the group by identifier and acts only through
/// the four actions; holds no app, path, link or command (T-S2).
public struct GroupTrigger: Identifiable, Hashable, Sendable {
    public static let maximumPerGroup = 10
    public static let maximumCount = 100
    public let id: UUID
    public var groupID: DockGroup.ID
    public var event: TriggerEvent
    public var action: TriggerAction
    public var runMode: TriggerRunMode          // notice (5 s), askFirst, immediately
    public var isEnabled: Bool
    public var oncePerDay: Bool
    public var finishesWhenEventEnds: Bool      // Start on a start edge only (§1.6)
    /// Whether this rule can run: a known event, an allowed action for it, valid values.
    public var isRunnable: Bool
}

public enum TriggerEvent: Hashable, Sendable {
    case schedule(TriggerSchedule)
    case login
    case appOpens
    case screensWake
    case screensSleep
    case condition(TriggerCondition, edge: Edge)        // .starts / .ends
    /// An event a newer version wrote: kept as read, written back unchanged, never runs (§2.7).
    case unsupported(kind: String, raw: JSONValue)
    public enum Edge: String, Codable, Sendable { case starts, ends }
}

public struct TriggerSchedule: Hashable, Sendable {
    public var minuteOfDay: Int                 // 0…1439
    public var weekdays: Set<Int>               // Calendar weekday numbers 1…7, not empty
}

public enum TriggerCondition: Hashable, Sendable {
    case display(DisplayMatch)                  // .anyExternal | .display(DisplayIdentity)
    case displays(DisplayArrangement)           // an exact multiset of identities, 1…8
    case wifi(WiFiNetworkName)
    case ethernet
    case vpn                                    // offered only if TS-8 passes
}

public enum TriggerAction: String, Codable, CaseIterable, Sendable { case showPopup, openAll, start, finish }
public enum TriggerRunMode: String, Codable, CaseIterable, Sendable { case notice, askFirst, immediately }

public struct DisplayIdentity: Hashable, Codable, Sendable {
    public var vendor: UInt32, model: UInt32
    public var serial: UInt32?                  // nil for 0 and placeholders such as 0x01010101
    public var name: String                     // at most 100 characters, control characters removed
    public var isBuiltIn: Bool
    public func matches(_ other: DisplayIdentity) -> Bool   // serial when both have one, else name
}

/// What the sources report; values only, so every rule is testable without AppKit (§6).
public enum TriggerSignal: Equatable, Sendable {
    case clock(Date)                                  // the timer fired, or a re-plan (wake, clock change)
    case launched(LaunchKind)                         // .login(sessionStart), .normal, .quiet
    case screens(asleep: Bool)
    case session(active: Bool)
    case displays([DisplayIdentity]?)                 // settled; nil = unreadable
    case network(NetworkReading)                      // settled
}
public struct NetworkReading: Equatable, Sendable {
    public var usesEthernet: Bool?
    public var wifiName: WiFiNetworkName??            // .none unknown, .some(nil) not on Wi-Fi
    public var tunnelIsPrimary: Bool?
}

/// `trigger-state.json`: what the evaluator and coordinator remember. A convenience: losing it
/// only means "today's past occurrences are handled" (§1.10).
public struct TriggerState: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var lastRunAt: Date?
        public var lastOutcome: TriggerOutcome?       // .started, .opened, .shown, .finished, .skipped(reason), .missed(reason)
        public var lastHandledOccurrence: Date?       // schedules
        public var condition: Bool?                   // conditions: last known value, nil = unknown
    }
    public var entries: [GroupTrigger.ID: Entry]
    public var pausedUntil: Date?                     // .distantFuture = until resumed
    public var pauseReason: PauseReason?              // .user, .budget
    public var lastLoginSession: Date?
    public var quietLaunchUntil: Date?
    public var recentRuns: [Date]                     // the last hour, for the budget
}

public struct TriggerFiring: Equatable, Sendable {
    public let triggerID: GroupTrigger.ID
    public let groupID: DockGroup.ID
    public let action: TriggerAction
    public let occurrence: Date                       // the due time, or when the edge settled
    public let isFinishWhenEnded: Bool
}

public enum TriggerEvaluator {
    public static func evaluate(_ signal: TriggerSignal, rules: [GroupTrigger], state: TriggerState,
                                activeGroups: Set<DockGroup.ID>, now: Date, calendar: Calendar)
        -> (firings: [TriggerFiring], state: TriggerState)
    /// When the clock source must wake up next: the earliest due schedule, or nil.
    public static func nextDue(rules: [GroupTrigger], state: TriggerState, after now: Date, calendar: Calendar) -> Date?
}

@MainActor public protocol AutomationHandling: AnyObject {
    func group(withID id: DockGroup.ID) -> DockGroup?
    var currentGroupID: DockGroup.ID? { get }
    var currentGroupStartTrigger: TransitionTrigger? { get }
    func startGroup(_ id: DockGroup.ID, trigger: TransitionTrigger) async -> TransitionReport?
    func finishGroup(_ id: DockGroup.ID, trigger: TransitionTrigger, showsPrevious: Bool) async -> TransitionReport?
    func openAllItems(of group: DockGroup) async -> LaunchReport
    func showPopup(of group: DockGroup)
}

@MainActor public protocol TriggerNoticePresenting: AnyObject {
    /// Shows the notice and returns the user's answer: .run (countdown ended or Start Now),
    /// .notNow, .timedOut (Ask First), .replaced (a newer firing took its place).
    func present(_ notice: TriggerNotice) async -> TriggerNoticeAnswer
    func dismiss()
}
```

`TransitionTrigger.automation` joins the enum (`TransitionPlanner.swift:5-25`): `mayQuit` becomes
`self != .focus && self != .automation`; `asksBeforeQuitting` is unchanged (false for it), so
`ContextSwitcher.confirmed` never asks (`ContextSwitcher.swift:169-189`). Its raw value
`"automation"` is what logs and `ContextSession.startTrigger` show.

### 2.3 Reading the system: APIs, permissions, spikes

| Information | API | Permission | Evidence |
| --- | --- | --- | --- |
| Time, day changes, clock and time zone changes | `Timer`/`DispatchSourceTimer`; `NSCalendarDayChanged`, `NSSystemClockDidChange`, `NSSystemTimeZoneDidChange` | none | Foundation headers (`NSCalendar.h:685`, `NSDate.h:15`, `NSTimeZone.h:219`) |
| Mac and screens sleep/wake, session switch | `NSWorkspace` `willSleep`, `didWake`, `screensDidSleep`, `screensDidWake`, `sessionDidBecomeActive`, `sessionDidResignActive` | none | `NSWorkspace.h:322-330`; already used for wake (`AutoUpdater.swift:144-147`) |
| Display list and identity | `NSScreen.screens`, `deviceDescription["NSScreenNumber"]` (the `CGDirectDisplayID` property is macOS 26+ only, `NSScreen.h:73`), `localizedName` (10.15+), `CGDisplayIsBuiltin`, `CGDisplayVendorNumber`, `ModelNumber`, `SerialNumber`; `NSApplication.didChangeScreenParametersNotification` | none | headers (`CGDisplayConfiguration.h:305-367`); a run on this Mac read "VX2776-4K-mhd", vendor 23139, model 28983, serial 16843009 (= 0x01010101, a placeholder) with no prompt |
| Network path: Ethernet, Wi-Fi in use, other interfaces | `NWPathMonitor` (`usesInterfaceType(.wiredEthernet / .wifi / .other)`) | none | a run on this Mac: `wired: true`, interfaces `en0:wiredEthernet`, `en1:wifi`, no prompt |
| Primary service (VPN heuristic) | `SCDynamicStore` `State:/Network/Global/IPv4` `PrimaryInterface` | none | this Mac: `PrimaryInterface: en0`; **ten `utun` interfaces exist with no VPN** (`ifconfig -l`), so "a utun exists" means nothing — TS-8 |
| Wi-Fi network name | `CWWiFiClient.shared().interface()?.ssid()`, `CWEventTypeSSIDDidChange` | **Location Services authorization** | `CWInterface.h:103`: "SSID information is not available unless Location Services is enabled and the user has authorized the calling app"; on this Mac (Wi-Fi `en1` active, `ipconfig getsummary en1`: `SSID : <redacted>`), an unauthorized process got `ssid() == nil`, `bssid() == nil` |
| Location authorization | `CLLocationManager.authorizationStatus`, `requestWhenInUseAuthorization()` or `requestAlwaysAuthorization()` (both macOS 10.15+; on macOS the granted status is `.authorizedAlways`, `WhenInUse` is iOS only, `CLLocationManager.h:64-79`, `:456-528`; which request an `LSUIElement` app should make is TS-7) | prompts once | needs `NSLocationUsageDescription` ("required if your macOS app uses APIs that access the user's location information", Apple docs) and, with the hardened runtime, the `com.apple.security.personal-information.location` entitlement ("enable the App Sandbox or Hardened Runtime capability … then select Location", Apple docs) |
| `CNCopyCurrentNetworkInfo` | — | — | `API_UNAVAILABLE(macos)` (`CaptiveNetwork.h:180-182`): not an option |
| Login item | `SMAppService.mainApp` `register`, `unregister`, `status`, `openSystemSettingsLoginItems` (macOS 13+) | user can turn it off in Login Items | `SMAppService.h`: "Apps that use SMAppService APIs must be code signed"; main app "will be launched on subsequent logins" |
| Launched at login | the open-application Apple Event's `keyAELaunchedAsLogInItem` (`'lgit'`, `AERegistry.h:1052`); console session start (`getutxent`, `who`: "console 22 Eki 18:35") | none | which one works with `SMAppService.mainApp` — TS-3 |
| A normal launch | `NSApplicationLaunchIsDefaultLaunchKey` in the did-finish-launching user info: NO "if the app was launched to open or print a file, to perform a Service, if the app had saved state that will be restored…" (`NSApplication.h:661-664`) | none | the app restores state (`AppDelegate.swift:318-320`) and opens URLs at launch — TS-4 |
| Screen locked | `CGSessionCopyCurrentDictionary` documents `kCGSessionOnConsoleKey` (`CGSession.h:23-46`); the "screen is locked" key isn't documented | — | lock without sleep isn't detected (TS-11) |

**Finding 1: only Wi-Fi names need a permission.** Time, login, launch, screens, displays, Ethernet
and the VPN heuristic read nothing gated. The Wi-Fi name is gated by Location Services on macOS 14
and later (and was redacted on this Mac's macOS 27.0.1 for an unauthorized process): there is no
supported permission-free way to it, and the app doesn't look for one (T-S9).

**Finding 2: the Location permission changes the app's signing.** It needs an entitlements file
(the app runs with the hardened runtime and has none today, `project.yml:69`), `--entitlements`
in `scripts/build-app.sh:191-193` and CI, and the Info.plist string. Agents are re-signed ad hoc
without entitlements (`AgentInstaller.swift:226-235`), which is right: they never read networks.
An ad hoc build gets a
new code identity each build, so TCC forgets its Location answer — a development nuisance only.
That's why Wi-Fi names are their own PR (PR 4) and a decision of their own (§9 Q4).

**Spike register** (each PR records results in `docs/design/triggers-spike.md`):

| # | Question | PR | If it fails |
| --- | --- | --- | --- |
| TS-1 | How late does a one-shot timer fire in this `LSUIElement` app under App Nap, with and without a `ProcessInfo.beginActivity(.userInitiated)` begun 90 s before the due time? | 1 | keep the activity window; budget ≤ 60 s late, else widen it |
| TS-2 | `SMAppService.mainApp.register()` with Developer ID and ad hoc builds; status after the user turns it off; the system notice; survives the updater replacing the app in place and a move | 2 | ad hoc: hide the checkbox with "needs a signed copy"; updater: re-register after relaunch |
| TS-3 | Does `keyAELaunchedAsLogInItem` arrive for `SMAppService.mainApp` and for hand-added Login Items? Is the console session start a usable "login session" key? | 2 | login = launched within 5 minutes of the console session start |
| TS-4 | `NSApplicationLaunchIsDefaultLaunchKey` for Finder, login, link, intent, update relaunch, restored state | 2 | "opens" = no URL and no intent within the 5-second launch settle |
| TS-5 | Display identity across reconnects, ports, docks, sleep; placeholder serials; clamshell; Sidecar and AirPlay displays (counted as external or not) | 3 | name + vendor + model only; virtual displays excluded |
| TS-6 | Do external displays leave and rejoin the screen list on wake? | 3 | longer settle on wake (5 s) |
| TS-7 | `ssid()` and SSID events after authorization on macOS 14, 15, 26, 27; prompt text; Location indicator in the menu bar | 4 | drop Wi-Fi from 0.11.0 (§9 Q4) |
| TS-8 | Primary interface for WireGuard, IKEv2 (built-in), Tailscale, a corporate client; system `utun`s | 4 | VPN events not offered |
| TS-9 | Ethernet through USB, Thunderbolt and dock adapters in `NWPath` | 4 | Ethernet = a wired interface in `availableInterfaces` with status satisfied |
| TS-10 | macOS 26+: does a Shortcuts automation with Start Group open the quit app and run without a dialog (hide-only group)? | 2 (manual) | the README recipe says "keep the app open" |
| TS-11 | Any documented lock signal? | — | none used; screens sleep + session active only |

### 2.4 Evaluation (pure, Core)

`TriggerEvaluator.evaluate`, for each runnable, enabled trigger whose group is in `activeGroups`:

1. **Schedule** (`.clock`, `.launched`, `.screens(asleep: false)`, `.session(active: true)`): the
   latest occurrence ≤ now (`TriggerScheduling.latestOccurrence`). It fires when it's after the
   trigger's `lastHandledOccurrence`, `now - occurrence ≤ 30 min` and the Mac can act (screens
   awake, session active); when it's older, `lastHandledOccurrence` moves to it with outcome
   `.missed(reason)`. Either way an occurrence is handled once.
2. **Login** (`.launched(.login(sessionStart))`): fires when `sessionStart` isn't the
   `lastLoginSession` in the state; the state keeps the new one.
3. **App opens** (`.launched(.normal)`): fires; `.quiet` (update, language) and URL or intent
   launches don't.
4. **Screens** (`.screens`): the matching edge fires (wake → `screensWake`, sleep → `screensSleep`).
5. **Conditions** (`.displays`, `.network`): the trigger's condition is computed from the reading
   (true, false or unknown); with a known previous value and a different known new value, the
   matching edge fires; the state keeps the new known value (`TriggerState.Entry.condition`).
   Unknown readings change nothing.
6. **Gates**, in order: cooldown (60 s since `lastRunAt`), once a day (`lastRunAt` today), the echo
   window (edges only), pause. A gated firing is recorded as skipped with its reason; nothing
   gated is kept for later.
7. **Finish when it ends**: an `.ends` edge of a Start trigger with the option produces a
   `TriggerFiring(isFinishWhenEnded: true, action: .finish)`; the coordinator carries it out only
   when the group is current and `startedBy == trigger.id` (§2.5).

`nextDue` returns the earliest future occurrence of any runnable, enabled schedule; the clock source
arms one timer for it (tolerance 10 s) and re-plans on every rule change, wake, day, clock and time
zone change. There's never more than one timer, and none without schedules.

### 2.5 Coordinator and carrying out

```
 Sources (App)              Core                                                   App
 ┌───────────────┐  signal  ┌──────────────────┐ firings ┌───────────────────────┐ notice ┌─────────────┐
 │ClockSource    │────────▶│ TriggerEvaluator │────────▶│ TriggerCoordinator    │──────▶│NoticePanel  │
 │WorkspaceSource│ (values) │ (pure)           │         │ settle 2 s · reduce   │◀──────│run / notNow │
 │DisplaySource  │          └────────▲─────────┘         │ pause · budget · echo │answer └─────────────┘
 │NetworkSource  │                   │ rules, state      │ one at a time         │
 │WiFiSource     │          ┌────────┴─────────┐         │ writes the state      │──────▶ AutomationHandling
 └───────────────┘          │ TriggerStore      │◀────────┘                       │        (AppDelegate:
                            │ (triggers.json)   │  state  └───────────────────────┘        ContextSwitcher,
                            │ TriggerState      │                                          GroupLauncher,
                            │ (trigger-state)   │                                          popup)
                            └───────────────────┘
```

- **`TriggerController`** (App, main app only; `AppDelegate` creates it after the stores are
  loaded, next to `FocusFilterBridge.coordinator.handler = self`, `AppDelegate.swift:263`) starts
  the sources, feeds signals to the evaluator with the active group ids (`store.groups`), hands
  firings to the coordinator, and begins a `ProcessInfo` activity 90 seconds before `nextDue` so
  App Nap doesn't delay the timer (TS-1). Agents never create it (`CybokronDockGroupsMain.swift:15-19`),
  so an agent can't register a login item or evaluate anything.
- **Launch kind.** The controller waits 5 seconds after `applicationDidFinishLaunching` (the
  launch settle) before sending `.launched`: URLs handled (`AppDelegate.swift:268-270`, `:291-299`)
  or an intent performed in that time make it `.quiet`; so does a **quiet-launch marker**
  (`quietLaunchUntil` in `trigger-state.json`, 2 minutes ahead) written just before the updater's
  and the language restart's relaunch (`AutoUpdater.swift:441-463`, `AppLanguageSupport.swift:62-86`).
  The marker is cleared at the next launch. Login vs normal: TS-3.
- **`TriggerCoordinator`** (Core, `@MainActor`, a `Sleeping` for its waits as
  `FocusRequestCoordinator.swift:102-105` and `Launching/DelayedLaunches.swift:6-19`):
  1. collects firings for 2 s after the last one (settle), then reduces them (§1.8);
  2. drops what pause or the budget stop, recording why;
  3. for each remaining firing, one at a time: looks the group up again (gone or archived →
     skipped, "the group no longer exists"); presents the notice per run mode and waits; on `.run`,
     calls the handler: Start → `startGroup(id, trigger: .automation)`; Finish → only when
     `currentGroupID == id` (and, for a finish-when-ended firing, `currentGroupStartTrigger ==
     .automation` and `startedBy[id] == triggerID`) → `finishGroup(id, trigger: .automation,
     showsPrevious: true)`; Open All → `openAllItems`; Show the Popup → `showPopup`;
  4. records the outcome and `lastRunAt` in the state, starts the echo window, counts the budget.
- **`AutomationHandling`** is implemented by `AppDelegate` next to `FocusRequestHandling`
  (`AppDelegate.swift:700-731`): the same `switcher.start/finish` and `launchAll`, with problems
  shown by `LaunchReportPresenter` as for a Focus (an alert for items that couldn't open is the one
  thing an unattended trigger may show).
- **Notice.** `TriggerNoticePanel` is a borderless non-activating `NSPanel` (as `PopupPanel.swift:10-19`)
  at the top right of the screen with the menu bar, under it; 5-second countdown, or no countdown
  for Ask First (2-minute time-out). Created on first use.
- **Pause and budget** live in `trigger-state.json` (`pausedUntil`, `pauseReason`, the last hour's
  run times), so a restart doesn't lift a pause.

### 2.6 Running while the app isn't: the options

The question is what happens at 9:00 when the user quit Cybokron Dock Groups at 18:00 yesterday.

| | (a) In the app only (+ Open at Login, catch-up, Shortcuts recipe) | (b) `SMAppService` LaunchAgent/daemon + headless runner | (c) Hybrid: LaunchAgent for time, app for the rest |
| --- | --- | --- | --- |
| Works while quit | no; at login yes (Open at Login); missed times ≤ 30 min run at launch; macOS 26+: Shortcuts automations | time and, with a persistent runner, everything | time only |
| What runs | the app (already a menu bar app) | a second process, always on for display/network events (`KeepAlive`), or woken every N minutes | a helper woken by launchd |
| User times in launchd | — | the agent's plist is **inside the signed bundle** (`SMAppService.h`: "plistName must correspond to a plist in the calling app's Contents/Library/LaunchAgents"): static, so no `StartCalendarInterval` for user times; `StartInterval` polling or a resident process | same limit; the alternative, a plist written to `~/Library/LaunchAgents`, is the legacy path malware uses and Background Items flags |
| Signing, notarization | unchanged (Wi-Fi: one entitlement, PR 4) | the helper or a runner mode of the same executable inside the bundle, signed and notarized with it; `build-app.sh`, `project.yml` and CI change | same as (b) |
| Updates | unchanged | "If an app updates either the plist or the executable … the SMAppService must be re-registered or it may not launch. It is recommended to also call unregister before re-registering" (`SMAppService.h`): every update by `UpdateInstaller` swaps the executable | same as (b) |
| User approval | Open at Login: a login item the user sees and can turn off | Background Items: "Allow in the Background", `.requiresApproval` when turned off | same as (b) |
| Dock and UI | unchanged | the runner must stay invisible (no Dock icon, no menu bar item) and must never "open" a running app: reopening shows a popup (`AppDelegate.swift:276-289`) | same as (b) |
| Acting twice | impossible: one process (`SecondCopyHandoff`) | runner and app both evaluating → a lock or "the runner only wakes the app"; the session (`ContextSession`) lives in the app, so the runner can't Start correctly itself | the runner must only open the app with a payload-free "check now" signal |
| Agents | unaffected | agents copy the executable (`AgentBundleLayout`): must never register anything | same |
| Ad hoc builds | work (Open at Login: TS-2) | `SMAppService` "must be code signed": TS-2 for ad hoc | same |
| Battery | one timer, notifications | a resident process or periodic wake-ups | periodic wake-ups |
| Effort | 4–5 PRs (§8) | +2–3 PRs, a new target, a new release pipeline step, new manual gates on every update | +2 PRs |
| Security surface | unchanged | a background executable launched by launchd, a new IPC or launch path | same, smaller |

**Decision (2026-10-25): (a)**, with Open at Login, the 30-minute catch-up and the Shortcuts recipe (§9 Q1).

- The app is a menu bar utility meant to keep running; Open at Login covers the common gap (after a
  restart), catch-up covers "the lid was closed at 9:00", and quitting the app is a clear way to stop
  everything automatic — a background helper would make Quit mean "quit, except at 9:00".
- (b) costs a second, permanent process for display and network events and re-registration on every
  update; its time-only variant (c) can't even hold the user's times in a supported plist.
- macOS 26 already runs Shortcuts automations for Time of Day, Wi-Fi and Display with the app's
  existing Start/Launch/Show Group intents, with the permissions held by Shortcuts — the "while
  quit" case for users who want it, at no cost to the app (TS-10 checks that it opens the quit
  app).
- (a) changes nothing about signing, updates, agents or the Dock, and keeps every action inside the
  process that owns the session and the stores.

(c) is not in 0.11.0. It stays the fallback if users of macOS 14 and 15 later ask for quit-app time triggers: then a runner mode
of the same executable, registered as an `SMAppService` agent with `StartInterval` 300, that does
nothing but open the app with a payload-free "check triggers" request when a schedule is within the
catch-up window and the app isn't running; the app evaluates its own rules (T-S6). Not in 0.11.0.

### 2.7 Data: files, schema, lenient rules

```jsonc
// triggers.json — the rules (user intent): in backups, kept across downgrades
{ "formatVersion": 1, "triggers": [
  { "id": "…", "groupID": "…", "enabled": true,
    "event": { "kind": "schedule", "minute": 540, "weekdays": [2, 3, 4, 5, 6] },
    "action": "start", "runMode": "notice" },
  { "id": "…", "groupID": "…", "enabled": true,
    "event": { "kind": "condition", "condition": { "kind": "display",
               "display": { "vendor": 23139, "model": 28983, "name": "VX2776-4K-mhd", "builtIn": false } },
               "edge": "starts" },
    "action": "start", "runMode": "notice", "finishesWhenEventEnds": true },
  { "id": "…", "groupID": "…", "enabled": false,
    "event": { "kind": "condition", "condition": { "kind": "wifi", "name": "Office" }, "edge": "ends" },
    "action": "finish", "runMode": "askFirst", "oncePerDay": true } ] }

// trigger-state.json — runtime state (a convenience, like update-state.json): not in backups
{ "formatVersion": 1, "pausedUntil": 1798790400, "pauseReason": "user",
  "lastLoginSession": 1798700100, "quietLaunchUntil": null,
  "recentRuns": [1798700500, …],                                  // the last hour, for the budget
  "triggers": { "<id>": { "lastRunAt": 1798700500, "lastOutcome": "started",
                          "lastHandledOccurrence": 1798700400, "condition": true } } }
```

| Saved (`triggers.json`) | Read as |
| --- | --- |
| unknown top-level or per-trigger keys | ignored |
| `event.kind` unknown (a newer version's) | `.unsupported`: kept and written back unchanged, never runs, shown as "Made by a newer version" |
| `minute` outside 0…1439, `weekdays` empty or outside 1…7 | the trigger isn't runnable: kept, off, shown as "Can't run: fix or remove it" |
| an action the event doesn't allow (§1.6), `finishesWhenEventEnds` where it doesn't apply | not runnable (action) / ignored (option) |
| `enabled` missing or not a boolean | `false` (fail closed) |
| `runMode` unknown | `notice` |
| a display name over 100 characters, a Wi-Fi name outside 1–32 bytes or with control characters | not runnable |
| a `groupID` of no active group | inert; deleted when the group is gone from both lists and the groups loaded without an issue (§1.12) |
| more than 10 for a group or 100 in all | the first ones in file order are kept |
| a file that can't be read | moved aside (`JSONFileSupport.moveAside`, as every store), no triggers, the group window shows the issue |

`trigger-state.json` is read leniently: a missing, unreadable or newer file is a fresh state (with
"past occurrences of today handled", §1.10); entries of deleted triggers are dropped on save.

Neither file is written while nothing changed; `TriggerStore` saves with the stores' 250 ms debounce
and flushes in `applicationWillTerminate` (`AppDelegate.swift:305-316`); state writes coalesce to at
most one per second.

**Why not `groups.json` or `preferences.json`.** Per-group `triggers` in `groups.json` would follow
the group naturally, but 0.10.0 would drop them on its first save (as 0.8.0 drops shortcuts,
`DowngradeProtection.swift:17-21`), agents would need another normalization, and the runtime state
would churn the groups file. `preferences.json` is app-wide settings, mirrored into every agent's
snapshot. The template precedent fits: a file older versions never open.

### 2.8 Compatibility and downgrades

| Data | 0.10.0 and earlier | Result there |
| --- | --- | --- |
| `groups.json`, `preferences.json`, agent configurations | unchanged by triggers | byte-identical round trip (fixture test, §6) |
| `triggers.json`, `trigger-state.json` | never opened | kept; triggers run again after updating |
| a group deleted there | — | its triggers are deleted at the next 0.11.0 launch |
| Open at Login | registered with macOS, not in the app's files | 0.10.0 keeps opening at login with no setting for it; System Settings turns it off |
| a 0.11.0 backup imported there | `triggers` key ignored (as `templates` by 0.8.0) | no triggers there; the file still has them |

`ReleaseHistory.firstTriggersVersion = 0.11.0`; `DowngradeProtection.warnsAboutTriggers(installing:
over:triggerCount:opensAtLogin:)` adds the §1.13 lines to the existing question. No new copies:
nothing 0.10.0 writes can lose trigger data.

### 2.9 Backups

- `BackupDocument` gains `triggers: [GroupTrigger]?`, written only when there are some (as
  `templates`, `SettingsBackup.swift:382`); `schemaVersion` stays 1.
- Reading a backup: every trigger comes in with `isEnabled = false` (T-S4), unsupported kinds kept,
  limits applied, triggers of groups not in the backup dropped.
- **Replace All** (`SettingsBackup+Stores.swift:25-58`): the trigger store is replaced when the
  backup has triggers, in the same all-or-none rollback as the templates (a `triggers.pre-import-<ts>.json`
  copy first); otherwise current triggers of groups that survive stay.
- **Merge** (`:60-77`): the backup's triggers of groups the merge added are appended, off.
- `SettingsRestoreSummary` gains `triggerCount` and its note (§1.14).

### 2.10 Agents

Nothing changes: `AgentConfiguration` (`AgentConfiguration.swift:17-34`) is built from `DockGroup`
and `PopupPreferences`, which gain no field. A test proves an agent configuration is byte-identical
with and without triggers. Agents don't create `TriggerController`, don't link the trigger UI paths,
and never call `SMAppService` (the bundle identifier gate in `CybokronDockGroupsMain.swift:10-19`).

### 2.11 Localization plan

As the earlier specs: keys arrive with their code, each PR lists its prefixes in
`awaitingTranslation`, `docs/l10n-keys.md` gets sections marked "English only for now", and PR 5
translates them into the 25 languages.

| Prefix | Where | About |
| --- | --- | --- |
| `core.trigger.` | summaries, last-run lines, reasons, limits, unsupported/unrunnable, budget | 40 |
| `triggers.editor.` | sheet: event, action, run mode, options, time, days, displays, Wi-Fi | 35 |
| `triggers.notice.` | notice titles and buttons | 10 |
| `groupWindow.triggers.`, `settings.triggers.` | section, pane, Open at Login, Location, Shortcuts hint | 20 |
| `menuBar.triggers.` | pause submenu, resume, paused line, quit tooltip | 7 |
| `core.backup.triggers.`, `updates.otherVersions.triggers.` | import note, downgrade lines | 5 |

About **117 keys** (827 → about 944). Times use `DateFormatter` templates (`"jmm"`), weekday names
`Calendar.shortWeekdaySymbols` in `firstWeekday` order; nothing hand-formats a time. The
`NSLocationUsageDescription` string stays English in `Resources/Info.plist`, as the folder usage
strings there are today (the app has no `InfoPlist.strings`); translating Info.plist strings is a
separate change for all of them.

---

## 3. UX sketches

### 3.1 Group window: Triggers section (after Keyboard Shortcut)

```
┌ Triggers ─────────────────────────────────────────────────────────────────┐
│ [✓] ⏰ At 9:00 on weekdays: start                                    [Edit…]│
│        Last ran today at 9:00: started “Work”.                             │
│ [✓] 🖥 When “VX2776-4K-mhd” connects: start, finish when it ends     [Edit…]│
│        Not run yet.                                                        │
│ [ ] 📶 When the Mac leaves “Office”: finish                          [Edit…]│
│        Waiting for Location access.                       [Allow…]         │
│                                                                            │
│ [Add Trigger…]                                              [−]            │
│ Triggers run while Cybokron Dock Groups is open. They never quit apps.     │
│ Open at Login is off.  [Turn On…]                                          │
└────────────────────────────────────────────────────────────────────────────┘
```

Empty: "No triggers. A trigger starts, opens or shows this group when something happens." with
Add Trigger…. Rows sort by event kind, then time.

### 3.2 New Trigger sheet

```
┌ New Trigger for “Work” ───────────────────────────────────────────────┐
│ When   [At a Time                                  ▾]                 │
│        Time [ 9:00 ]                                                  │
│        Days (M)(T)(W)(T)(F)( S )( S )    [Weekdays] [Weekends] [Every Day]
│                                                                       │
│ Do     [Start                                      ▾]                 │
│        Starting hides the apps of the group started before, as        │
│        “Work” is set to. A trigger never quits apps.                  │
│ How    [Show a 5-Second Notice                     ▾]                 │
│        [ ] At most once a day                                         │
│                                                                       │
│ If the Mac is asleep at 9:00, the trigger runs when it wakes, up to   │
│ 30 minutes late.                                                      │
│                                              [Cancel] [Add Trigger]   │
└───────────────────────────────────────────────────────────────────────┘
```

When = a display event:

```
│ When   [When a Display Connects                    ▾]                 │
│        Display [Any External Display ▾]  (Any External Display ·      │
│                 VX2776-4K-mhd · LG UltraFine (not connected))          │
│ Do     [Start ▾]   [✓] Finish when it ends                            │
```

When = These Displays Are Connected:

```
│        Displays  • Built-in Retina Display  • VX2776-4K-mhd           │
│                  [Use Current Displays]                               │
```

When = a Wi-Fi network, without permission:

```
│ When   [When the Mac Joins a Wi-Fi Network         ▾]                 │
│        Network Name [ Office                       ] [Use Current Network] (disabled)
│        ⓘ macOS shows Wi-Fi network names only to apps allowed to use  │
│          Location Services. Your location is never read.   [Allow…]   │
```

**Allow…** requests Location authorization once (macOS shows its prompt; TS-7 picks the call);
after a denial it becomes **Open Privacy Settings…**. Add Trigger stays enabled: the trigger is
saved and shows "Waiting for Location access" until allowed.

Invalid combinations aren't offered: the Do pop-up lists only the actions §1.6 allows for the
chosen event; How shows only Run Right Away for Show the Popup.

### 3.3 Settings → Triggers

```
┌ Triggers ──────────────────────────────────────────────────────────────────┐
│ [✓] Open at Login                                                          │
│     Opens Cybokron Dock Groups when you log in, so At Login and other     │
│     triggers can run.                                                      │
│ Status: Running · Paused until tomorrow 0:00 [Resume]                      │
│ Location Access: Not determined (only Wi-Fi triggers need it)              │
├────────────────────────────────────────────────────────────────────────────┤
│ Group      Trigger                                   Last ran              │
│ 💼 Work    At 9:00 on weekdays: start                today 9:00 ✓          │
│ 💼 Work    When “Office” is left: finish             —  (off)              │
│ 🎨 Design  When “VX2776-4K-mhd” connects: show       yesterday 14:02 ✓      │
│                                              [Show in Group Window…]       │
├────────────────────────────────────────────────────────────────────────────┤
│ Triggers run while Cybokron Dock Groups is open. When it's quit, the       │
│ Shortcuts app's automations can still start a group (macOS 26 and later):  │
│ Shortcuts → Automation → Time of Day → Start Group.                        │
└────────────────────────────────────────────────────────────────────────────┘
```

The list is read-only but its checkboxes turn triggers on and off (as G+I's overview with
Change…). The pane sits after Switching in `SettingsPane` (icon `clock.arrow.2.circlepath`).

### 3.4 Menu bar menu and notice

```
Menu bar menu (when any trigger exists):     Notice (top right, under the menu bar):
  Groups …  Most Used …                       ┌───────────────────────────────────────┐
  ──────────────                              │ ⏰ Starting “Work”                 5 │
  New Group from Open Apps…                   │    At 9:00 on weekdays             │
  Pause Triggers            ▸ For 1 Hour      │            [Not Now]  [Start Now]  │
                              Until Tomorrow  └───────────────────────────────────────┘
                              Until I Resume Them
  Manage Groups…   ⌘G                         Ask First:  “Start “Work”?”  [Not Now] [Start]
  Settings…        ⌘,
  …                                           Paused:  "Resume Triggers"  + "Triggers paused until 0:00"
```

### 3.5 Keyboard and VoiceOver

- Sheet: Return adds, Escape cancels; the day toggles are buttons with "Monday, on" labels.
- Triggers rows are one element each: "At 9:00 on weekdays: start, on. Last ran today at 9:00."
- The notice is announced (`AccessibilityNotification.Announcement`); its buttons have labels; it
  stays at least 5 seconds even under Reduce Motion (no animation).

---

## 4. Security and privacy

### 4.1 Threat model

`SECURITY.md` ("Scope") names another process, a web page or link, a crafted `groups.json` or
`.dockgroups` backup, or a tampered update making the app launch unintended apps or run code.
Triggers add the first way for **data alone** to make the app act without a user action at that
moment: a rule says "at 9:00, Open All". New inputs: `triggers.json`, `trigger-state.json`, the
`triggers` key of backups, and system signals (time, displays, networks) that anyone near the Mac
can partly influence (plugging a monitor, naming a hotspot "Office").

What an attacker could want: launch a group's apps unattended, hide the user's apps, or loop the
app into a storm. What stays out of reach by design: choosing *what* opens (only a group's items,
through the existing gates), quitting anything, running code.

### 4.2 Invariants

- **T-S1 Four actions, existing paths.** A trigger acts only through `ContextSwitcher.start/finish`
  (trigger `.automation`), `GroupLauncher.openAll` and `PopupPanelController.show`. Items open only
  as they open from a click: app bundles only (`GroupLauncher`), openers checked each time
  (`ItemOpenerPolicy`), launch delays as set.
- **T-S2 No payload.** A trigger holds a group identifier, an event from a closed set (times,
  weekday numbers, display identities, a network name) and an action from a closed enum. No app,
  path, URL, script, shell text or opener; the coding has no field that could hold one.
- **T-S3 Never quits.** `TransitionTrigger.automation.mayQuit == false`: quitting settings act as
  hiding (`GroupSwitching.withoutQuitting`); no Close All, no force quit, no question.
- **T-S4 Turned on here.** Triggers from a backup come in off; turning one on is a click in this
  app. `enabled` missing or malformed reads as off.
- **T-S5 Fail closed.** A trigger acts only on a group in `store.groups` (not archived, not
  deleted, not unreadable); unknown or unrunnable events never run; unknown readings make no edge.
- **T-S6 No new command surface.** No link, intent or launch argument tells the app to run a
  trigger or a group automatically. (If option (c) ever comes, its signal carries nothing: the app
  re-evaluates its own rules, so a forged signal can at most make a due trigger run on time.)
- **T-S7 Bounded.** 100 triggers; 10 per group; 60 s cooldown; once per occurrence; 15 s echo
  window; 12 actions per hour, then a one-hour pause; one action at a time; one notice at a time;
  one timer; state writes at most once per second.
- **T-S8 Cancellable.** Every Open All, Start and Finish shows a notice with Not Now by default;
  Pause Triggers stops all; turning a trigger off stops it; quitting the app stops everything.
- **T-S9 No way around privacy gates.** Wi-Fi names come only from CoreWLAN with Location
  authorization. The app never infers a network from the router's address or hardware address, ARP
  or neighbor tables, scan results, IP ranges or anything else macOS doesn't gate, and never
  starts location updates (`startUpdatingLocation` is never called).
- **T-S10 Agents unchanged.** Agents read only `group-config.json`; they can't register login
  items or evaluate triggers.

### 4.3 Crafted files and local attackers

- **A crafted backup** can bring at most triggers that are off (T-S4) on groups that came with it;
  the import summary counts them.
- **A crafted `triggers.json`** written by another process running as the user can turn triggers
  on. Such a process can already write `~/Library/LaunchAgents` and run code at login, so the
  delta is small: it can make the app Open All or Start a group at a time — the user's own groups,
  through the item gates, with the notice showing (unless it also set Run Right Away). Signing the
  rules with a Keychain-held key was considered and rejected: the attacker runs as the user, ad hoc
  builds would re-prompt for Keychain access on every build, and the gain doesn't justify it.
  SECURITY.md's scope gains one sentence (PR 2): "Triggers act only while the app runs, only on
  your groups' items through the same checks, never quit apps, and triggers from a backup come in
  turned off."
- **A crafted `trigger-state.json`** can pause triggers or mark occurrences handled (so they skip):
  it can suppress triggers but not cause runs. Which trigger started the current group is kept in
  the coordinator's memory, like the session itself, never in the file, so "Finish when it ends"
  can't be pointed at a group by editing it. A forged condition value can at most fake one edge
  of a trigger the user turned on. `pausedUntil` far in the future is shown as "Paused until I
  resume them".
- **Look-alike signals.** A hotspot named "Office" or a monitor reporting another's identifiers can
  set off the matching trigger: the action is the user's own (notice by default, never quits). The
  Wi-Fi editor's help says so: "Any network with this name counts."

### 4.4 Loops

A trigger's own action can't cause a time, login, launch or screens event. Display and network
edges *can* follow from opening apps (a VPN client, DisplayLink, AirPlay) — the echo window takes
them into the state without running anything; per-trigger cooldowns, `ContextSession.repeatInterval`
and the hourly budget stop any remaining ping-pong between two groups. Focus calls aren't trigger
events: a Focus filter and a trigger can both start groups, each once, deduplicated within 3 s.

### 4.5 Privacy

Nothing leaves the Mac. Network names and display names are stored only in `triggers.json` and
backups (the user's own data, like item paths). Logs never contain them (`privacy: .private`);
they name triggers and groups by identifier and events by kind ("trigger <id> (schedule) started
group <id>"). Diagnostics: counts by kind, how many on, pause state, Open at Login status, Location
authorization status — no names, no times of use. The app asks for Location only to read the
network name, says so in the prompt string, and never reads coordinates.

---

## 5. Performance and battery

| Part | Cost | Budget |
| --- | --- | --- |
| Clock | one one-shot timer to the next due time, tolerance 10 s; none without schedules; a `ProcessInfo` activity only 90 s before due (TS-1) | no polling; ≤ 60 s late under App Nap |
| Workspace | five `NSWorkspace` observers (sleep/wake, screens, session) | notifications only |
| Displays | `didChangeScreenParameters` + one read of `NSScreen.screens` and four CoreGraphics calls per display, 2 s after the last change | < 1 ms per read |
| Network | one `NWPathMonitor` on a utility queue, started only while a network trigger exists; one `SCDynamicStore` read per settled change | event-driven |
| Wi-Fi | `CWWiFiClient` SSID events, started only while a Wi-Fi trigger exists **and** Location is authorized | no scans (`scanForNetworks` is never called) |
| Evaluation | O(rules) per signal, ≤ 100 rules, dictionary lookups | < 1 ms |
| Budget | the last hour's run times in `trigger-state.json`, pruned on each run | ≤ 12 entries; a pause at the 13th |
| Files | debounced saves; state ≤ 1 write/s, only on change | — |
| Notice | one panel, created on first use, released after | — |
| Idle | with no triggers: no sources started, no timer, no files written | zero |

Waking the Mac is never requested: no `IOPMSchedulePowerEvent`, no power assertions. A time that
falls while the Mac sleeps waits for the next wake (§1.10).

---

## 6. Test plan

`Tests/DockGroupsCoreTests`, swift-testing; no real timers, NSWorkspace, CoreGraphics, Network,
CoreWLAN, CoreLocation or ServiceManagement. Fakes: the existing `FakeSleeper`
(`Tests/DockGroupsCoreTests/LaunchOptionsFakes.swift:84`) and, in a new `TriggerFakes.swift`,
`FakeAutomationHandler` (records calls, scripted current group), `FakeNoticePresenter` (scripted
answers), signal builders, a fixed `Calendar` and time zones.

- **`GroupTriggerCodingTests`**: round trip of every event, action and option; lenient table §2.7
  row by row (unknown kind kept and re-encoded byte for byte; invalid minute/weekdays → not
  runnable; `enabled` malformed → off; unknown `runMode` → notice); limits 10/100 keep file order;
  display name and Wi-Fi name bounds (32 bytes in UTF-8, multibyte names, control characters).
- **`TriggerRulesTests`**: the §1.6 matrix exhaustively (event × action → runnable or not);
  `finishesWhenEventEnds` only for Start on `.starts`.
- **`TriggerSchedulingTests`**: next and latest occurrences across weekdays, midnight, DST forward
  (02:30 → 03:00) and back (01:30 once) in Europe/Istanbul (no DST), Europe/Berlin, America/New_York,
  Australia/Lord_Howe (30-minute DST); weekend presets for `en_US`, `ar_SA`, `fa_IR` calendars
  produce explicit sets; a clock change backwards doesn't run an occurrence twice.
- **`TriggerEvaluatorTests`**: schedule fires once per occurrence; catch-up ≤ 30 min runs, > 30
  min is `.missed` with its reason; screens asleep / session inactive defer within the window;
  first run without state handles today's past occurrences; login once per session; app opens:
  normal fires, quiet and URL launches don't; condition edges from known → known only (unknown →
  anything makes none, both directions); persisted condition state across a simulated relaunch;
  a trigger added while the condition is true doesn't fire; display matching with serials,
  placeholder serials, identical twins, built-in ignored for connect/disconnect; arrangement
  multiset equality; cooldown 60 s; once a day across midnight and a time zone change; echo window
  for edges only; archived/deleted group ids inert; disabled and unrunnable never fire.
- **`TriggerReducerTests`**: §1.8 precedence: finishes first, one Start (latest, then list order),
  Open All deduped and dropped for the started group, Show the Popup at most one; skipped reasons
  recorded.
- **`TriggerCoordinatorTests`** (with `FakeSleeper`, `FakeAutomationHandler`, `FakeNoticePresenter`):
  2 s settle; one at a time; notice → run / Not Now / time-out / replaced; Run Right Away skips the
  notice; Finish only when current; finish-when-ended only when current, `.automation` and started
  by that trigger (a user Start in between → nothing); pause (hour, tomorrow, indefinitely) skips
  and records; budget: 12 run, the 13th pauses for an hour and is recorded; state written once per
  outcome; a group deleted during the notice → skipped; a handler set late keeps the firings (as
  the Focus coordinator's `waiting`).
- **`TransitionPlannerTests`** (additions, `Tests/DockGroupsCoreTests/TransitionPlannerTests.swift`):
  `.automation.mayQuit == false`, `asksBeforeQuitting == false`; a Start plan with "quit the
  previous group" and a Finish plan with "quit its apps" hide instead; `ContextSwitcher` never calls
  the question for it.
- **`TriggerStoreTests`**: add/update/delete/enable; limits; pruning only when the group store has
  no issue and the group is in neither list; archived groups' triggers kept; debounce and flush;
  unreadable file moved aside.
- **`TriggerStateCodingTests`**: lenient, fresh on missing/unreadable/newer; quiet-launch marker
  set and cleared; deleted triggers' entries dropped.
- **`SettingsBackupTriggerTests`**: export writes `triggers` only when some exist (a backup without
  triggers byte-identical to 0.10.0's); import turns all off, drops triggers of absent groups,
  keeps unsupported kinds; Replace All with and without backup triggers; Merge adds only for added
  groups; all-or-none rollback with templates; summary notes.
- **`Version0100Fixtures`** (generated by building `4aaddc8`'s Core): `groups.json`,
  `preferences.json` (with and without protected apps and capture settings), an agent
  configuration and a backup re-encode byte for byte with 0.11.0 and with triggers present.
- **`AgentModelTests`** (addition): agent configuration identical with and without triggers.
- **Downgrade protection** (additions next to the existing ones in
  `Tests/DockGroupsCoreTests/UpdateInstallerTests.swift`): warning lines only with triggers on /
  Open at Login on; no extra copies.
- **`DiagnosticsReportTests`**, **`LocalizationTests`** (prefixes).
- **Manual (recorded in PRs 2–4)**, on macOS 14, 15 and 26 (this Mac runs 27.0.1): a 9:00 trigger
  with the Mac awake, asleep through 9:00 and woken at 9:20 and at 9:45; lid closed; the app quit and
  opened at 9:10; Open at Login on/off, approval revoked in System Settings, after an update, after
  moving the app, ad hoc build (TS-2); At Login vs When Opens on a restart (TS-3, TS-4); a link
  launching the quit app (no "opens" trigger); an external monitor plugged and unplugged, through a
  dock, across sleep, two identical monitors, clamshell, Sidecar (TS-5, TS-6); Ethernet adapter,
  dock (TS-9); VPN clients (TS-8); Wi-Fi with Location not determined / allowed / denied / revoked,
  the prompt text, the Location indicator (TS-7); notice over a full-screen app and with VoiceOver;
  Pause and Resume; the budget; a Shortcuts automation starting a group while the app is quit (TS-10,
  macOS 26+); Focus and a trigger starting the same group; backup round trip; 0.11.0 → 0.10.0 →
  0.11.0 with triggers.

---

## 7. Risks and unknowns

| # | Risk or unknown | Effect | Mitigation |
| --- | --- | --- | --- |
| R1 | App Nap delays the timer in a windowless menu bar app | a 9:00 trigger at 9:02 | activity window 90 s before due; TS-1 measures |
| R2 | Users expect triggers while the app is quit | "it didn't work" | TR-5 texts everywhere; Open at Login; catch-up; Shortcuts recipe; Quit tooltip |
| R3 | Apps hiding on their own surprise users | lost trust | notice by default, never quit, Not Now, Pause, last-run lines, Finish only for the current group |
| R4 | Location prompt for Wi-Fi breaks the "no prompt" story; macOS changes SSID access again | fewer users allow; Wi-Fi triggers dead | opt-in on demand; every other trigger works (§9 Q4); unknown makes no edge |
| R5 | Display identity collisions (placeholder serials, twins) and storms on wake | wrong or repeated edges | vendor+model+name, multiset matching, 2 s settle, state across sleep, cooldown; TS-5/6 |
| R6 | Network flapping (roaming, DHCP, captive portals) | repeated runs | 5 s settle, unknown ≠ left, cooldown, once a day option |
| R7 | VPN detection is a heuristic | false edges | offered only if TS-8 passes; otherwise out of 0.11.0 |
| R8 | `SMAppService.mainApp` on ad hoc builds or after an update | Open at Login silently off | status shown live; re-register after relaunch if needed; TS-2 |
| R9 | Update or language relaunch counted as "opens" | groups start after an update | quiet-launch marker before both relaunch paths |
| R10 | A Shortcuts automation and a trigger both act | double work | 3 s repeat rule for Start; reducer; README says to pick one |
| R11 | Fast user switching: two users run the app | one user's trigger acts in the background session | session inactive → defer within the window |
| R12 | Time zone travel and clock changes | missed or doubled times | wall-clock schedules, re-plan on change, handled-occurrence state, 30-min window |
| R13 | A forged `triggers.json` by a local process | unattended Open All/Start of the user's groups | out of the delta that matters (§4.3); notice by default; no payload; SECURITY.md sentence |
| R14 | Two groups' triggers ping-pong through VPN/display apps | a storm | echo window, cooldowns, budget pause |
| R15 | Newer versions add event kinds | 0.11.0 drops them | unsupported kinds kept verbatim and inert |
| R16 | Countdown notice over a presentation or a screen share | distraction | small panel, top right; Run Right Away and Ask First per trigger; Pause |
| R17 | `triggers.json` unreadable | triggers lost | moved aside, issue shown, never pruned from a failed read |

---

## 8. PR plan

Five PRs, Core first: PR 1 adds `TransitionTrigger.automation` to the switching code every Start
and Finish runs through, so it lands alone and fully tested before anything can fire. Each keeps
`scripts/test.sh` green, runs `xcodegen generate` when files are added, and adds its keys and
`awaitingTranslation` prefixes (`AGENTS.md`).

| PR | Title (Conventional Commits) | Scope | Acceptance criteria |
| --- | --- | --- | --- |
| **1** | `feat(core): plan automatic group triggers` | Spike first (TS-1; results in `docs/design/triggers-spike.md`). `GroupTrigger` and its event, condition, action, run mode types with lenient coding and unsupported kinds; `DisplayIdentity`, `WiFiNetworkName`; `TriggerSignal`, `NetworkReading`; `TriggerScheduling`; `TriggerEvaluator`; `TriggerReducer`; `TriggerBudget`; `TriggerCoordinator` with `AutomationHandling` and `TriggerNoticePresenting`; `TriggerState` + `trigger-state.json`; `TriggersDocument` + `triggers.json`; `TriggerStore`; `TransitionTrigger.automation`; backup `triggers` (imported off) and summary; `ReleaseHistory.firstTriggersVersion` and `DowngradeProtection` lines; diagnostics; `Version0100Fixtures`. Keys: `core.trigger.`, `core.backup.triggers.`. | Existing tests pass unchanged; §6 Core suites pass; 0.10.0 fixtures byte-identical; agent configuration unchanged; no UI, nothing runs. |
| **2** | `feat: run time, login and launch triggers while the app runs` | Spikes TS-2, TS-3, TS-4, TS-10. `TriggerController`, `ClockSource`, `WorkspaceSource` (sleep/wake, screens, session), launch kind and quiet-launch marker in `AutoUpdater` and `AppLanguageSupport`; `TriggerNoticePanel`; `AppDelegate` `AutomationHandling`; `LoginItem` (Open at Login); group window Triggers section, editor sheet (time, login, opens, screens), archived note; Settings → Triggers pane; menu bar Pause/Resume, Quit tooltip; README (features, Shortcuts recipe), CHANGELOG, SECURITY.md scope sentence. Keys: `triggers.editor.`, `triggers.notice.`, `groupWindow.triggers.`, `settings.triggers.`, `menuBar.triggers.`, `updates.otherVersions.triggers.`. | Manual list (§6) for time, login, launch, screens, Open at Login, notice, pause, budget; nothing quits; no prompt of any kind; archived groups' triggers never run. **Must not be released without PR 5.** |
| **3** | `feat: run display triggers` | Spikes TS-5, TS-6. `DisplaySource` (settled set, identity), editor for display, any external, These Displays (Use Current Displays), Finish when it ends; README. Keys: more `triggers.editor.`, `core.trigger.`. | Manual display list (§6); no prompt; edges only on real changes across sleep. |
| **4** | `feat: run network triggers` | Spikes TS-7, TS-8, TS-9. `NetworkSource` (`NWPathMonitor`, `SCDynamicStore`), Ethernet events, VPN events only if TS-8 passes; `WiFiSource` and `LocationAccess`; `Resources/CybokronDockGroups.entitlements` (Location), `project.yml` `CODE_SIGN_ENTITLEMENTS`, `build-app.sh` and CI `--entitlements`, `NSLocationUsageDescription`; editor for networks, Allow…/Open Privacy Settings…; Location status in Settings; README, SECURITY.md (Location sentence). Keys: more `triggers.editor.`, `settings.triggers.`. | Notarized CI build passes `syspolicy_check` with the entitlement; Location asked only from Allow…; Wi-Fi triggers wait without it and never fire "leaves" on lost access; Ethernet/VPN need no permission. If TS-7 fails, the Wi-Fi half moves to a later release and this PR ships Ethernet (and VPN) only. |
| **5** | `feat: translate trigger keys to all languages` | The new prefixes in the 25 translations (one pass per language, reviewed); `awaitingTranslation` back to `[]`; `docs/l10n-keys.md`. | `LocalizationTests` green, no awaiting prefixes. |

Release order: PR 1 can merge any time (nothing visible, nothing new written until a trigger
exists). PRs 2–5 ship **together** as 0.11.0. The version bump (`build: version 0.11.0`, build
1100) isn't part of this plan: it follows when 0.11.0 is cut, then the `v0.11.0` tag → CI's
notarized universal DMG as a **draft** → the `release` environment approval → the user's explicit
approval to publish. Manual gates to record before tagging: the spike register (§2.3), the §6
manual list, and the 0.11.0 → 0.10.0 → 0.11.0 round trip.

---

## 9. DECISIONS

Decided by the user on 2026-10-25, each as the recommendation in the earlier draft. Each is
written into the sections above; PR 1 doesn't depend on them except where noted.

1. **Running while the app is quit.** **Decision (2026-10-25):** option (a): triggers run only
   while the app runs, with Open at Login, a 30-minute catch-up and the macOS 26+ Shortcuts recipe;
   no background helper in 0.11.0. A helper would make Quit mean "quit, except at 9:00" (§2.6).
   (User-decided.)
2. **Default before running.** **Decision (2026-10-25):** Open All, Start and Finish show a 5-second
   notice with Not Now by default (Ask First and Run Right Away per trigger); Show the Popup runs
   right away. That keeps "at 9:00" meaning 9:00 and still gives a way out. (User-decided.)
3. **Catch-up window.** **Decision (2026-10-25):** a missed time runs up to 30 minutes late, fixed,
   with no per-trigger setting; PR 1 keeps it a constant. One rule is easier to explain. (User-decided.)
4. **Wi-Fi names and the Location permission.** **Decision (2026-10-25):** Wi-Fi triggers ship in
   0.11.0 (PR 4), with Location requested on demand only when the user adds a Wi-Fi trigger; Ethernet
   and VPN need no permission. Opt-in keeps "no prompt" for every other trigger. If TS-7 shows the
   name stays redacted after authorization on a supported macOS, Wi-Fi moves out as §8 PR 4 says.
   (User-decided.)
5. **Finish as an automatic action.** **Decision (2026-10-25):** automatic Finish is allowed on time,
   screens sleep and condition edges, only for the current group and only by hiding; "Finish when it
   ends" is also allowed for Start triggers (§1.6). "At 18:00, finish Work" is a main use, and hiding
   is reversible. (User-decided.)
6. **Where Open at Login lives.** **Decision (2026-10-25):** Settings → Triggers, linked from the group
   window's Triggers section; it is never turned on by itself. Triggers are the reason for it.
   (User-decided.)
7. **"When an app opens / quits" triggers.** **Decision (2026-10-25):** deferred to 0.12.0, not PR 3b
   in 0.11.0, after the four event families have been used in practice. They are loop-prone with Open
   All. (User-decided.)
8. **Backups and the budget.** **Decision (2026-10-25):** triggers from a backup come in turned off
   (T-S4), and the budget is 12 automatic actions per hour; the 13th pauses all triggers for an hour
   and is recorded. A backup is the file a user can be handed (SECURITY.md), and 12 an hour is far
   above real use. (User-decided.)
