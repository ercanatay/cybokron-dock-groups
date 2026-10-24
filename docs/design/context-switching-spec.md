# Design spec: context switching — Start and Finish, Focus, and item launch options

- **Status:** draft; decisions recorded 2026-10-24 (see DECISIONS). Design only: no code.
- **Baseline:** `main` at `b32f6af` (version 0.7.0, `project.yml` `MARKETING_VERSION: "0.7.0"`), 725
  tests in 106 suites, 551 `en.lproj` keys, `LocalizationTests.awaitingTranslation` empty.
- **Features:** C (Start and Finish a group, with protected apps), D (pair a group with a macOS
  Focus), E (launch options per item: a delay and "Open With").
- **Builds on:** `docs/design/group-items-and-tags-spec.md` (A+F, shipped in 0.7.0). Its naming,
  the Core/App split, `ItemAction` / `ItemPresence`, the launch guards of `GroupLauncher`, the
  compatibility rules for `groups.json` and backups, and the PR format are reused here.
- **Clean room:** the behavior below comes from the written acceptance criteria, the research
  summary in §1 and this repository only. Every claim about current code cites `file:line` at
  `b32f6af` (paths are relative to `Sources/` unless they start with `Tests/`, `docs/` or a file at
  the repository root).

## Acceptance criteria (behavior)

C, Start and Finish:

- **C-1** Every group can be **started**. Starting opens its items as Open All does and then, as
  the group's settings say, hides the running apps of the group started before it (the default),
  hides every other app, quits the previous group's apps, or leaves everything else alone. Apps the
  two groups share are never hidden or quit.
- **C-2** Every group can be **finished**. Finishing hides its running apps (the default), quits
  them, or leaves them, and then, as the group's settings say, shows the running apps of the group
  started before it again. Finishing never launches anything.
- **C-3** Quitting is never a default and always graceful (apps can still ask to save changes;
  nothing is force quit). An automatic trigger (a Focus) never quits: it hides instead. A link,
  Siri or the Shortcuts app asks first whenever a transition would quit an app.
- **C-4** **Protected apps**, a list in Settings, are never quit by Start, Finish or Close All
  (from the popup, the menus, a link, Siri, or a standalone group's own app) and never hidden by
  Start or Finish. This app and its standalone groups' apps are always protected, and Finder is
  never quit.
- **C-5** Start and Finish are offered in the popup, the menu bar menu, the group window, through
  links (`cybokrondockgroups://start/<group>`, `…/finish/<group>`) and in Siri and the Shortcuts
  app. A standalone group's own app doesn't offer them in this wave.
- **C-6** The app knows which group is **current** (the one started last, until it's finished) while
  it runs; the popup and the menu bar menu show it.
- **C-7** Open All, Hide All and Close All work as they do today, except that Close All spares
  protected apps (C-4).

D, Focus:

- **D-1** In System Settings → Focus → a Focus → Focus Filters, the user can add a Cybokron Dock
  Groups filter that names a group and what happens when that Focus turns on: **Start** (the
  default), **Open All** or **Show Popup**; and whether the group is finished when the Focus turns
  off (off by default).
- **D-2** It happens once per Focus change, without polling. Switching from one Focus to another
  does the second Focus's action; the first Focus's group is finished only if its own filter asks.
- **D-3** A transition caused by a Focus never quits an app and never asks: a quitting setting acts
  as hiding.
- **D-4** The app never changes the Focus, so it can't start a loop. The same request arriving
  twice (a Focus filter and a Shortcuts automation that both start the group) is carried out once.
- **D-5** Settings says where the pairing is set up, opens the Focus settings, and shows what the
  current Focus asks of the app.

E, launch options:

- **E-1** Any item can have a **launch delay** of 0 to 60 seconds. Open All and Start apply it;
  clicking an item (or Return) opens it right away.
- **E-2** A file, folder or website can be opened **with a chosen app** instead of its default app,
  among the apps macOS lists as able to open it.
- **E-3** A delayed item that hasn't opened yet doesn't open when its group is finished, another
  group is started, or Hide All or Close All runs on its group; nor when it was removed or changed
  meanwhile.
- **E-4** Launch options never run code the item itself couldn't run: there are no arguments,
  commands or scripts, and a chosen app that would run the item, or that macOS doesn't list for
  it, is refused. That holds whether the setting was made in the app, written into
  `groups.json`, or brought in with a backup (`SECURITY.md`, "Scope").
- **E-5** Launch options are edited with the item's other details (alias, tags, task notes), in the
  same editor, and saved once, on Done.
- **E-6** Versions 0.7.0 and earlier read the files this version writes without errors: they open
  items with their default apps and without delays, and ignore Start and Finish settings and
  protected apps.

Non-goals (this wave): launch arguments, browser profiles, terminal commands, shell scripts and
AppleScript (the research's second phase of E); automatic triggers other than Focus (research M);
per-group global shortcuts, including for Start and Finish (research G); window layouts (H); live
window previews (N), browser tab and session restore (O), iCloud sync (P); Start and Finish in
standalone groups' own apps; changing the Focus from the app.

---

## 0. Summary and scope

### 0.1 Summary

Cybokron Dock Groups already opens, hides and quits a group's apps as three separate commands. This
wave turns them into **context switching**: one move that brings a group forward and puts the
previous one away (Start), one that puts a group away and brings the previous one back (Finish), a
list of apps that switching never quits, a way for a macOS Focus to start a group, and per-item
launch options (a delay, and which app opens a file, folder or website).

Three design decisions carry most of the weight (each argued where it's made):

1. **A transition is planned in Core, as a pure function, and only then carried out** (§3.3). The
   plan lists exactly which apps are hidden, quit, shown again and opened, and why the others are
   kept. Safety rules — protected apps, shared apps, "automatic triggers never quit", "links and
   Siri ask before quitting" — are properties of the plan, so they're tested in
   `DockGroupsCoreTests` without AppKit, as `ItemAction.available` made the A+F menus testable.
2. **Focus pairings live in the system's Focus settings, not in the app** (§3.6). The app declares
   a Focus filter (`SetFocusFilterIntent`); macOS stores which group a Focus names and calls the
   app when the Focus turns on or off. There's no Focus data to read, nothing to poll, no new
   permission, and nothing in `groups.json` or backups.
3. **"Open With" adds no new way to run code** (§5). The item is checked exactly as in 0.7.0
   first; the chosen app is resolved by bundle identifier through LaunchServices at launch time
   (never a stored path), must be an app bundle macOS lists for that item, and must not be an app
   that runs what it opens. Any failure refuses the open (fail closed), from every source.

### 0.2 Scope

| In | Out (and where it would go) |
| --- | --- |
| Start, Finish, the current group (C) | Window layouts (H) |
| Protected apps ("never quit") (C) | Per-group shortcuts, also for Start and Finish (G) |
| Focus filter → Start, Open All or Show Popup; finish when the Focus ends (D) | Time, display or network triggers (M) |
| Launch delay per item (E, phase 1) | Arguments, browser profiles, terminal commands, scripts (E, phase 2) |
| "Open With" for files, folders, websites (E, phase 1) | Live previews (N), browser sessions (O), iCloud sync (P) |
| Links, Siri and Shortcuts for Start and Finish | Start and Finish in standalone groups' own apps |

### 0.3 Current-state inventory (what this wave builds on)

| Area | Where | What it does today |
| --- | --- | --- |
| Open All | `DockGroupsCore/Launching/GroupLauncher.swift:99` | apps launched concurrently, then files and folders (one request per default app), then websites; report in group order |
| Open one item | `GroupLauncher.swift:67` | activate, reopen or launch an app; check and open a file or folder; open a website |
| Launch guards | `GroupLauncher.swift:175` (`locateApplicationBundle`), `:215` (`check`) | apps start only from `.app` bundles; files and folders are checked every time (name, presence, type, kind) |
| Refused default apps | `DockGroupsCore/Model/FileItemPolicy.swift:74-87` | Terminal, iTerm2, Installer, ProfileHelper, System Settings, Automator Installer, Java launcher never open a file item |
| File opening | `DockGroupsCore/Launching/ApplicationWorkspace.swift:91` | `openFileItems` groups by default app; refuses a refused default app |
| Hide All, Close All | `DockGroupsCore/Launching/GroupTerminator.swift:95`, `:116` | only apps with a process (`Kind.hasProcess`, `:135`); this app never quits or hides itself |
| Quit requests | `DockGroupsCore/Commands/GroupQuitRequests.swift:115`, `:130` | a link asks with the app's alert (confirm button delayed 0.7 s); Siri and Shortcuts ask with `requestConfirmation` |
| Siri confirmation (I8) | `CybokronDockGroups/Intents/GroupIntents.swift:79-109` | `requestConfirmation(actionName:dialog:)` on macOS 15+, the deprecated variant through `MacOS14Confirming` on 14 |
| App Shortcuts | `CybokronDockGroups/Intents/DockGroupsShortcuts.swift:8`, `:19`, `:30` | Launch, Quit and Show Group (3 of the 10 allowed) |
| Intent handler | `CybokronDockGroups/Intents/GroupIntentSupport.swift:22`, `:35` | `handler` is set by the app delegate; `resolve` throws `notReady` before that |
| App wiring | `CybokronDockGroups/App/AppDelegate.swift:42-44`, `:260-288`, `:340-384` | Close All through `GroupQuitRequests`; Open All and Hide All direct; link commands |
| Agent wiring | `CybokronDockGroups/Agent/AgentAppDelegate.swift:42-43`, `:317-318`, `:232` | the agent's Close All calls `GroupTerminator.closeAll` directly (A+F §6.3 D1, still true); its Dock menu |
| Links | `DockGroupsCore/Commands/URLCommand.swift:92-95` | `launch/` and `hide/` share one cooldown (`groupActionKey`); `quit/` asks first |
| Global shortcuts (I6) | `DockGroupsCore/Shortcuts/GroupHotKeys.swift:97-113` | 18 hot keys (number row and keypad 1…9) with one modifier set, registered all or none |
| Settings panes | `CybokronDockGroups/Settings/SettingsWindowController.swift:107-114` | Popup, Shortcuts & Siri, Most Used, Updates, Backup, Changelog, Support |
| Group window sections | `CybokronDockGroups/MainWindow/GroupDetailView.swift:78-82` | Group, Items, Dock Tile, Standalone, Popup |
| Item details editor | `CybokronDockGroups/MainWindow/ItemDetailsEditor.swift:14`, `DockGroupsCore/Model/ItemDetailsDraft.swift` | alias, tags and task notes; saved once on Done |
| Popup header | `CybokronDockGroups/Popup/PopupContentView.swift:173-221` | group name and summary, then Open All, Hide All, Close All (⌘ turns it into Force Quit) |
| Menu bar menu | `CybokronDockGroups/MenuBar/StatusBarController.swift:155-184` | each group; ⌥ alternate Open All, ⇧⌥ alternate Hide All |
| Item model | `DockGroupsCore/Model/AppReference.swift:153-154` | coding keys `bundleIdentifier, name, path, kind, url, alias, tags, notes` |
| Group model | `DockGroupsCore/Model/DockGroup.swift:104-105` | coding keys; unknown keys ignored, display values decoded leniently |
| Preferences | `DockGroupsCore/Model/PopupPreferences.swift:147` | flat keys; every value optional and lenient, unknown keys ignored |
| Agent configuration | `DockGroupsCore/Standalone/AgentConfiguration.swift:22-23` | embeds the group and a preferences snapshot (minus the update setting); any change rebuilds the agent, debounced 1.5 s (`CybokronDockGroups/Standalone/StandaloneController.swift:36`) |
| Downgrades | `DockGroupsCore/Updates/DowngradeProtection.swift`, `ReleaseHistory.swift:23` | copies `groups.json` aside before installing a version older than 0.6.8; warns when groups use items it can't show |
| Session state | — | none: nothing records which group was opened last, except the popup's `lastGroupID` (`CybokronDockGroups/Popup/PopupPanelController.swift:95`) |
| Focus | — | no Focus code anywhere in `Sources/` |

### 0.4 What A+F left that matters here

- **D1 is still open.** A+F's optional R2 (`GroupActionPerformer`) wasn't done, so Close All has two
  paths: the main app's (`GroupQuitRequests`) and the agent's (direct). Protected apps therefore
  live in `GroupTerminator` itself (§3.4), where both paths pass.
- **The launch guard is the security boundary** (A+F §2.3, shipped stricter: `.unverified` items
  aren't opened, `GroupLauncher.swift:229-230`). E plugs into it after the item is checked, never
  before (§3.5).
- **Every app-wide preference is copied into every agent's configuration**, so a new preference
  rebuilds every standalone group's app on each change unless the snapshot normalizes it (as it does
  for `automaticallyChecksForUpdates`). §3.9 normalizes the new values.

---

## 1. What the research asks for (summary of sections C, D and E)

The research report ("Cybokron Dock Groups için Yeni Özellik Araştırması ve Önceliklendirme
Raporu", 23 October 2026) ranks these three features "high" and groups them, with protected apps,
into a "Context Switching" phase that comes after files, folders and task tags. In its words, the
app would become a "context manager" rather than a launcher. Its sections C, D and E, summarized:

### 1.1 C: Start and Finish, and safe context switching

- **Idea.** Open All, Hide All and Close All already exist. Combine them into one transition
  engine: "Switch to Coding" hides the Design group safely, launches the Coding group, opens its
  resources and turns on the Work Focus. "Finish Coding" leaves out some apps, closes or hides the
  Coding group, and returns to the previous context.
- **Prior art.** Workspaces models this as START and FINISH; Bunch runs different actions when a
  context opens and when it closes.
- **Exclusions are critical.** A DockDoor feature request (#1664, 18 October 2026) asks for an
  exclusion list after an automatic "quit the app when its last window closes" ended the Phone app
  by surprise ("add a button that allows to select apps to exclude").
- **Difficulty: medium to high.** Opening, hiding and quitting are easy; the hard part is safe
  behavior. Force quitting an app with unsaved documents must never be a default. "Close apps not in
  the next group" must start **off**, with per-app exclusions and normal (graceful) quitting.
- **Risk.** Low privacy cost, low to medium performance cost; the real risk is data loss through
  behavior, not technology. **Priority:** high, in stages.

### 1.2 D: pairing a group with a macOS Focus

- **Idea.** Pairings such as Work Focus → Work group, Personal → Personal, Coding → Dev. When the
  Focus changes, the app does a configurable action: **Do nothing, Show Group, Launch Group** or
  **Switch Context**.
- **Prior art.** DockFlow markets "the Dock changes and apps launch when a Focus is on"; a review
  calls Focus plus Shortcuts automation its most valuable power-user feature. Apple's App Intents
  has an official Focus filter API (`SetFocusFilterIntent`).
- **Benefit.** The user stops thinking about which group to open: the group follows the system's
  context, and the app already has the Siri and Shortcuts groundwork.
- **Difficulty: medium.** The design question is matching events to state and **preventing
  loops**: if the app changes the Focus and the Focus triggers the app, there must be no recursion.
- **Cost.** Very low privacy and performance cost; use the system's mechanism, **not polling**.
  **Priority:** high.

### 1.3 E: launch actions, delays and the target app per item

- **Idea.** An item stops being only "open" and can carry a small launch recipe: VS Code with
  `~/Projects/cybokron`, Arc with the Work profile and a GitHub address, Terminal in
  `~/Projects/cybokron`, Figma right away, Slack three seconds later.
- **Prior art.** Workspaces delays resources and chooses which app opens a file or folder; DockFlow
  opens an IDE with a project or switches browser profiles; Bunch opens a project folder and runs
  commands in a terminal there.
- **Stages.** First **delay, Open With and URL**; later arguments, browser profiles, terminal
  commands and scripts. `NSWorkspace.open(_:withApplicationAt:configuration:completionHandler:)` is
  the natural basis.
- **Cost.** Low privacy cost while everything stays local. Shell scripts widen the attack surface a
  lot: **scripts coming from a backup must never run on their own**. Low performance cost; delays
  can even spread the load at login. **Priority:** high for the simple recipe, medium to low for a
  script engine.

### 1.4 A conflicting recommendation

The later "Final Özellik Önerisi" (23 October 2026, outside the repository) recommends a smaller
C ("switch to this group" that hides rather than quits, with a global never-quit list and a
`switch/<group>` link) and an "Open With" choice, but **drops Focus integration**: Siri and
Shortcuts already exist, and there are bug reports about Focus filters on macOS 26.5. It also drops
shell hooks for safety. This spec follows the research for D: Focus **ships last (PR 5), behind a
spike** that checks delivery on macOS 14, 15 and 26 (§8 R1, DECISION 1; decided by the user on
2026-10-24). `switch/` is accepted as a synonym of `start/` (§2.6). Scripts are out either way.

---

## 2. Behavior specification

### 2.1 Words used in this spec and in the app

| Term | Meaning |
| --- | --- |
| **Start** | Bring a group forward: open its items (as Open All does), then put the previous group away as the group's settings say. Shown as "Start" in buttons and "Start “Coding”" in menus. |
| **Finish** | Put a group away: hide (or quit, or leave) its running apps, then show the previous group again if the settings say so. |
| **Current group** | The group started last that hasn't been finished. At most one. |
| **Previous group** | The group that was current before the current one was started. |
| **Protected apps** | Apps that Start, Finish and Close All never quit, and Start and Finish never hide. |
| **Shared app** | An app that is in both groups of a transition: it's never hidden or quit by it. |
| **Launch options** | An item's launch delay and "Open With" app. |
| **Trigger** | Who asked: the user's click, a link, Siri or Shortcuts, or a Focus. |

The commands keep their names: Open All, Hide All, Close All are unchanged; Start and Finish are new.

### 2.2 Start

1. The group to start is **T**; the current group, if any, is **P**.
2. If T is already current and was started less than 3 seconds ago, nothing happens (D-4); otherwise
   Start runs even when T is current (it opens what isn't open yet).
3. **Putting the others away** happens first, as T's setting "When this group starts" says:

   | Setting | Effect | Default |
   | --- | --- | --- |
   | Leave other apps open | nothing | |
   | Hide the previous group's apps | P's running apps that aren't in T are hidden | **yes** |
   | Hide all other apps | every running regular app that isn't in T is hidden | |
   | Quit the previous group's apps | P's running apps that aren't in T are asked to quit | |

   Never touched: protected apps, apps in T, this app and its standalone groups' apps, Finder (never
   quit; it can be hidden by "Hide all other apps"), and processes that aren't regular apps
   (`NSApplication.ActivationPolicy.regular`). Without a P, the "previous group" settings do nothing.
4. **Then T's items open** exactly as Open All opens them, launch options included (§2.9).
5. T becomes current and P becomes previous (§2.4).
6. Problems are reported as today (`LaunchReportPresenter`): items that couldn't open, apps that
   couldn't be hidden or quit. Siri and Shortcuts get a one-sentence summary (§2.7).

Hiding first and opening second matches the research's order and keeps T's apps in front. A
"quit" setting with a trigger that may not quit (§2.5) acts as "Hide the previous group's apps".

### 2.3 Finish

1. The group to finish is **G**; it's usually the current group, but any group can be finished.
2. The group shown next, **N**, is the previous group when G is current and G's setting "After
   finishing" is "Show the previous group" (the default); otherwise there's none.
3. **G's running apps** are put away as G's setting "When this group finishes" says: **Hide them**
   (default), **Quit them**, or **Leave them open**. Never touched: protected apps, apps also in N,
   this app and its standalone groups' apps, Finder.
4. G's delayed items that haven't opened yet are cancelled (E-3).
5. **Then N's running apps are shown again** (un-hidden, the first brought to the front). Nothing
   is launched: an app of N that was quit stays quit.
6. G stops being current; N becomes current (and its own previous group becomes previous), or no
   group is current.

### 2.4 The current group

- Only Start makes a group current; Open All, Show Popup and clicking an item don't.
- The app keeps a short history of started groups (the last 8, each group once) in memory only. It
  starts empty at each launch (DECISION 6): after an update or a restart, no group is current
  and Finish's "show the previous group" does nothing until a group is started again.
- Deleting a group removes it from the history; renaming doesn't matter (groups are kept by ID).
- The popup's summary line says "current" for the current group; its Start button becomes Finish
  (§4.1). The menu bar menu shows the current group first (§4.2).

### 2.5 Which triggers may quit, and which ask

| Trigger | Quitting settings | Asks first |
| --- | --- | --- |
| The user's click (popup, menu bar, group window) | apply | no (the user chose the setting and clicked, as with Close All) |
| A link (`start/`, `finish/`, `switch/`) | apply | **yes**, the app's alert, as `quit/` links ask (`GroupQuitRequests`), only when the plan quits something |
| Siri or the Shortcuts app | apply | **yes**, in Siri or Shortcuts (`requestConfirmation`, the I8 bridge), only when the plan quits something |
| A Focus | **act as hiding** | never |

The question names the apps it would quit. Declining a link's question offers to hide instead; a
declined Siri confirmation ends the request (as Quit Group does). Force quitting is never offered.

Dialog drafts (en-US):

```
Switch to “Coding” and quit 2 apps?
“Coding” is set to quit the apps of “Design” it doesn't use: Figma, Sketch.
A link opened by another app, a script or a web page asked for this. Apps can still ask to save changes.
                                   [Cancel]  [Hide Instead]  [Quit and Switch]   (confirm enabled after 0.7 s)

Finish “Coding” and quit 3 apps?
Finishing “Coding” quits Xcode, Simulator and Instruments. Protected apps and apps “Design” uses stay open.
Apps can still ask to save changes.
                                   [Cancel]  [Hide Instead]  [Quit Apps]
```

Siri and Shortcuts show the title and the second line, with "Quit Apps" and "Cancel".

### 2.6 Links

| Link | Command | Cooldown |
| --- | --- | --- |
| `cybokrondockgroups://start/<group>` (also `switch/<group>`) | Start | shares the `group-apps` cooldown with `launch/` and `hide/` (`URLCommand.swift:92-95`) |
| `cybokrondockgroups://finish/<group>` | Finish | the same |

`<group>` is a name, slug or identifier, as for the other links (`GroupLookup`). Settings → Shortcuts
& Siri lists both links for every group (`GroupInvocations.links`).

### 2.7 Siri and the Shortcuts app

Two new intents, in the "Groups" category, with App Shortcuts phrases:

| Intent | Phrases | Result |
| --- | --- | --- |
| **Start Group** | "Start \(group) in \(app)", "Switch to \(group) in \(app)", "Start a group in \(app)" | "Started “Coding”: opened 4 items and hid 3 apps of “Design”." |
| **Finish Group** | "Finish \(group) in \(app)", "Wind up \(group) in \(app)", "Finish a group in \(app)" | "Finished “Coding”: hid 4 apps and showed “Design” again." |

Both resolve the group first (`GroupIntentSupport.resolve`), ask before quitting (§2.5) and never
force quit. Launch Group, Quit Group and Show Group don't change. The app then has 5 of the 10 App
Shortcuts the system allows. Settings → Shortcuts & Siri lists the two new phrases per group
(`GroupInvocations.siriPhrases`).

### 2.8 Protected apps

- **Settings → Switching → Protected Apps**: a list of apps with an Add Apps… button (the existing
  app picker, `.app` bundles only) and an "Add a Running App" menu of the running regular apps;
  each row has a remove button. At most 50 apps.
- Footer text: "Start, Finish and Close All never quit these apps, and switching groups never
  hides them. Cybokron Dock Groups and its groups' own apps are always protected, and Finder is
  never quit."
- Close All (popup, menu, `quit/` link, Quit Group in Siri, a standalone group's Dock menu and popup)
  skips protected apps; Hide All doesn't (the user asked to hide that group).
- When Close All or Finish skips protected apps, the report says so: Siri "Asked 2 apps in “Work”
  to quit; Slack is protected and stays open." The app shows no alert for skipped apps.

### 2.9 Launch options

- **Delay** (all kinds): None, 1, 2, 3, 5, 10, 15, 30 or 60 seconds. Applied by Open All and Start
  only. An item with a delay opens that many seconds after the command started (delays run side by
  side, not one after another). Items without a delay open as today.
- **Open With** (files, folders, websites; not apps): "Default App" (the default) or one of the apps
  macOS lists for that item (§3.5), and "Other…" (an open panel limited to apps, whose choice is
  checked the same way). A folder (only a folder item) can be opened in Terminal or iTerm2, which
  macOS doesn't list (DECISION 5, §5.4); a backup never brings that choice in.
- **Clicking an item** opens it with its "Open With" app, without its delay.
- **The chosen app isn't on this Mac** (it was removed, or the group came from another Mac): the
  item opens with its default app, and the row says so (§4.3). This isn't reported as a problem.
- **The chosen app can't open the item safely** (§3.5): the item isn't opened, and the report says
  "• Notes.txt: wasn't opened with “Terminal”, because that app can't open it safely."
- **Pending delayed items** are cancelled by Finish, by starting another group, by Hide All or Close
  All of their group; when one fires, it's looked up again in its group and skipped if it was
  removed or its launch options changed. Problems of delayed items are reported when they fire, in
  one alert per command.
- **Standalone groups' own apps** apply launch options too (their Open All uses `GroupLauncher`).

### 2.10 Focus

- **Setting it up** happens in System Settings → Focus → (a Focus) → Focus Filters → Add Filter →
  Cybokron Dock Groups. The filter's fields (from the app's `SetFocusFilterIntent`):
  - **Group**: one of the groups (the existing `GroupEntity`, so a renamed group keeps working).
  - **When This Focus Turns On**: Start (default), Open All, or Show Popup.
  - **Finish the Group When This Focus Turns Off**: off by default (DECISION 3).
- **When the Focus turns on**, the app waits 1 second for the system to settle (switching Focus A →
  B may deliver more than one call), then does the last request: Start, Open All or Show Popup. A
  Start caused by a Focus never quits (§2.5).
- **When the Focus turns off**, the system calls the filter with empty fields. If the Focus's group
  was started by that Focus, is still current, and the filter said to finish it, it's finished
  (hiding only). Otherwise nothing happens.
- **Switching Focus A → B**: B's request is done; A's group is finished first only if A's filter
  said so, A's group is still current, and A's group isn't B's group.
- **A deleted group** in a filter does nothing (logged). A group named by a filter that's already
  current is started again only after the 3-second rule (§2.2).
- **The app isn't running** when the Focus changes: macOS is expected to launch it to deliver the
  request (assumption D-A1, §3.6); the request is carried out once the groups are loaded.
- **At launch**, the app only reads what the current Focus asks (for Settings); it doesn't act on
  it, so starting the app never hides or opens anything by surprise.
- **Settings → Switching → Focus** explains the setup, has an "Open Focus Settings…" button, and
  shows "The current Focus starts “Coding”." or "No Focus asks Cybokron Dock Groups for anything
  right now." The system doesn't tell the app which Focus is on, only what its filter asks, so the
  text never names the Focus.

### 2.11 Standalone groups' own apps

Their popup and Dock menu keep Open All, Hide All and Close All; Close All spares protected apps
(C-4); Open All applies launch options. They don't offer Start or Finish (DECISION 8) and know
nothing of the current group: they read only `group-config.json`, and the session lives in the main
app.

---

## 3. Architecture

### 3.1 Layers and files

| Layer | New or changed | Purpose |
| --- | --- | --- |
| Core model | `Model/GroupSwitching.swift` (new) | a group's Start and Finish settings |
| Core model | `Model/ProtectedApps.swift` (new) | the protected app list and the implicit protections |
| Core model | `Model/ItemLaunchOptions.swift` (new) | an item's delay and "Open With" app |
| Core switching | `Switching/RunningAppSnapshot.swift` (new) | what a running app is, for planning |
| Core switching | `Switching/TransitionPlanner.swift` (new) | pure planning of Start and Finish (§3.3) |
| Core switching | `Switching/ContextSession.swift` (new) | the current group and history (§3.2) |
| Core switching | `Switching/ContextSwitcher.swift` (new) | carries a plan out, asks, reports (§3.4) |
| Core switching | `Switching/FocusRequestCoordinator.swift` (new) | settles, de-duplicates and maps Focus calls (§3.6) |
| Core launching | `Launching/ItemOpenerPolicy.swift` (new), `Launching/ApplicationCatalog.swift` (new) | decides whether a chosen app may open an item (§3.5) |
| Core launching | `Launching/DelayedLaunches.swift` (new) | schedules and cancels delayed items (§3.5) |
| Core launching | `GroupLauncher.swift`, `ApplicationWorkspace.swift`, `GroupTerminator.swift` (changed) | openers, delays, protection, un-hiding |
| Core commands | `URLCommand.swift`, `GroupInvocations.swift`, `GroupQuitRequests.swift` (changed) | links, listed phrases and links, transition questions |
| Core persistence | `SettingsBackup.swift`, `AgentConfiguration.swift`, `DowngradeProtection.swift` (changed) | import rules, agent snapshot, downgrades |
| App | `Intents/SwitchingIntents.swift`, `Intents/GroupFocusFilter.swift` (new) | Start and Finish intents, the Focus filter |
| App | `Settings/SwitchingSettingsView.swift` (new) | the Switching pane |
| App | `GroupDetailView.swift`, `ItemDetailsEditor.swift`, `AppRowView.swift`, `PopupContentView.swift`, `PopupPanelController.swift`, `StatusBarController.swift`, `AppDelegate.swift` (changed) | surfaces |

`AppReference` keeps its name (A+F §1.1); new APIs use `GroupItem`.

### 3.2 Model

```swift
/// What starting and finishing a group does besides opening its items (§2.2, §2.3).
public struct GroupSwitching: Hashable, Sendable {
    public enum OnStart: String, Codable, CaseIterable, Sendable {
        case leaveOthers, hidePreviousGroup, hideAllOtherApps, quitPreviousGroup
    }
    public enum OnFinish: String, Codable, CaseIterable, Sendable {
        case hideApps, quitApps, leaveApps
    }
    public enum AfterFinish: String, Codable, CaseIterable, Sendable {
        case nothing, showPreviousGroup
    }
    public var onStart: OnStart = .hidePreviousGroup
    public var onFinish: OnFinish = .hideApps
    public var afterFinish: AfterFinish = .showPreviousGroup
    /// The defaults: nothing is written for such a group.
    public var isDefault: Bool { self == GroupSwitching() }
    /// The settings an automatic trigger uses: quitting becomes hiding (C-3, D-3).
    public var withoutQuitting: GroupSwitching
}

extension DockGroup {
    public var switching: GroupSwitching   // new stored property, JSON key "switching"
}

/// The apps that switching and Close All never quit, and switching never hides (C-4).
public struct ProtectedApps: Hashable, Sendable {
    public static let maximumCount = 50
    /// Apps only (identified as group apps are: bundle identifier, or bundle path); unique.
    public private(set) var apps: [GroupItem]
    public init(_ apps: [GroupItem])                      // keeps applications, dedupes, caps
    /// Listed, or always protected: this app, its agents (`AgentIdentity.bundleIdentifierPrefix`),
    /// and — for quitting — Finder.
    public func protects(_ app: RunningAppSnapshot, from action: ProtectedAction) -> Bool
    public enum ProtectedAction: Sendable { case hiding, quitting }
}

extension PopupPreferences {
    public var protectedApps: ProtectedApps               // new, key "protectedApps"
}

/// An item's launch options (the research's "launch recipe", first stage).
public struct ItemLaunchOptions: Hashable, Sendable {
    public static let allowedDelays = [0, 1, 2, 3, 5, 10, 15, 30, 60]   // seconds; UI steps
    public static let maximumDelay = 60
    /// Seconds after Open All or Start; 0 = right away. Decoding clamps to 0…60.
    public private(set) var delay: Int
    /// Files, folders and websites only; `nil` = the default app.
    public private(set) var opener: ItemOpener?
    public init(delay: Int = 0, opener: ItemOpener? = nil, kind: AppReference.Kind)   // drops an opener for apps
    public var isEmpty: Bool
}

/// The app chosen to open an item: identified by bundle identifier only — never a location, so
/// a groups file or backup can't point it at a program somewhere on disk.
public struct ItemOpener: Hashable, Sendable {
    public let bundleIdentifier: String   // 1…255 characters of [A-Za-z0-9.-]; else dropped
    public let name: String               // shown when the app isn't on this Mac
}

extension AppReference {
    public var launch: ItemLaunchOptions                  // new stored property, flat keys (§3.9)
}
```

`ContextSession` (Core, `@MainActor final class ContextSession: ObservableObject`):

```swift
@Published public private(set) var current: DockGroup.ID?
public private(set) var history: [DockGroup.ID]          // most recent first, max 8, each once
public private(set) var startedAt: Date?                 // of the current group, for the 3 s rule
public private(set) var startedByFocus: FocusRequest?    // set when a Focus started the current group
public var previous: DockGroup.ID? { history.dropFirst().first }
public func didStart(_ id: DockGroup.ID, at: Date, byFocus: FocusRequest?)
public func didFinish(_ id: DockGroup.ID, showing next: DockGroup.ID?)
public func prune(keeping ids: Set<DockGroup.ID>)        // on store.$groups
```

### 3.3 Planning a transition (pure, Core)

```swift
/// A running app as planning sees it; built from `NSRunningApplication` by the app, by hand in tests.
public struct RunningAppSnapshot: Hashable, Sendable {
    public let processIdentifier: pid_t
    /// Lowercased bundle identifier, or the normalized bundle path for apps without one
    /// (`RunningApplicationLookup.pathIdentity`), matched as group items are.
    public let identity: String
    public let name: String
    public let isHidden: Bool
    public let isRegular: Bool
}

public enum TransitionTrigger: String, Sendable, CaseIterable {
    case userAction, link, intent, focus
    public var mayQuit: Bool { self != .focus }
    public var asksBeforeQuitting: Bool { self == .link || self == .intent }
}

public struct TransitionPlan: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case start(DockGroup.ID), finish(DockGroup.ID) }
    public struct KeptApp: Equatable, Sendable {
        public enum Reason: Equatable, Sendable { case protected, shared, alwaysProtected }
        public let app: RunningAppSnapshot
        public let reason: Reason
    }
    public let kind: Kind
    public var hide: [RunningAppSnapshot]
    public var quit: [RunningAppSnapshot]             // graceful only, never forced
    public var unhide: [RunningAppSnapshot]           // Finish → the group shown next
    public var open: DockGroup?                       // Start → Open All of this group
    public var kept: [KeptApp]                         // for reports: why an app was left alone
    public var next: DockGroup.ID?                    // the group current afterwards
    public var quitsAnything: Bool { !quit.isEmpty }
}

public enum TransitionPlanner {
    public static func start(_ target: DockGroup, previous: DockGroup?, running: [RunningAppSnapshot],
                             protected: ProtectedApps, trigger: TransitionTrigger) -> TransitionPlan
    public static func finish(_ group: DockGroup, next: DockGroup?, running: [RunningAppSnapshot],
                              protected: ProtectedApps, trigger: TransitionTrigger) -> TransitionPlan
    /// The same plan with every quit turned into a hide ("Hide Instead").
    public static func hidingInsteadOfQuitting(_ plan: TransitionPlan) -> TransitionPlan
}
```

Rules the planner applies, in this order (each one is a test in §7):

1. Only running regular apps that aren't terminated are considered.
2. An app is "in a group" when an application item of the group has its identity (case-insensitive,
   path identities as `RunningApplicationLookup`); websites, files and folders have no process
   (`Kind.hasProcess`, A+F §1.3).
3. Never hidden or quit: this app (by process identifier), standalone groups' apps (bundle
   identifier prefix `com.cybokron.dockgroups.agent.`), apps in the target or next group (shared),
   protected apps. Never quit: Finder (`com.apple.finder`).
4. `trigger.mayQuit == false` turns every quit into a hide (`GroupSwitching.withoutQuitting`).
5. An app that is already hidden isn't hidden again; an app in `unhide` that isn't hidden is left.
6. Order of the lists follows the group's item order, then the running order for "all other apps".

The planner reads nothing and changes nothing: it gets a snapshot. The app makes the snapshot once
per transition from `NSWorkspace.shared.runningApplications` (one call), through a protocol
(`RunningApplicationsListing`) so tests never touch the system.

### 3.4 Carrying a transition out

```swift
@MainActor public final class ContextSwitcher {
    public init(store: GroupStore, preferences: PreferencesStore, session: ContextSession,
                launcher: GroupLauncher, terminator: GroupTerminator,
                applications: RunningApplicationsListing, delayed: DelayedLaunches,
                prompt: TransitionConfirmationPrompting, clock: () -> Date = Date.init)
    /// `confirm` is the intent's question (Siri, Shortcuts); links use `prompt`; nil for others.
    public func start(_ id: DockGroup.ID, trigger: TransitionTrigger,
                      confirm: ((TransitionConfirmation) async throws -> Void)? = nil) async throws -> TransitionReport
    public func finish(_ id: DockGroup.ID, trigger: TransitionTrigger,
                       confirm: ((TransitionConfirmation) async throws -> Void)? = nil) async throws -> TransitionReport
}
```

Sequence: plan → ask if `plan.quitsAnything && trigger.asksBeforeQuitting` (a link's "Hide
Instead" re-plans with `hidingInsteadOfQuitting`; a declined intent throws, as Quit Group does) →
cancel the delayed items of the groups put away → hide → quit (graceful) → un-hide → `openAll`
(Start) → update the session → report.

- **`GroupTerminator` gains** `hide(_:)`, `quit(_:)` and `unhide(_:)` for snapshots (looked up again
  by process identifier at that moment; an app that quit meanwhile is skipped). `closeAll(_:mode:)`
  and `hideAll(_:)` keep their signatures; the terminator reads the protected apps from an injected
  `() -> ProtectedApps` (the main app's from its preferences, an agent's from its configuration),
  and Close All skips them. `QuitReport` gains `kept: [AppReference]`.
- **`TransitionConfirmation`** sits next to `QuitConfirmation` (`GroupQuitRequests.swift:21`) with
  the same delayed confirm button; `GroupQuitRequests` gains a `requestTransition` that drops a
  link's question while another is showing (as it drops quit links now).
- **`TransitionReport`** bundles the `LaunchReport` (Start), hide and quit reports and the kept apps;
  `LaunchReportPresenter` presents its problems; `summary` gives Siri's sentence.

**Concurrency.** Everything here is `@MainActor`, as `GroupStore`, `GroupLauncher` and
`GroupTerminator` are: `NSWorkspace` and `NSRunningApplication` are used from the main thread, and
the only waits are LaunchServices completion handlers and `Task.sleep`. A custom `actor` would add
hops without protecting any state the main actor doesn't already own. Transitions are **serialized**:
`ContextSwitcher` chains each request after the one before (`await previous.value`), so a second
Start can't interleave with the first one's `openAll`. The link alert is modal on the main thread,
as quit links' alert is today; while it shows, other link transitions are dropped and Focus
requests wait in the coordinator. Nothing busy-waits.

### 3.5 Launch options in `GroupLauncher`

**Opener check** (Core, pure decision plus a catalog protocol):

```swift
/// What LaunchServices knows about apps; the app's implementation uses NSWorkspace, tests a fake.
@MainActor public protocol ApplicationCatalog: AnyObject {
    func applicationURL(forBundleIdentifier id: String) -> URL?
    /// The apps that declare they open `url` (`NSWorkspace.urlsForApplications(toOpen:)`).
    func applicationURLs(toOpen url: URL) -> [URL]
    func bundleIdentifier(ofApplicationAt url: URL) -> String?
}

public enum ItemOpenerDecision: Equatable, Sendable {
    case defaultApp                 // no opener, or the opener isn't on this Mac
    case openWith(URL)              // checked: open the item with this app
    case refused(openerName: String)
}

public enum ItemOpenerPolicy {
    /// Apps that run what they're given: never an opener of a file; of a folder only the two terminals below (§5.4).
    public static let runnerBundleIdentifiers: Set<String>   // terminals and script runners (§5.3)
    /// Bundle identifiers of the terminals allowed to open a folder item (DECISION 5).
    public static let folderTerminalBundleIdentifiers: Set<String> = ["com.apple.terminal", "com.googlecode.iterm2"]
    @MainActor public static func decide(_ opener: ItemOpener?, for item: GroupItem, target: URL,
                                         catalog: ApplicationCatalog) -> ItemOpenerDecision
}
```

`decide`, in order (fail closed at every step after 1):

1. No opener, or the item is an app → `.defaultApp`.
2. `applicationURL(forBundleIdentifier:)` is `nil` → `.defaultApp` (the app was removed; §2.9).
3. The URL must be an app bundle (`FileLocation.isAppBundlePath`, `Model/FileLocation.swift:61`)
   whose bundle identifier is the opener's.
4. Not `FileItemPolicy.refusesHandler` and not a runner — except a folder terminal for a folder
   when allowed (§5.4).
5. Listed by `applicationURLs(toOpen: target)` for the item's checked location (`target` is what
   `GroupLauncher.check` resolved, or the website's URL) — except the allowed folder terminal, which
   macOS doesn't list for folders (checked on this Mac at `b32f6af`: Terminal declares
   `public.directory` as an editor but `urlsForApplications(toOpen:)` doesn't return it).
6. → `.openWith(url)`.

**Where it runs.** `GroupLauncher.open` and `openAll` call `check` first (unchanged, A+F §2.3): a
refused or missing item never reaches the opener check. Websites are checked as today
(`WebsiteAddress`). Then `decide`; `.openWith` goes to a new `ApplicationWorkspace` method,
`open(_ urls: [URL], withApplicationAt: URL) async throws` (the same `NSWorkspace.open` call
`openWebsites` and `openFileItems` already make, `ApplicationWorkspace.swift:83-121`), one request
per opener; `.defaultApp` goes through `openFileItems` / `openWebsites` as today; `.refused` becomes
`.failed(reason: core.launch.opener.refused)` without calling the workspace.

**Delays.** `openAll(_:)` opens the items without a delay as today and hands the others to
`DelayedLaunches` (Core, `@MainActor`), which keeps one `Task` per delay value per group:

```swift
@MainActor public protocol Sleeping { func sleep(for duration: Duration) async throws }  // Task.sleep; a fake in tests
@MainActor public final class DelayedLaunches {
    public func schedule(_ items: [GroupItem], of group: DockGroup.ID, after seconds: Int,
                         open: @escaping ([GroupItem]) async -> LaunchReport)
    public func cancel(group: DockGroup.ID)          // Finish, Start of another, Hide All, Close All
    public func cancelAll()                          // app terminates
    public var pending: [DockGroup.ID: Int]          // counts, for the summary
}
```

When a task wakes, it re-reads the group from the store and opens only the items still there with
the same identity and launch options (E-3), through the same `GroupLauncher` path (checks included:
a file deleted during the delay is reported as not found). `LaunchReport.Outcome` gains
`.scheduled(seconds: Int)` (not a problem) so the immediate report and Siri's summary can say "2
more open in a few seconds"; the one exhaustive switch in the app (`LaunchReportPresenter`)
gains a case.

### 3.6 Focus (D)

**Mechanism.** A Focus filter: `GroupFocusFilter: SetFocusFilterIntent` (App Intents, macOS 13+;
the app requires 14). Apple's documentation ("Defining your app's Focus filter") says the system
calls the filter's `perform()` with the configured parameters when the Focus turns on, and with
the default parameters (`nil` for optional ones) when it turns off; `current` returns the active
configuration. No entitlement or permission is involved, and nothing is polled.

```swift
struct GroupFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Start a Group"
    static let description = IntentDescription("Starts, opens or shows a group of Cybokron Dock Groups when this Focus turns on.")
    @Parameter(title: "Group") var group: GroupEntity?
    @Parameter(title: "When This Focus Turns On", default: .start) var action: FocusGroupAction   // AppEnum
    @Parameter(title: "Finish the Group When This Focus Turns Off", default: false) var finishesWhenFocusEnds: Bool
    var displayRepresentation: DisplayRepresentation { /* "Start “Coding”" / "No group" */ }
    @MainActor func perform() async throws -> some IntentResult {
        FocusFilterBridge.receive(FocusRequest(groupID: group?.id, action: .init(action), finishesWhenFocusEnds: finishesWhenFocusEnds))
        return .result()
    }
}
```

Only the main app declares it: standalone groups' apps have no App Intents of their own
(`Agent/AgentAppDelegate.swift:28-33`), so a Focus never reaches them.

**Coordinator** (Core, `@MainActor final class FocusRequestCoordinator`):

- `receive(_ request: FocusRequest)` stores the request as *latest* and (re)starts one settle task of
  1 second (`Sleeping`), so A → B, and off-then-on, collapse into the last state.
- After settling, against the session:
  - group `nil` (Focus off, or a filter without a group): if `session.startedByFocus` is set, says
    `finishesWhenFocusEnds`, and its group is still current → `finish(…, trigger: .focus)`; else
    nothing.
  - a group: if a previous Focus-started group is current, its request said to finish, and it isn't
    this group → finish it first (`afterFinish` ignored); then do the action with `trigger: .focus`
    (Start; or Open All; or Show Popup). The 3-second rule (§2.2) absorbs a Shortcuts automation
    doing the same.
- Requests arriving before the app is ready (`GroupIntentSupport.handler == nil`, store not loaded)
  are kept (the latest only) and done once `AppDelegate.applicationDidFinishLaunching` registers
  the coordinator.
- It never writes anything: Focus pairings are the system's, not part of `groups.json` or backups.

**No loops (D-4).** The app has no API to change a Focus and doesn't run Shortcuts, so nothing it
does can turn a Focus on or off. Only users' automations could chain the two; the 1-second settle
and the 3-second rule make repeated requests idempotent.

**Assumptions to verify in the spike (PR 5 gate, §8 R1):**

- **D-A1** The system launches the menu bar app (`LSUIElement`) to deliver `perform()` when it isn't
  running, without an App Intents extension (the Apple sample uses an extension "for background
  execution"; the app has none and adding one would need an App Group).
- **D-A2** Switching Focus A → B calls `perform()` once with B's parameters, or off then on; the order
  is stable.
- **D-A3** `perform()` is called when a Focus turns on by schedule, by a Shortcut, or from another
  device (Focus sharing across devices).
- **D-A4** `current` works from the main app and reflects the active Focus right after launch.
- **D-A5** Known macOS 26.5 Focus filter bugs (§1.4) don't affect delivery; if they do, the feature
  ships disabled on that version with a note in Settings.
- **D-A6** Standalone groups' apps (copies of the main executable with their own bundle identifiers,
  `Standalone/AgentBundleLayout.swift`) don't show up as a second Cybokron Dock Groups filter in
  System Settings.

**Settings link.** "Open Focus Settings…" opens `x-apple.systempreferences:com.apple.Focus-Settings.extension`
(to verify on 14, 15 and 26, like the Accessibility link, `Support/AccessibilityAccess.swift:13`).

### 3.7 Global shortcuts (I6) and Start and Finish

No new hot keys in this wave. Reasons, from the registrar (`Shortcuts/GroupHotKeys.swift:97-113`):

- The 18 hot keys are registered **all or none**; one failure switches every shortcut to event
  monitors, which need Accessibility access (I6's whole point was to avoid that). A second set (for
  example ⇧ plus the modifiers plus a digit to Start) doubles the chances of a failure.
- With shift added, two modifier sets collide with system shortcuts: ⌃⌘⇧3 and ⌃⌘⇧4 copy screenshots
  to the clipboard, for `controlCommand` (`Shortcuts/GroupShortcuts.swift:7`). Hot keys aren't
  exclusive, so a collision may not fail registration and both would fire.
- Per-group, assignable shortcuts (research G) are the place for Start keys, with per-key failure
  handling. This spec leaves `GroupHotKeyRegistrar` unchanged, and notes for G: Start keys must be
  separate registrations whose failure doesn't fall back for the popup keys.

### 3.8 Siri, Shortcuts and the I8 confirmation bridge

- `StartGroupIntent` and `FinishGroupIntent` live in `Intents/SwitchingIntents.swift`, built like
  `QuitGroupIntent`. The confirmation helper (`confirmQuitting`, `MacOS14Confirming`,
  `Intents/GroupIntents.swift:79-109`) moves to a shared `IntentConfirmation` so the three intents
  ask the same way: `requestConfirmation(actionName:dialog:)` on macOS 15+, the deprecated call on
  14, destructive only for force quitting (which these intents never do).
- `GroupIntentHandling` (`Intents/GroupIntentSupport.swift:6-16`) gains
  `start(_:confirm:)` and `finish(_:confirm:)`, implemented by the app delegate through
  `ContextSwitcher` with `trigger: .intent`.
- **Verification (PR 3, manual):** on macOS 14 and 15, Start Group with a quitting setting asks in
  Siri and in the Shortcuts app; declining quits nothing and hides nothing (the plan isn't carried
  out); a hiding setting doesn't ask. In a Shortcuts **automation** (no one there to answer), a
  quitting transition may stall or fail: the result is documented in the PR and in the README
  ("use a hiding setting for automations").

### 3.9 Data schema and compatibility

Keys are added, never renamed; every new value is written only when it differs from its default,
and decoded leniently on its own (A+F §1.8). Format versions stay at **1** (`GroupsDocument`,
`SettingsBackup.currentSchemaVersion`, `PreferencesDocument`, `AgentConfiguration`).

```jsonc
// a group with non-default Start and Finish settings (key "switching", omitted when default)
{ "id": "…", "name": "Coding", "emoji": "💻", "apps": [ … ],
  "switching": { "onStart": "quitPreviousGroup", "onFinish": "hideApps", "afterFinish": "nothing" } }
// a folder opened with VS Code three seconds after Open All or Start
{ "bundleIdentifier": "file:///Users/me/Projects/cybokron/", "kind": "folder", "name": "cybokron",
  "launchDelay": 3, "openWith": { "bundleIdentifier": "com.microsoft.VSCode", "name": "Visual Studio Code" } }
// an app that opens five seconds later (apps have no "openWith")
{ "bundleIdentifier": "com.tinyspeck.slackmacgap", "name": "Slack", "launchDelay": 5 }
// preferences.json
{ "formatVersion": 1, …, "protectedApps": [ { "bundleIdentifier": "com.apple.Music", "name": "Music" } ] }
```

Decoding rules:

| Saved | Result |
| --- | --- |
| no `switching`, or unreadable | defaults |
| `switching` with an unknown or unreadable field | that field's default, others kept |
| `launchDelay` not an integer | 0; out of range → clamped to 0…60 |
| `openWith` on an app item | dropped |
| `openWith` with an empty or malformed bundle identifier (not 1…255 of `[A-Za-z0-9.-]`) | dropped |
| `openWith` without `name` | the bundle identifier is shown as its name |
| `protectedApps` with non-app items, duplicates or more than 50 | only apps, deduped, first 50 |

**Older versions reading this version's files (E-6):**

| Data | 0.7.0 and earlier | User-visible result there |
| --- | --- | --- |
| `switching` | unknown group key, ignored (`DockGroup.swift:104-124`) | no Start or Finish there; nothing happens |
| `launchDelay`, `openWith` | unknown item keys, ignored (`AppReference.swift:153-226`) | items open right away with their default apps |
| `protectedApps` | unknown preference key, ignored (`PopupPreferences.swift:146-197`) | Close All quits every running app of the group again |
| **any save there** | writes without the new keys | Start and Finish settings, launch options and **protected apps are lost** |

The last row is a safety regression, not only a data loss: after going back and up again, apps the
user protected aren't protected any more. So `DowngradeProtection` (`Updates/DowngradeProtection.swift`)
grows in PR 6: `ReleaseHistory.firstContextSwitchingVersion` (the version shipping PR 3), a
`pre-downgrade` copy of **`preferences.json`** too (today only `groups.json` is copied), and the
install question warns when groups have Start or Finish settings or launch options, or the
protected list isn't empty (§4.6).

**Backups.** Groups carry `switching` and launch options; preferences carry `protectedApps` (a backup's
`preferences` are `preferences.json`'s content, `Persistence/SettingsBackup.swift`). Import
(`sanitizedForImport`) also:

1. drops an `openWith` whose bundle identifier is refused (`FileItemPolicy.refusesHandler`) or a
   runner, **including the folder terminals** (they're accepted only when set on this Mac, §5.4);
2. keeps other openers: they're checked again at every launch (§3.5), as every item is;
3. counts the items whose launch options were reset in a new, non-encoded
   `SettingsBackup.resetLaunchOptionCount`, shown in the import confirmation (§4.6).

**Agents.** `AgentConfiguration.init` (`Standalone/AgentConfiguration.swift:17-25`) normalizes the
snapshot so unrelated edits don't rebuild agents: the group's `switching` is reset to the default
(agents don't start or finish), and `protectedApps` is reduced to the protected apps that are in
that group (Close All only needs those). Launch options stay: the agent's Open All applies them.

### 3.10 Settings and windows

- **Settings:** a new pane, **Switching**, after Shortcuts & Siri in `SettingsPane`
  (`Settings/SettingsWindowController.swift:107-114`), symbol `arrow.left.arrow.right.square`. It
  holds Protected Apps and Focus (§4.4). Per-group settings don't go there: like every other group
  setting, they're in the group window (A+F §0.5).
- **Group window:** a new section, **Start and Finish**, between Items and Dock Tile
  (`MainWindow/GroupDetailView.swift:78-82`), with the three pickers and a Start button (§4.3).
- **Item editor:** the details editor (`MainWindow/ItemDetailsEditor.swift`) gains an **Opening**
  part below Task Notes; `ItemDetailsDraft` gains the launch fields, and `GroupStore.saveDetails`
  becomes `saveItemEdits(_:)`, still one save and one agent rebuild per Done (A+F §4.2 B).
- **Store:** `GroupStore.updateLaunchOptions(_:ofItem:inGroup:) -> Bool` (no save when unchanged),
  `relinkItem` and moves keep launch options, and `updateGroup` covers `switching`. The
  `ContextSession` prunes on `store.$groups`.

### 3.11 Localization plan

Keys follow the A+F rules (A+F §7.1): a key is added with the code that looks it up, each PR adds
its prefixes to `awaitingTranslation`, `docs/l10n-keys.md` gets a section per prefix marked "English
only for now", and a final PR translates them into the 25 languages (as `66f3ef8` did for A+F).
Estimated new keys:

| Prefix | Where | About |
| --- | --- | --- |
| `core.switching.` | transition questions, buttons, kept-app notes, opener refusal, delayed notes | 16 |
| `core.invocation.startGroup` / `finishGroup` (+ `.phrase`), link titles | Settings → Shortcuts & Siri | 6 |
| `switching.` | Settings → Switching (protected apps, Focus) | 16 |
| `groupWindow.switching.` | Start and Finish section | 16 |
| `item.launch.` | editor's Opening part, row captions, popup help | 14 |
| `popup.switching.` | Start/Finish button, "current" marker, help | 7 |
| `menuBar.switching.` | current group line, Finish, ⌃⌥ alternate | 5 |
| `settings.backup.launchReset.` | import confirmation | 2 |
| `updates.otherVersions.switching.` | downgrade warning | 1 |

About **83 keys** (551 → about 634). App Intents texts (intent titles, parameter names, phrases, the
Focus filter's fields) stay English literals, as the existing intents' do; they're not in
`Localizable.strings`. The Siri phrases listed in Settings (`core.invocation.*.phrase`) must match
the App Shortcuts phrases, in English, as today (`docs/l10n-keys.md`, introduction).

---

## 4. UX sketches

### 4.1 Popup

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ 💻 Coding                       [■ Finish] [Open All] [Hide All] [Close All] │
│    8 items · 3 running · current                                             │
├──────────────────────────────────────────────────────────────────────────────┤
│  (grid)                                                                      │
├──────────────────────────────────────────────────────────────────────────────┤
│ Type to filter · ↩ opens the selected item · Tab: next group     [A→Z] [⚙]  │
└──────────────────────────────────────────────────────────────────────────────┘
```

- A group that isn't current shows **[▶ Start]** in that place; the current one **[■ Finish]**.
- Help: "Start: open this group's items and hide the apps of “Design”." (it names what the setting
  does, including "and quit the apps of “Design” it doesn't use"); "Finish: hide this group's apps
  and show “Design” again."
- In narrow popups (fixed columns of 1 to 3) the button shows only its symbol, with the same help and
  VoiceOver label ("Start Coding").
- The Most Used popup and standalone groups' popups have no Start or Finish button.
- Item cells: an item with launch options adds them to its help: "Open cybokron with Visual Studio
  Code. Open All and Start open it after 3 seconds."

### 4.2 Menu bar menu

```
  Current: 💻 Coding
    Finish “Coding”
  ─────────────
  💻 Coding                    8        (⌥: Open All in “Coding”, ⇧⌥: Hide All, ⌃⌥: Start “Coding”)
  🎨 Design                    5
  ─────────────
  Most Used ▸ …
```

- The "Current" line and Finish appear only while a group is current.
- ⌃⌥ is a third alternate of each group item, next to the existing ⌥ and ⇧⌥ ones
  (`MenuBar/StatusBarController.swift:155-184`).

### 4.3 Group window

```
Start and Finish
  When this group starts   [Hide the previous group's apps        ▾]
                            Leave other apps open
                            Hide the previous group's apps
                            Hide all other apps
                            Quit the previous group's apps
  When this group finishes [Hide its apps ▾]   (Hide its apps / Quit its apps / Leave its apps open)
  After finishing          [Show the previous group ▾]   (Show the previous group / Do nothing)
  Protected apps, and apps both groups use, are never hidden or quit.  [Protected Apps…]  [▶ Start]
  ⚠ Quitting asks apps to quit; they can still ask to save changes. A Focus never quits apps.
```

"Protected Apps…" opens Settings on the Switching pane. The ⚠ line shows only when a quitting
setting is chosen.

Item rows show launch options under the location:

```
 [📁] cybokron                         ~/Projects/cybokron                     (ⓘ) (⊖)
      Opens with Visual Studio Code · after 3 s
 [📄] Report.pdf                       ~/Documents/Report.pdf                  (ⓘ) (⊖)
      Opens with Preview (not on this Mac: uses the default app)
 [▣] Slack                             com.tinyspeck.slackmacgap               (ⓘ) (⊖)
      After 5 s
```

Item editor (popover from ⓘ, as in 0.7.0), new part at the bottom:

```
 Details of “cybokron”
 Alias        [                                  ]
 Tags         [ work, cybokron                   ]
 Task notes   [                                  ]
 ──────────────
 Opening
 Open with    [Visual Studio Code ▾]   Default App (Finder) / Visual Studio Code / Zed / … / Other…
 Delay        [3 seconds ▾]            None / 1 / 2 / 3 / 5 / 10 / 15 / 30 / 60 seconds
              Open All and Start wait this long; clicking the item opens it right away.
                                                        [Cancel]  [Done]
```

Apps show only Delay. The "Open with" menu lists the default app first, then the apps macOS lists
for the item (§3.5), sorted by name, then "Other…".

### 4.4 Settings → Switching

```
Protected Apps
  ┌────────────────────────────────────────────┐
  │ ♪ Music                                (⊖) │
  │ ☏ FaceTime                             (⊖) │
  └────────────────────────────────────────────┘
  [Add Apps…] [Add a Running App ▾]
  Start, Finish and Close All never quit these apps, and switching groups never hides them.
  Cybokron Dock Groups and its groups' own apps are always protected, and Finder is never quit.

Focus
  A Focus can start a group when it turns on. In System Settings → Focus, choose a Focus,
  then Add Filter → Cybokron Dock Groups, and pick the group.
  [Open Focus Settings…]
  Now: the current Focus starts “Coding”.            (or: No Focus asks for a group right now.)
  A Focus only hides apps; it never quits them.
```

### 4.5 Flow: a day with two Focuses

```
Work Focus filter:     Coding · Start · finish when the Focus turns off
Personal Focus filter: Home · Start · (no finish)

09:00  Work Focus on ──perform(Coding, .start, finish)──▶ settle 1 s ──▶ Start Coding (trigger: focus)
         Design was current: hide Figma, Sketch · open Xcode, cybokron (in VS Code); Slack after 5 s
13:00  Personal Focus on ──perform(Home, .start)──▶ settle 1 s ──▶ Coding is current and its
         request said "finish" → Finish Coding (hide; a pending Slack is cancelled) → Start Home
18:00  Personal Focus off ──perform(nil)──▶ Home's request said nothing about finishing → nothing
```

### 4.6 Alerts and confirmations

- **Transition questions:** §2.5.
- **Delayed problems:** "Some items in “Coding” couldn't be opened" with "• Slack: not found on this
  Mac." (the existing texts), shown once when the last delayed item of that command fired.
- **Opener refused:** "• Notes.txt: wasn't opened with “Terminal”, because that app can't open it
  safely."
- **Backup import:** "The backup has 3 groups with 14 items. The launch settings of 1 item were
  reset: they named an app that runs files."
- **Downgrade:** "Version 0.7.0 can't keep Start and Finish settings, launch options or protected
  apps. Copies of your groups and settings are kept before it's installed; editing groups or
  settings in that version drops these settings, and Close All there quits protected apps too."

---

## 5. Security and privacy

### 5.1 Threat model, as it stands

`SECURITY.md` ("Scope") names a crafted `groups.json` or `.dockgroups` backup making the app
launch unintended apps or run code. 0.7.0 closed that for file items (A+F F1-6): a file or folder is
checked every time before it's opened, whatever its source, and an app item starts only from an app
bundle (`GroupLauncher.swift:175-234`, `CHANGELOG.md` 0.7.0 "Fixed"). A backup is the realistic
vector (anyone can hand one over); `groups.json` needs a write into the user's Library, which already
allows worse, but it's treated the same as defense in depth. **E must not reopen that hole; C and
D must not add a way to destroy work.**

### 5.2 New surfaces

| Surface | Code execution risk | Data-loss risk | Answer |
| --- | --- | --- | --- |
| `openWith` | **yes**, if the opener runs what it opens (a terminal asked to open a file may run it) | — | §5.3 |
| `launchDelay` | none (it only waits) | a delayed launch after the user moved on | cancelled (E-3) |
| `switching` quit settings | none | quitting apps with unsaved work | graceful only, opt-in, asks for links and Siri, never for Focus (C-3) |
| `switching` hide settings | none | none (reversible) | — |
| `protectedApps` | none (it only prevents) | a backup restored with Replace All replaces the list, as it replaces every setting (Merge keeps the current settings) | the import confirmation already says settings are replaced; the downgrade copy (§3.9) |
| Focus filter parameters | none (a group ID and an action, stored by macOS) | none: never quits | — |
| `start/`, `finish/` links | none | quitting by a web page | shares the link cooldown; asks before quitting |

### 5.3 Invariants for launch options

- **L-1** Launch options add no new kind of thing that runs: no arguments, environment, commands,
  scripts or URL schemes beyond today's (http and https websites). `ItemLaunchOptions` has exactly
  two fields, and E's second phase (research §1.3) is a separate design with its own review.
- **L-2** The item is checked exactly as in 0.7.0 **before** the opener is considered (`check`,
  `GroupLauncher.swift:215`): a refused item stays refused whatever the opener.
- **L-3** The opener is an app resolved **by bundle identifier through LaunchServices at launch
  time**; no location is ever stored or read, so data can't point it at a program somewhere on disk.
- **L-4** The opener must be an app bundle macOS lists for the checked item, and not a refused
  default app (`FileItemPolicy.swift:74`) or a runner (`ItemOpenerPolicy.runnerBundleIdentifiers`:
  the refused default apps plus Warp `dev.warp.Warp-Stable`, Ghostty `com.mitchellh.ghostty`, kitty
  `net.kovidgoyal.kitty`, Alacritty `org.alacritty`, WezTerm `com.github.wez.wezterm`, Hyper
  `co.zeit.hyper`, Python Launcher `org.python.PythonLauncher`, Automator Application Stub
  `com.apple.Automator.Automator-Application-Stub`, Script Editor applets `com.apple.ScriptEditor.id.*`
  by prefix). Two layers: macOS's list keeps Terminal away from text files (Terminal declares only
  its own types, shell scripts, executables and directories — checked at `b32f6af`), the runner list
  keeps terminals away from files they do declare.
- **L-5** Every refusal fails closed: the item isn't opened with its default app instead, because a
  refused opener means the data is wrong or crafted. Only an opener that isn't installed falls back
  to the default app (that's what an older version would do anyway).
- **L-6** The same checks run for every source: the editor, `groups.json`, a backup, a standalone
  group's configuration. Backup import additionally drops runner and refused openers (§3.9).
- **L-7** Logs name the opener by bundle identifier (an app, not the user's data) and the item by
  `logIdentity` (A+F §1.2); failure reasons of file items stay out of the log
  (`GroupLauncher.swift:236-246`).

### 5.4 Residual risks, accepted or left open

- **Droplets.** macOS lists Automator and AppleScript droplets for the types they accept (on this
  Mac, `com.adobe.Automator.Save-as-Adobe-PDF` is listed for PDFs). Opening a file with one runs its
  workflow on the file. That's equivalent to launching that installed app, which an app item in
  crafted data can already do; it isn't a new capability. Accepted.
- **Folders in a terminal (DECISION 5).** Opening a folder in Terminal or iTerm2 starts the
  user's shell there; shell hooks that run on entering a folder (autoenv-style `.env` sourcing)
  could run code a crafted folder ships. Hence, allowed with limits: folders only, those two apps only, never
  from a backup (import drops them), and the folder must pass the 0.7.0 checks. A crafted
  `groups.json` could still set it; that needs a write into the user's Library, where a
  LaunchAgent would do more harm. Decided: allow, with these limits.
- **Considered and rejected: sealing launch options** with an HMAC whose key is in the Keychain, so a
  `groups.json` edited outside the app would lose them. Standalone groups' apps are signed ad hoc
  and would need Keychain access prompts, a reinstall loses the key, and the threat (a write into
  the user's Library) already allows more than it would stop.

### 5.5 Privacy

Nothing leaves the Mac. Focus pairings are stored by macOS; the app only receives a group ID and an
action. The diagnostics report (`Diagnostics/DiagnosticsReport.swift`) adds counts only: "2 groups
with Start and Finish settings, 3 items with launch options, 4 protected apps, a current group:
yes" — no names, bundle identifiers or Focus names.

---

## 6. Performance

- **Transitions.** One `runningApplications` snapshot per transition; planning is O(running apps ×
  group items) over a few dozen of each; hiding and quitting are one call per app on the main
  thread. Open All is unchanged.
- **Focus.** Event-driven: the system calls `perform()`; the coordinator keeps one settle `Task`
  (cancelled and replaced by each new call) and no timer otherwise. Nothing polls Focus state; the
  Settings line reads `current` when the pane appears.
- **Delays.** At most one `Task` per distinct delay value per group (nine values), sleeping with
  `Task.sleep`; cancellation is immediate. Tests use a fake `Sleeping`, so they don't wait.
- **UI.** `ContextSession.current` is published; the popup header and the menu read it when they
  build (the menu is rebuilt when it opens, `MenuBar/StatusBarController.swift:65-73`). The popup's
  build cost (A+F §3.3) doesn't change.
- **LaunchServices.** The editor asks for the apps that open an item once when its "Open with" menu
  opens; Open All asks once per item that has an opener. Rows never ask while drawing (A+F §2.4):
  "not on this Mac" comes from the group window's existing presence refresh, extended with one
  bundle-identifier lookup per opener.
- **Agents.** The snapshot normalization (§3.9) keeps protected-app and Start/Finish edits from
  rebuilding standalone groups' apps; launch-option edits rebuild only that group's app, once per
  Done.

---

## 7. Test plan (`Tests/DockGroupsCoreTests`, swift-testing, no real Dock, LaunchServices or Focus)

Suites are named as today ("Group items: actions" → "Switching: …"), `@MainActor` where the code is,
with fakes in a shared `SwitchingFakes.swift` (as `ItemInterfaceFakes.swift`).

- **`SwitchingModelTests`**: `GroupSwitching` defaults, coding, lenient fields, "written only when not
  default"; `ProtectedApps` (apps only, dedupe, 50 cap, implicit protections); `PopupPreferences`
  with `protectedApps`; 0.7.0 fixtures of `groups.json`, `preferences.json`, an agent configuration
  and a backup, generated by building `b32f6af`'s Core (as `Version067Fixtures`), decode to the
  same values and re-encode **byte for byte**.
- **`TransitionPlannerTests`** (the core of C): the matrix of `OnStart` × previous group (none,
  disjoint, overlapping) × running state; shared apps never hidden or quit; protected and implicit
  apps never; Finder hidden only by "all other apps" and never quit; `trigger: .focus` never quits;
  `hidingInsteadOfQuitting`; already-hidden apps not hidden again; order follows the group; Finish
  with and without a next group; un-hiding only what's hidden.
- **`ContextSessionTests`**: start, finish, history order and cap, previous, pruning deleted
  groups, the 3-second rule with an injected clock.
- **`ContextSwitcherTests`**: with a fake listing, fake terminator applications and fake workspace:
  hide before open; the link question asked only when quitting, "Hide Instead" hides, Cancel does
  nothing; an intent's `confirm` throwing does nothing; serialized transitions (a second Start
  waits); delayed items cancelled on Finish and on starting another group; reports and summaries.
- **`GroupTerminatorTests`** (additions): Close All spares protected apps and reports them as kept;
  the agent path (direct `closeAll`) spares them too; Hide All doesn't consult the list.
- **`ItemLaunchOptionsTests`**: coding (flat keys), clamping, opener dropped for apps, malformed
  identifiers dropped, default not written, round trip with details.
- **`ItemOpenerPolicyTests`** with a fake `ApplicationCatalog`: each step of `decide` (§3.5), including
  Terminal for a text file (not listed → refused), Terminal for a folder (allowed only with the
  folder-terminal switch), a refused default app, a runner, a non-bundle URL, a bundle whose
  identifier differs, an uninstalled opener (→ default app).
- **`FileItemLauncherTests`** (additions, the security core of E): a crafted `groups.json` whose items
  name Terminal, iTerm2, Python Launcher and a non-listed app as openers for a `.txt`, a `.command`
  and a folder → nothing reaches `open(_:withApplicationAt:)` except what the rules allow; a refused
  item with an allowed opener stays refused; the opener request batches per app; websites with a
  browser opener.
- **`DelayedLaunchesTests`** with a fake `Sleeping`: firing order, cancellation per group, an item
  removed or changed meanwhile skipped, problems reported once per command, `.scheduled` outcomes.
- **`SettingsBackupTests`** (additions): round trip of `switching`, launch options and protected
  apps; import drops runner and refused openers and counts `resetLaunchOptionCount`; folder
  terminals dropped on import.
- **`AgentModelTests` / `AgentPlannerTests`** (additions): the snapshot resets `switching` and reduces
  `protectedApps` to the group's apps; editing an unrelated protected app or a group's Start setting
  doesn't make the agent `outdated`; a launch-option edit does.
- **`FocusRequestCoordinatorTests`** with a fake `Sleeping` and a fake switcher: settle collapses A → B
  and off-then-on; Focus off finishes only a Focus-started current group whose request said so;
  A → B finishes A only when A asked; pending until ready; repeated requests within 3 seconds once;
  a deleted group does nothing; `.openAll` and `.showPopup` actions.
- **`URLCommandTests`** (additions): `start/`, `switch/`, `finish/` parse; they share the group-apps
  cooldown; throttle keys.
- **`GroupInvocationsTests`**, **`LocalizationTests`** (prefixes only), **`DowngradeProtectionTests`**
  (copies `preferences.json`; warns for each new setting), **`DiagnosticsReportTests`** (counts, no
  names).
- **Manual (each UI PR, recorded in the PR):** hiding and showing with full-screen apps, Stage
  Manager and several displays; Start and Finish from a link (question, Hide Instead, cooldown);
  Siri and Shortcuts on macOS 14 and 15 (I8 bridge, §3.8); "Open with" for a folder in VS Code and
  Terminal (folders); the Focus spike (§3.6) on 14, 15 and 26; a downgrade to 0.7.0 with every new
  setting in use.

---

## 8. Risks and unknowns

| # | Risk or unknown | Effect | Mitigation |
| --- | --- | --- | --- |
| R1 | Focus filter delivery to a non-extension, `LSUIElement` app (D-A1…D-A6); reported Focus filter bugs on macOS 26.5 | D doesn't work, or works only while the app runs | PR 5 starts with a spike on 14, 15 and 26; if D-A1 fails, Settings says "works while Cybokron Dock Groups is running"; if delivery is unreliable, D waits and ships in a later release (DECISION 1) |
| R2 | The final proposal dropped Focus integration (§1.4) | product disagreement | D is the last feature PR (PR 5; PRs 6 and 7 are safety and translation) and independent of C and E; the user decided to include it (DECISION 1) |
| R3 | `hide()` on full-screen apps, apps on other Spaces, Stage Manager | "hide others" looks partial | manual tests; the report lists apps that couldn't be hidden, as Hide All does |
| R4 | Siri confirmation in Shortcuts automations (nobody answers) | a quitting Start stalls or fails | documented; README recommends hiding settings for automations |
| R5 | Users confuse Start with Open All | surprise hiding | Start is a separate, labelled button with help that says what it hides; Open All unchanged |
| R6 | "Previous group" only knows Starts, not Open All or clicks | Finish shows a group the user didn't expect | the help text names the group; "After finishing: Do nothing" exists |
| R7 | Downgrade loses protected apps (safety regression) | Close All in the older version quits them | `preferences.json` copy and warning (§3.9), PR 6 ships with PR 3 |
| R8 | macOS's "apps that open this" list misses apps users want (some IDEs for folders, Terminal) | the editor doesn't offer them | "Other…" is checked by the same rules and says why an app was refused; folder terminals are allowed (DECISION 5) |
| R9 | Delays and Siri's Launch Group | Siri reports before delayed items open | `.scheduled` outcomes in the summary ("2 more open in a few seconds") |
| R10 | Quitting apps with unsaved documents | data loss | graceful quit only; opt-in; asked for links and Siri; Focus never quits |
| R11 | Standalone groups' apps don't Start or Finish (DECISION 8) | inconsistency between surfaces | the agent's ⌥-click stays Open All; a later PR can forward to the main app |
| R12 | Session forgotten at relaunch (DECISION 6) | Finish after an update has no previous group | documented; persisting is a small follow-up if wanted |

---

## 9. Phased implementation plan (PR order)

The first PR is **PR 1**: the transition rules are the riskiest part for users (C-3, C-4), they're
Core-only and fully testable, and they fix the data format before any UI can write it. There are
**7 PRs**, plus an optional refactor; each one keeps `scripts/test.sh` green and runs `xcodegen
generate` when files are added (`AGENTS.md`).

| PR | Title (Conventional Commits) | Scope | Acceptance criteria |
| --- | --- | --- | --- |
| **1** | `feat(core): start and finish groups` | `GroupSwitching`, `ProtectedApps` + coding (§3.9); `RunningAppSnapshot`, `RunningApplicationsListing`, `TransitionPlanner`, `ContextSession`, `ContextSwitcher`, `TransitionConfirmation`, `TransitionReport`; `GroupTerminator` protection, `hide`/`quit`/`unhide`, `QuitReport.kept`; `AgentConfiguration` normalization; `start/`, `switch/`, `finish/` in `URLCommand`. Keys: `core.switching.` (questions, kept-app notes). | All existing tests pass unchanged; 0.7.0 fixtures are byte-identical; §7 model, planner, session, switcher, terminator, agent and URL tests pass; no UI change (nothing writes the new keys yet). |
| **2** | `feat(core): launch options for group items` | `ItemLaunchOptions`, `ItemOpener` + coding; `ApplicationCatalog` + system implementation; `ItemOpenerPolicy`; `ApplicationWorkspace.open(_:withApplicationAt:)`; `GroupLauncher` openers and delays; `DelayedLaunches` with `Sleeping`; `LaunchReport.Outcome.scheduled`; summaries; backup import rules and `resetLaunchOptionCount`. Keys: the rest of `core.switching.` (opener refusal, delayed notes). | §7 launch-option, opener, launcher-security and delayed tests pass; a crafted `groups.json` and backup reach `open(_:withApplicationAt:)` only as §5.3 allows; no UI change. |
| **3** | `feat: start and finish groups from the popup, menus, links and Siri` | App wiring of `ContextSwitcher` (`AppDelegate`), popup Start/Finish button and "current" marker, menu bar current line, Finish and ⌃⌥ alternates, group window "Start and Finish" section, Settings → Switching pane with Protected Apps, Start and Finish Group intents and phrases (shared `IntentConfirmation`), Settings → Shortcuts & Siri listing, link question alert; README (features, links table), SECURITY.md scope line, CHANGELOG. Keys: `switching.` (protected part), `groupWindow.switching.`, `popup.switching.`, `menuBar.switching.`, `core.invocation.startGroup`/`finishGroup`. | Manual: transitions with full-screen apps and Stage Manager; links ask before quitting and "Hide Instead" works; Siri asks on 14 and 15, recorded in the PR; Close All spares protected apps in the main app and an agent; `docs/l10n-keys.md` updated. **Must not be released without PR 6.** |
| **4** | `feat: choose the app that opens an item, and a launch delay` | Item editor "Opening" part (`ItemDetailsDraft` launch fields, `saveItemEdits`), "Open with" menu from `ApplicationCatalog`, "Other…" checked by the same rules, row captions and popup help, folder terminals (Terminal and iTerm2, folder items only; DECISION 5), backup confirmation text. Keys: `item.launch.`, `settings.backup.launchReset.`. | One Done gives one save and at most one agent rebuild; an uninstalled opener shows "not on this Mac" and opens with the default app; a refused opener is explained in the editor and refused at launch; delays cancelled by Finish (manual). **Must not be released without PR 6.** |
| **5** | `feat: start a group when a Focus turns on` | Spike first (D-A1…D-A6, results in the PR); `GroupFocusFilter`, `FocusGroupAction`, `FocusFilterBridge`, `FocusRequestCoordinator`; Settings → Switching → Focus with "Open Focus Settings…" and the current state; README recipe (Focus filter, and Shortcuts automations as an alternative). Keys: `switching.` (Focus part). | Spike passes on 14 and 15 (26 recorded); §7 coordinator tests pass; Focus-started transitions never quit; repeated triggers act once (manual, with a Shortcuts automation doing the same). |
| **6** | `feat: keep copies of the groups and settings before installing a version without switching` | `ReleaseHistory.firstContextSwitchingVersion`, `DowngradeProtection` copying `preferences.json` too and warning for Start/Finish settings, launch options and protected apps. Keys: `updates.otherVersions.switching.`. | Installing 0.7.0 from Other Versions… (dry run) creates `groups.pre-downgrade-*.json` and `preferences.pre-downgrade-*.json` and shows the warning only when a new setting is used; the manual downgrade table (§3.9) is verified. Ships with PR 3. |
| **7** | `feat: translate context switching keys to all languages` | The new prefixes in the 25 translations; `awaitingTranslation` back to `[]`; `docs/l10n-keys.md` labels. | `LocalizationTests` green with no awaiting prefixes. |
| 8 *(optional)* | `refactor: share group actions between the app and its agents` | A+F's R2 (`GroupActionPerformer`), now also owning the `ContextSwitcher` wiring. | No user-visible change; Close All's two paths (D1) explicit and tested. |

Releases: PRs 1 and 2 can ship in any release (nothing visible, nothing new written). PRs 3, 4 and 6
ship **together**, as 0.8.0 (they write data older versions drop). PR 5 (Focus, last, in this wave) follows in the same or
the next release, only if its spike passes; otherwise it waits (DECISION 1). PR 7 can be in the release with 3, 4 and 6 or the next. Each
release bumps the version and build number together (`AGENTS.md`, `scripts/check-version.sh`).

---

## DECISIONS

Recorded 2026-10-24. "User-decided" means the user answered explicitly; "default kept" means the
recommendation of this spec stands because the user asked for nothing else.

1. **Focus (D).** **Decision (2026-10-24):** D is in this wave, as the last feature PR (PR 5), and ships only
   if the delivery spike passes (user-decided). Reason: Focus is the one trigger Siri and Shortcuts
   can't replace cleanly, and the spike bounds the risk.
2. **What Start does to other apps.** **Decision (2026-10-24):** Start hides the previous group's
   apps and doesn't quit them (user-decided). Reason: hiding is reversible and keeps unsaved work
   safe, while "hide all others" or "leave everything" would surprise more.
3. **Finishing when a Focus ends.** **Decision (2026-10-24):** "Finish the group when this Focus turns
   off" is off by default (default kept from recommendations). Reason: a Focus ending shouldn't hide
   work by surprise.
4. **Protected apps and explicit Close All.** **Decision (2026-10-24):** Close All pressed by hand
   (popup, menus, `quit/` links, Quit Group) also leaves protected apps alone (user-decided).
   Reason: one rule for every quit path is easier to trust than a list only some commands honor.
5. **Folders in a terminal.** **Decision (2026-10-24):** "Open with" offers Terminal and iTerm2 for
   folder items only, and import from a backup drops them (user-decided, as recommended in §5.4).
   Reason: it's a common need, and the limits keep a crafted folder from running code.
6. **Remembering the current group.** **Decision (2026-10-24):** the current group and history are
   forgotten when the app quits (default kept from recommendations). Reason: it's the simplest
   behavior and nothing surprising happens after an update.
7. **The delay steps.** **Decision (2026-10-24):** 0–60 seconds in nine steps, applied only by Open
   All and Start (default kept from recommendations). Reason: it covers spreading launch load without
   delaying direct clicks.
8. **Standalone groups' own apps.** **Decision (2026-10-24):** they don't offer Start or Finish
   (default kept from recommendations). Reason: agents stay self-contained and know nothing of the
   current group.
