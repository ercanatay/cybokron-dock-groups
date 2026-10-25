# Design spec: capturing open apps into groups

- **Status:** draft for review (2026-10-25). Design only: no code. Decisions are recorded in
  DECISIONS (§9), all taken by the user on 2026-10-25.
- **Baseline:** `main` at `2ea08df` (version 0.9.0, `project.yml` `MARKETING_VERSION: "0.9.0"`),
  1051 `@Test` functions, 792 `en.lproj` keys, `LocalizationTests.awaitingTranslation` empty.
- **Feature:** phase 4a, **Capture**: make a group from the apps that are open now, or add them to
  a group. Target: **0.10.0** on its own (Decision 7). Triggers (time, display, network) are phase 4b
  and out of this spec, shipped in a later release.
- **Builds on:** `docs/design/group-items-and-tags-spec.md` (A+F, 0.7.0),
  `docs/design/context-switching-spec.md` (C+D+E, 0.8.0) and
  `docs/design/group-shortcuts-and-templates-spec.md` (G+I, 0.9.0). Their Core/App split, lenient
  JSON rules, item gates, agent snapshot normalization, link gate and PR format are reused.
- **Clean room:** behavior comes from the written acceptance criteria and this repository only.
  Claims about current code cite `file:line` at `2ea08df` (paths relative to `Sources/` unless they
  start with `Tests/`, `docs/` or name a file at the repository root).

## Acceptance criteria (behavior)

- **CP-1** **New Group from Open Apps…** lists the apps that are open now, lets the user choose
  which ones and name the group, and makes the group in one step. Nothing is opened, hidden or quit.
- **CP-2** **Add Open Apps…** does the same for an existing group: apps already in it are shown as
  such and can't be chosen again; the chosen ones are added at the end, in the order shown.
- **CP-3** Only apps a user would put in a group are listed: regular apps (a Dock icon, a menu bar),
  one entry per app, never background agents, menu bar extras, Finder, Cybokron Dock Groups itself
  or a standalone group's own app. An app that can't be kept as an app bundle isn't listed, and the
  sheet says how many weren't.
- **CP-4** The list is ordered **most recently used first** (the default) or **by name**; an option
  selects only the apps with an open window. Both choices are remembered.
- **CP-5** Capture is offered in the menu bar menu, the group window (sidebar **+** menu and a
  group's **Add** menu), an empty group's popup, a link, and Siri and the Shortcuts app.
- **CP-6** Capture needs no permission: no Accessibility, Screen Recording or Automation access,
  and no prompt, ever. Window information only changes which apps start selected.
- **CP-7** A captured item is an ordinary app item, exactly as Add Apps… makes it; groups made by
  capture are ordinary groups. Version 0.9.0 reads everything 0.10.0 writes without errors.
- **CP-8** Nothing read from `groups.json`, `preferences.json` or a backup makes capture add, open
  or run anything.

Non-goals (this wave): triggers that capture or switch on their own (phase 4b); capturing windows,
tabs, documents or Finder folders; restoring window positions; capturing into a template;
capturing from a standalone group's own app; a global keyboard shortcut for capture; editing the
order inside the sheet.

---

## 0. Summary and scope

### 0.1 Summary

Making a group today means picking apps one by one in an open panel (`GroupDetailView.swift:614-636`).
Capture turns "what I have open right now" into a group, with one review step. Three decisions carry
most of the weight:

1. **A frozen snapshot, planned in Core.** The running apps, the window list and the activation
   history are read once, at the moment the user asks, *before* the app comes to the front (§2.6),
   into plain values. A pure `CapturePlanner` turns them into an ordered, filtered, de-duplicated
   `CapturePlan` (§2.4); the sheet works on that plan, and changing the order or the window option
   re-plans the same snapshot. Everything that decides what is listed is testable without
   NSWorkspace.
2. **Permission-free by construction.** Capture reads `NSWorkspace.runningApplications` and, for
   windows, only the owner, layer, bounds, alpha and on-screen fields of
   `CGWindowListCopyWindowInfo`, which need no permission and never prompt (the app already relies
   on that, `CybokronDockGroups/Support/AccessibilityAccess.swift:54-64`). Window names (Screen
   Recording) and the Accessibility API are never used. Window information only decides the
   default selection, never whether an app is listed, so a wrong guess costs one click (§2.3).
3. **One gate for app items from outside sources.** The rule backups apply to app items today
   (`DockGroupsCore/Persistence/SettingsBackup.swift:203-228`) becomes `AppItemPolicy`, applied by
   the planner and by `GroupStore.addItems` and the new `addGroup(named:items:)` (§2.5). Capture
   writes nothing new to `groups.json`; its two settings live in `preferences.json` under
   `"capture"` and are normalized out of agent configurations, so agents don't change at all.

### 0.2 Scope

| In | Out (and where it would go) |
| --- | --- |
| New Group from Open Apps… with a review sheet (CP-1) | One-click capture without the review sheet, e.g. ⌥-click (Decision 1) |
| Add Open Apps… to an existing group (CP-2) | Capture into a template; replacing a group's items |
| Regular apps only; Finder, this app, agents, background apps left out (CP-3) | Finder windows' folders, documents, browser tabs (need Automation or Accessibility) |
| Order: most recently used, or by name; "Select only apps with open windows" (CP-4) | Dock order; choosing single windows |
| Menu bar, sidebar +, Add menu, empty popup, link, Siri and Shortcuts (CP-5) | A standalone group's own app; a global capture shortcut |
| No permission at all (CP-6) | Window titles (Screen Recording), window positions (Accessibility) |
| Settings remembered in `preferences.json` (CP-4, CP-7) | A new Settings pane |
| — | Time, display and network triggers (phase 4b) |

### 0.3 Current-state inventory (what this wave builds on)

| Area | Where | What it does today |
| --- | --- | --- |
| Running apps for switching | `DockGroupsCore/Switching/RunningAppSnapshot.swift:57-85` | `SystemRunningApplicationsListing`: pid, identity, name, hidden, `isRegular` from `NSWorkspace.runningApplications` |
| Identity of a running app | `RunningAppSnapshot.swift:25-32`, `Launching/RunningApplicationLookup.swift:18-35` | lowercased bundle identifier, or the resolved, lowercased bundle location for apps without one |
| "Add a Running App" | `CybokronDockGroups/Settings/SwitchingSettingsView.swift:100-128` | regular, non-terminated apps with a bundle URL, as `GroupItem`s; precedent for capture |
| Always left alone | `Model/ProtectedApps.swift:11-13`, `:75-80`, `:107-119` | this app, its agents (`AgentIdentity.bundleIdentifierPrefix`), Finder when quitting; `addable(from:)` skips them |
| Live running state | `CybokronDockGroups/Support/RunningAppsMonitor.swift:8-56` | launch/quit/wake notifications; ids and path identities; used by popups and agents |
| Activations observed | `CybokronDockGroups/Support/UsageMonitor.swift:23-36` | `didActivateApplicationNotification` feeds Most Used (regular apps only, `:38-43`) |
| Window list without permission | `CybokronDockGroups/Support/AccessibilityAccess.swift:54-64` | `CGWindowListCopyWindowInfo` owner PID + layer: "don't need Screen Recording access" |
| Accessibility use | `Launching/WindowRestorer.swift:89-110` | only to restore minimized windows, behind `AXIsProcessTrusted()` |
| App item made from a URL | `Model/AppReference.swift:89-106` | `.app` bundles only; path identity resolves symlinks |
| App item made from a running app | `SwitchingSettingsView.swift:123-126`, `UsageMonitor.swift:44-48` | `GroupItem(bundleIdentifier:name:path:)` with `localizedName` and the standardized bundle path |
| App item gate (backups) | `Persistence/SettingsBackup.swift:203-228` | path-identified apps must be app bundle paths; ids with "/" or ":" left out; non-bundle fallback paths dropped |
| Starting an app | `Launching/GroupLauncher.swift:256-265` | only from an app bundle (`FileLocation.isAppBundlePath`, `Model/FileLocation.swift:59-64`) |
| Store | `Store/GroupStore.swift:140-151`, `:323-335` | `addGroup(named:emoji:)` (one save), `addItems` (dedupes case-insensitively, filters file items) |
| Unique names | `Model/GroupNaming.swift:13-23` | "name", "name 2"… against active and archived groups |
| Group window requests | `CybokronDockGroups/MainWindow/MainWindowView.swift:16-30`, `MainWindowController.swift:127-133` | popup asks the window to open Add Apps… etc. on a group |
| Sidebar + menu | `MainWindow/GroupSidebarView.swift:141-172` | New Group · New Group from Template ▸ · Manage Templates… |
| Group Add menu | `MainWindow/GroupDetailView.swift:198-203` | Add Apps… · Add Files or Folders… · Add Website… |
| Popup empty state | `Popup/PopupContentView.swift:681-702` | Add Apps… · Add Files or Folders… · Add Website… pills |
| Menu bar menu | `MenuBar/StatusBarController.swift:81-122` | current group, groups (+ ⌥ alternates), Most Used, Manage Groups…, Settings… |
| Links | `DockGroupsCore/Commands/URLCommand.swift:20-31`, `:70-111`; `App/AppDelegate.swift:506-604` | parsed in Core, gated by `URLCommandGate` (5 s per key) |
| Siri and Shortcuts | `Intents/DockGroupsShortcuts.swift:6-62`, `Intents/GroupIntentSupport.swift:7-25` | 5 of 10 App Shortcuts; `GroupIntentHandling` bridges to the app |
| Preferences | `Model/PopupPreferences.swift:151-229` | lenient keys; `protectedApps` written only when not empty |
| Agent snapshot | `Standalone/AgentConfiguration.swift:17-32` | resets settings agents don't use, so edits to them don't rebuild agents |
| Agent Dock menu | `Agent/AgentAppDelegate.swift:256-284`, `:34-38` | items, Open All, Hide All, Close All, Group Settings… (link to the main app) |

### 0.4 Rules carried over from earlier specs

- A+F §2.3 and C+D+E §5.3: every item is checked when it opens, whatever its source; capture adds
  no new item kind, only app items through the existing launch path.
- C+D+E §3.9 and G+I §2.10: a new app-wide setting is normalized out of `AgentConfiguration`
  unless agents use it.
- G+I §2.3: names the store makes are unique across active and archived groups; names the user
  types are kept as typed.
- C+D+E §2.6: links that change nothing but the UI are gated per key only; links that open, hide,
  start or finish apps share the group-apps cooldown. Capture links only open a sheet (§2.8).

---

## 1. User behavior

### 1.1 Words used in this spec and in the app

| Term | Meaning |
| --- | --- |
| **Open apps** | The regular apps running now: the ones with a Dock icon while they run. Shown as "Open Apps". |
| **Capture** | Making a group from open apps, or adding them to one. Not a word the UI uses on its own. |
| **Recently used** | The order in which apps were last brought to the front, the most recent first. |
| **Open window** | A normal window of the app, on screen or not (minimized, hidden, on another Space). |

### 1.2 New Group from Open Apps

1. Menu bar menu, the sidebar's **+** menu, or a link → **New Group from Open Apps…**.
2. The group window comes forward with a sheet (§3.1). The list was read the moment the item was
   chosen, so the app the user was working in is first.
3. Each row: icon, name, and a caption when it applies: "Hidden", "No open windows", "Protected".
   A checkbox per row; **Select All** and **Select None** below the list.
4. **Name** is filled in (§1.6) and selected, so typing replaces it. It follows the selection until
   the user edits it.
5. **Create Group** (Return) makes the group at the end of the list with the chosen apps, in the
   order shown, and selects it in the group window; **Cancel** (Escape) changes nothing.
   Create Group is disabled while nothing is selected.
6. The new group isn't standalone, has no shortcut and the default emoji, tile and popup settings:
   everything else is set in the group window as for any group.

### 1.3 Which apps are listed

| Running process | Listed? | Why |
| --- | --- | --- |
| A regular app (`activationPolicy == .regular`) with a bundle identifier and a `.app` bundle | yes | what a group holds |
| The same app running twice (two instances, or two copies with one identifier) | once | one item per identity (`normalizedBundleIdentifier`); the most recently used instance's location is kept |
| A regular app without a bundle identifier, at an app bundle path | yes, by location | as Add Apps… identifies it (`AppReference.swift:91-106`) |
| …without a bundle identifier, run from a temporary copy (App Translocation) | no, counted | its location changes every launch; the footnote says to move it to Applications |
| An app with an identifier, run from a temporary copy | yes, without a location | found by its identifier, as a backup's app with a non-bundle path (`SettingsBackup.swift:222-225`) |
| Accessory and background apps (menu bar extras, agents, helpers, `.accessory` / `.prohibited`) | no | not apps a user opens (as Most Used, `UsageMonitor.swift:39`) |
| Cybokron Dock Groups, another copy of it, a standalone group's own app | no | `ProtectedApps.isAlwaysProtected(…, action: .hiding)` |
| Finder | no | always running; a group can still get it through Add Apps… (Decision 2) |
| The Shortcuts app, when capture runs from Siri or Shortcuts | no | it's the caller, not part of the work (§1.10) |
| No bundle URL, a bundle URL that isn't a file URL to a `.app`, an identifier with "/", ":" or control characters | no, counted | `AppItemPolicy` (§2.5) |
| Terminated while the sheet is open | stays listed | the snapshot is frozen; an app item doesn't need the app running |

Apps launched while the sheet is open aren't added to it; closing and reopening the sheet reads
again. The footnote, only when the count isn't zero: "2 open apps can't be added here: they aren't
app bundles, or run from a temporary copy (move them to Applications first)."

### 1.4 Order

- **Most Recently Used** (default): apps in the order they were last brought to the front while
  Cybokron Dock Groups was running (in memory only, never saved, §2.3). Apps not brought to the
  front since then follow, in the order of their frontmost window on screen, then by launch date
  (newest first), then by name. The app that was in front when capture was chosen comes first;
  from the group window, that's the app used before the group window.
- **Name**: A to Z the way Finder sorts names (`DockGroup.sortedByName`, `DockGroup.swift:97-109`).
- The chosen order is the order of the added items. The sheet offers no reordering: the group
  window does (drag, Sort A→Z).

### 1.5 What starts selected

All listed apps start selected, except:

- **protected apps** (Settings → Switching): listed with the caption "Protected", not selected.
  They are the apps a user keeps open all day (mail, chat, a password manager), which are rarely
  part of one task (Decision 2);
- with **Select only apps with open windows** on: apps without an open window, captioned "No open
  windows";
- in **Add** mode, apps already in the group: shown checked and disabled, captioned "In this
  group", never counted;
- past the limit (§1.8): the apps after the 50th selectable one.

Changing the order or the window option re-plans the snapshot and resets the selection to these
defaults; the name follows unless it was edited.

### 1.6 Name suggestion

- One app selected: its name ("Xcode"). More: the first selected app's name and how many others,
  "Xcode +3" (no plural forms, so every language reads it the same). Nothing selected: "Open Apps".
- Made unique among active and archived groups (`GroupNaming.uniqueName`): "Xcode +3 2".
- A name the user typed is kept as typed (as renaming keeps it, G+I §2.3); a blank one falls back
  to the suggestion. (Decision 3.)

### 1.7 Add Open Apps to a group

- Group window → a group → **Add** → **Add Open Apps…**, or the popup of an empty group, or
  `cybokrondockgroups://capture/<group>`.
- The sheet (§3.2) has no name field; its title names the group; its button is **Add 3 Apps** ("Add
  1 App"), disabled with nothing selected.
- Apps already in the group are matched by identity, ignoring case, as the store's own duplicate
  check (`GroupStore.swift:763-766`).
- The chosen apps are appended in the order shown; in Free Layout each takes the first free cell,
  as any added item does. One change, one save; a standalone group's own app is rebuilt in place
  as for Add Apps… (`StandaloneController.swift:243-259`), its Dock icon refreshed when the tile's
  first nine icons change.
- When every open app is in the group already: "Every open app is already in “Coding”." with only
  **Done**.

### 1.8 Limits

- At most **50** apps per capture (`CapturePlan.maximumItems`). Past it, rows can't be checked:
  "You can add up to 50 apps at once." A group can still grow beyond 50 by capturing again or with
  Add Apps…: groups have no item limit today, and capture doesn't add one.
- The list itself shows at most 200 open apps (a guard; a Mac rarely runs 60).

### 1.9 Where capture is offered

| Surface | Item | Mode |
| --- | --- | --- |
| Menu bar menu | **New Group from Open Apps…**, after the groups and Most Used, before Manage Groups… | new group |
| Group window sidebar **+** menu | **New Group from Open Apps…**, after New Group from Template ▸ | new group |
| Group window, a group's **Add** menu | **Add Open Apps…**, after Add Apps… | add |
| Popup of an empty, editable group | **Add Open Apps…** pill, after Add Apps… | add (opens the group window, as Add Apps… does) |
| Link | `cybokrondockgroups://capture`, `cybokrondockgroups://capture/<group>` | new group, add |
| Siri and the Shortcuts app | **New Group from Open Apps**, **Add Open Apps to Group** | new group, add (no sheet) |
| A standalone group's own app | nothing new; Group Settings… leads to the group window | — |

The popup's grid context menu and the Most Used popup don't get it: the empty state is where
"what do I put in here?" is asked, and Most Used isn't editable.

### 1.10 Siri and Shortcuts

- **New Group from Open Apps**: parameters *Name* (optional; the suggestion when empty) and *Only
  Apps with Open Windows* (default: the remembered setting). Makes the group with the apps that
  start selected (§1.5), at most 50, and returns it, so a shortcut can go on with "Launch Group".
  Dialog: "Made “Xcode +3” with 4 apps." / "No open apps to put in a group."
- **Add Open Apps to Group**: parameters *Group* and *Only Apps with Open Windows*. Dialog: "Added
  2 apps to “Coding”." / "Every open app is already in “Coding”."
- Neither asks for confirmation: nothing is opened, hidden or quit, and the group can be deleted
  or edited. The Shortcuts app itself is left out (§1.3). An archived group gives the existing
  "is archived" error (`GroupIntentSupport.swift:58-65`).
- One App Shortcut with Siri phrases for the first ("Capture my open apps in Cybokron Dock
  Groups"): 6 of the 10 allowed (Decision 5).

### 1.11 Links

- `cybokrondockgroups://capture` opens the New Group sheet; `…/capture/<group>` the Add sheet for
  that group (named as other links name groups, `GroupLookup`). An unknown or archived group beeps
  and is logged, as for other links (`AppDelegate.swift:606-621`); no sheet opens.
- A link never writes anything: the user still clicks Create Group or Add. The app that opened the
  link (a browser, Terminal, a launcher) is usually first in the list.
- Settings → Shortcuts & Siri → Links lists "Add Open Apps" for the selected group after its other
  links; the README's link table gets both rows.

### 1.12 Standalone groups and remembered settings

Capture never makes a standalone group, and a standalone group's own app offers no capture: its
popup and Dock menu don't edit the group (`AgentAppDelegate.swift:11-13`), and its Group
Settings… opens the group window, where Add Open Apps… is. Adding to a standalone group is an
item change (its own app is rebuilt as for Add Apps…). Those own apps are never listed: they are
regular apps while their Dock menu is on (`PopupPreferences.swift:48-52`).

The sheet's **Order** pop-up and **Select only apps with open windows** checkbox are saved in
`preferences.json` when changed, and used by the next capture, Siri and Shortcuts included. There
is no Settings pane for them (Decision 6). They travel with backups as part of the preferences.

### 1.13 en-US text drafts

| Where | Text |
| --- | --- |
| Menu bar / sidebar + | "New Group from Open Apps…" |
| Menu bar tooltip | "Make a group of the apps that are open now. You choose which ones first." |
| Add menu / popup pill | "Add Open Apps…" |
| Add menu help | "Add apps that are open now to this group." |
| Sheet title (new) | "New Group from Open Apps" |
| Sheet title (add) | "Add Open Apps to “Coding”" |
| List header | "Open Apps (7)" |
| Order pop-up | "Order:" "Most Recently Used" · "Name" |
| Window option | "Select only apps with open windows" |
| Window option, window list unreadable | "macOS didn't say which apps have open windows." (option disabled) |
| Captions | "Hidden" · "No open windows" · "Protected" · "In this group" |
| Buttons | "Select All" · "Select None" · "Cancel" · "Create Group" · "Add 1 App" / "Add %ld Apps" · "Done" |
| Footer | "Background apps, Finder and Cybokron Dock Groups aren't listed. Nothing is opened or quit." |
| Unavailable footnote | "1 open app can't be added here…" / "%ld open apps can't be added here: they aren't app bundles, or run from a temporary copy (move them to Applications first)." |
| Limit | "You can add up to 50 apps at once." |
| Nothing to list | "No other apps are open." |
| All in group | "Every open app is already in “%@”." |
| Name fallback | "Open Apps" · suggestion "%1$@ +%2$ld" |

---

## 2. Architecture

### 2.1 Layers and files

| Layer | New or changed | Purpose |
| --- | --- | --- |
| Core model | `Model/CaptureSettings.swift` (new); `Model/PopupPreferences.swift` (changed) | the two remembered settings; `capture` key |
| Core model | `Model/AppItemPolicy.swift` (new) | the app item gate, out of `SettingsBackup.safeItem` |
| Core capture | `Capture/OpenApps.swift`, `Capture/ActivationHistory.swift`, `Capture/CapturePlanner.swift` (new) | snapshot values, reader protocol and system reader, history, planner, naming |
| Core store | `Store/GroupStore.swift` (changed) | `addGroup(named:items:)`; `addItems` applies `AppItemPolicy` |
| Core persistence | `Persistence/SettingsBackup.swift`, `Standalone/AgentConfiguration.swift` (changed) | `safeItem` calls `AppItemPolicy`; agent snapshot resets `capture` |
| Core commands | `Commands/URLCommand.swift`, `Commands/GroupInvocations.swift` (changed) | `capture` links; "Add Open Apps" link listing |
| Core diagnostics | `Diagnostics/DiagnosticsReport.swift` (changed) | one line with the two settings |
| App | `Capture/CaptureController.swift`, `Capture/CaptureSheet.swift` (new) | history feed, snapshot timing, the sheet and its model |
| App | `MainWindowView.swift`, `MainWindowController.swift`, `GroupSidebarView.swift`, `GroupDetailView.swift`, `PopupContentView.swift`, `PopupPanelController.swift`, `StatusBarController.swift`, `AppDelegate.swift`, `ShortcutsSettingsView.swift` (changed) | surfaces |
| App intents | `Intents/CaptureIntents.swift` (new); `DockGroupsShortcuts.swift`, `GroupIntentSupport.swift` (changed) | two intents, one App Shortcut |

### 2.2 Core types

```swift
/// A running app as capture reads it: copied once from `NSRunningApplication`; nothing stays live.
public struct OpenApp: Hashable, Sendable {
    public let processIdentifier: pid_t
    public let bundleIdentifier: String?
    public let bundleURL: URL?
    public let name: String?                       // localizedName
    public let isRegular: Bool                     // activationPolicy == .regular
    public let isHidden: Bool
    public let launchDate: Date?
}

/// Which processes have windows, from the window server's owner, layer, bounds, alpha and
/// on-screen fields only: no permission, no prompt, never a window's name (§2.3).
public struct WindowSnapshot: Equatable, Sendable {
    /// Processes with at least one normal-layer window, on screen or not.
    public let processesWithWindows: Set<pid_t>
    /// Processes by their frontmost on-screen normal window, front first.
    public let onScreenOrder: [pid_t]
}

/// Everything a capture is planned from, read at one moment (§2.6).
public struct OpenAppsSnapshot: Equatable, Sendable {
    public let apps: [OpenApp]
    public let windows: WindowSnapshot?            // nil: the window server didn't answer
    public let history: ActivationHistory
}

@MainActor public protocol OpenAppsReading: AnyObject { func openApps() -> [OpenApp]; func windows() -> WindowSnapshot? }
/// `NSWorkspace.shared.runningApplications` and `CGWindowListCopyWindowInfo`.
@MainActor public final class SystemOpenAppsReader: OpenAppsReading { … }

/// The order apps were brought to the front while this app runs. Memory only, never saved.
public struct ActivationHistory: Equatable, Sendable {
    public static let maximumCount = 200
    public mutating func recordActivation(ofIdentity identity: String)   // moves it to the front
    public func rank(ofIdentity identity: String) -> Int?                // 0 = most recent
}

public struct CaptureSettings: Hashable, Sendable {
    public enum Order: String, Codable, CaseIterable, Sendable { case recentlyUsed, name }
    public var order: Order = .recentlyUsed
    public var selectsOnlyAppsWithWindows = false
    public var isDefault: Bool { self == CaptureSettings() }
}
extension PopupPreferences { public var capture: CaptureSettings }   // stored; key "capture"

public enum CaptureTarget: Hashable, Sendable { case newGroup, group(DockGroup.ID) }

public struct CaptureCandidate: Identifiable, Hashable, Sendable {
    public enum Note: Hashable, Sendable { case hidden, noWindows, protected, inGroup }
    public let item: GroupItem                     // kind .application, passed AppItemPolicy
    public let notes: Set<Note>
    public let isSelectable: Bool                  // false: already in the target group
    public var id: String { item.normalizedBundleIdentifier }
}

public struct CapturePlan: Equatable, Sendable {
    public static let maximumItems = 50
    public static let maximumCandidates = 200
    public let target: CaptureTarget
    public let candidates: [CaptureCandidate]      // in the chosen order
    public let defaultSelection: [CaptureCandidate.ID]   // §1.5, at most maximumItems
    public let unavailableCount: Int               // regular apps that can't be items (§1.3)
    /// The selected items, in candidate order: selectable ones only, the first `maximumItems`.
    public func items(selecting ids: Set<CaptureCandidate.ID>) -> [GroupItem]
}

public enum CapturePlanner {
    /// `targetItems`: the group's items in add mode, else []; `leavingOut`: the Shortcuts app for intents.
    public static func plan(_ snapshot: OpenAppsSnapshot, settings: CaptureSettings, target: CaptureTarget,
                            targetItems: [GroupItem], protectedApps: ProtectedApps,
                            leavingOut identities: Set<String> = []) -> CapturePlan
    /// §1.6: "Xcode", "Xcode +3", "Open Apps", made unique against `taken`.
    public static func suggestedName(for items: [GroupItem], taken: some Sequence<String>) -> String
}
```

`OpenApp` and `WindowSnapshot` are values so that tests build any situation by hand (two
instances, translocated paths, missing launch dates, an unreadable window list) without
`NSRunningApplication`; the system reader is the only code that touches AppKit for capture.

### 2.3 Reading the system: what needs a permission

| Information | API | Permission | Used for |
| --- | --- | --- | --- |
| Running apps, identifier, bundle URL, name, policy, hidden, launch date | `NSWorkspace.runningApplications`, `NSRunningApplication` | none | the list (`RunningAppSnapshot.swift:66-79` reads the same) |
| Activations | `NSWorkspace.didActivateApplicationNotification` | none | Most Recently Used (as `UsageMonitor.swift:30-35`) |
| Window owner PID, layer, bounds, alpha, on screen | `CGWindowListCopyWindowInfo` | none; it never prompts | "open windows" and the on-screen order |
| Window names | `kCGWindowName` | Screen Recording (withheld without it) | **never read** |
| Windows, minimized state, documents of windows | Accessibility (`AXUIElement`, as `WindowRestorer.swift:89-110`) | Accessibility | **not used** |
| Folders shown in Finder windows, browser tabs | Apple Events | Automation | **not used** (out of scope) |

**Finding: capture doesn't need Accessibility.** Everything listed or ordered comes from the first
three rows. Per-window selection, choosing which windows or documents to capture, would need
Accessibility (window list and `kAXDocumentAttribute`) or Screen Recording (window titles), and is
out of scope; the permission-free part of "window-based selection" is the window option, which
only pre-selects (§1.5).

`SystemOpenAppsReader.windows()` makes two calls: `.optionOnScreenOnly` + `.excludeDesktopElements`,
which the SDK header documents as "ordered from front to back" (`CGWindow.h`,
`kCGWindowListOptionOnScreenOnly`), for `onScreenOrder`; and `.optionAll` for
`processesWithWindows` (windows of hidden apps, minimized windows and other Spaces are off
screen). A window counts when its layer is 0, its alpha is above 0 and its bounds are at least
50 × 50 points, to skip the invisible helper windows some apps keep; an off-screen window that is a
square at x = 0 doesn't count either (PR 1 spike, `docs/design/capture-spike.md`: every app keeps
such helpers off screen). That's a heuristic: the spike records it for hidden apps and apps with
nothing open; minimized-only apps, other Spaces, full screen and Stage Manager stay manual in PR 2.
Its errors only change a default checkbox. `openApps()` returns regular apps only (the spike: 10 ms
for every process's properties, 0.3 ms for the regular ones).

**Activation history.** `CaptureController` (App, main app only) observes
`didActivateApplicationNotification`, records the regular app's identity
(`RunningAppSnapshot.identity(bundleIdentifier:bundleURL:)`), and seeds itself at launch with
`NSWorkspace.frontmostApplication`. Activations of this app are not recorded, so "most recent"
from the group window is the app used before it. Agents don't run it.

### 2.4 Planning (pure, Core)

`CapturePlanner.plan`, in order:

1. **Eligibility.** For each `OpenApp`: not regular → skip (not counted); identity from
   `RunningAppSnapshot.identity`; always protected (`ProtectedApps.isAlwaysProtected(identity:
   action: .hiding)`), Finder (`ProtectedApps.finderBundleIdentifier`) or in `leavingOut` → skip;
   build the item (step 2) → `nil` counts in `unavailableCount`.
2. **Item.** With a bundle identifier: `GroupItem(bundleIdentifier:name:path:)`, path =
   `bundleURL.standardizedFileURL.path` unless it's translocated (a path component
   `AppTranslocation`), then `nil`. Without one: identity = the bundle URL with symlinks resolved and
   standardized (as `AppReference.swift:101-104`), refused when translocated. Name =
   `DockGroup.sanitizedName(localizedName)` or the bundle's file name without `.app`, control
   characters removed, at most 255 characters. The bundle identifier must also be at most 255
   characters without whitespace or control characters (stricter than stored data, because it's
   new input). Then `AppItemPolicy.sanitized` (§2.5); its `nil` is unavailable.
3. **De-duplication** by `normalizedBundleIdentifier`: the instance ranked first in step 4 wins
   (its path is kept).
4. **Order.** `.name`: `DockGroup.sortedByName`. `.recentlyUsed`: by history rank; unranked after
   ranked, by first index in `windows.onScreenOrder` (a pid not on screen after those on screen),
   then `launchDate` newest first (missing dates last), then name. Stable for equal keys.
5. **Notes and selection.** `inGroup` when `targetItems` has the identity (not selectable);
   `protected` when `protectedApps.lists(identity:)`; `hidden` from `isHidden`; `noWindows` when
   `windows` is known and lacks the pid (never set when it's `nil`). Default selection: selectable,
   not protected, not `noWindows` when the window option is on; the first 50 of those.
6. **Bounds.** At most 200 candidates, in order, before notes.

`items(selecting:)` returns selectable candidates in candidate order, filtered by the ids, capped
at 50: the sheet, the intents and the tests share it, so the cap can't be bypassed by a UI bug.

### 2.5 Store integration and the app item gate

```swift
/// Apps that come from outside the app's own pickers: backups, capture, and every store addition.
/// The rule `SettingsBackup.safeItem` applied to apps (`SettingsBackup.swift:214-226`), in one place.
public enum AppItemPolicy {
    /// Can be a bundle identifier: no "/" or ":" (today's backup rule, unchanged).
    public static func isBundleIdentifier(_ identifier: String) -> Bool
    /// `item` itself for non-apps; for an app, with a fallback path that isn't an app bundle path
    /// dropped, or `nil` when its identity is neither a bundle identifier nor an app bundle path.
    public static func sanitized(_ item: GroupItem) -> GroupItem?
}

extension GroupStore {
    /// A new group at the end of the list with `items` (after `AppItemPolicy` and `FileItemPolicy`,
    /// duplicates dropped), named `name` as typed, or the default when blank. One change, one save.
    @discardableResult public func addGroup(named name: String, items: [GroupItem]) -> DockGroup
}
```

- `SettingsBackup.safeItem`'s app branch calls `AppItemPolicy.sanitized`; behavior unchanged
  (fixtures and `SettingsBackupTests` prove it).
- `GroupStore.addItems(_:toGroup:)` (`GroupStore.swift:323-335`) maps items through
  `AppItemPolicy.sanitized` before its existing `FileItemPolicy.acceptsByIdentity` filter, so every
  caller (Add Apps…, Add Website…, moves, capture, intents) passes the same gate. Add Apps…'s items
  (`AppReference(applicationURL:)`) and "Add a Running App"'s pass it already; PR 1 proves it with
  the existing store tests.
- The suggestion is made by `CapturePlanner.suggestedName` against the active and archived names
  (the sheet and the intents pass them from the store, as `GroupStore.takenNames` lists them,
  `GroupStore.swift:754-757`); the store then keeps the name it's given, as `addGroup(named:)`
  does (`GroupStore.swift:140-151`).
- Add mode uses `addItems` unchanged otherwise: append, case-insensitive dedupe, Free Layout cells
  sanitized, one save.

### 2.6 App wiring

**Snapshot timing.** `CaptureController.snapshot() -> OpenAppsSnapshot` runs synchronously in the
action that asks for capture, before anything activates the app:

```swift
// AppDelegate
private func beginCapture(_ target: CaptureTarget) {
    let snapshot = capture.snapshot()              // the user's app is still in front
    popupController.close()
    mainWindowController.capture(target, from: snapshot)   // then NSApp.activate()
}
```

The menu bar's menu and the popup don't activate the app (it's `LSUIElement`; the popup is a
non-activating panel), so their snapshot has the user's app first. A link's snapshot is taken when
the link is handled; the opener is in front then. From the group window, the history puts the app
used before it first (§2.3).

**Group window.** `GroupWindowSelection` gains `@Published var capture: CaptureRequest?`
(`CaptureRequest: Identifiable { target, snapshot, id }`). `MainWindowController.capture(_:from:)`
sets it and shows the window — on the target group in add mode, through `showSettings(ofGroup:)`
(`MainWindowController.swift:116-125`). `MainWindowView` presents one `.sheet(item:)` for both
modes, like the template sheets (`MainWindowView.swift:187-199`). When another sheet is up (Save
as Template, Manage Templates, Add Website, a details editor), the request waits until it closes;
a newer request replaces a waiting one.

**`CaptureSheetModel`** (App, `ObservableObject`): snapshot, settings, plan, selection, name text,
`nameWasEdited`. Changing the order or the window option saves `preferences.capture` (one
`PreferencesStore.update`) and re-plans the same snapshot. Create: `store.addGroup(named:items:)`
then `selection.groupID = group.id`. Add: `store.addItems(_:toGroup:)`; if the group was deleted
or archived meanwhile, the sheet closes with a beep (logged).

**Surfaces.**

- `StatusBarController.Actions` gains `captureNewGroup`; one item before Manage Groups…
  (`StatusBarController.swift:99-102`), enabled always.
- `GroupSidebarView.Actions` gains `captureNewGroup`; a button in the + menu after the templates
  submenu (`GroupSidebarView.swift:143-160`).
- `GroupDetailView`'s Add menu gains Add Open Apps… (`GroupDetailView.swift:198-203`), calling an
  action that the window passes down (snapshot taken in the click).
- `PopupContentView.PopupActions.addOpenApps` (`nil` for Most Used and agents); the empty-state
  pill after Add Apps… (`PopupContentView.swift:693-694`); `PopupPanelController` maps it to
  `beginCapture(.group(id))`.
- Icons in the sheet come from the existing `AppIconProviding` by item (cached), not from the
  disk per row.

**Diagnostics.** One line: "Capture: order recentlyUsed, windowed-only off" (no app names).

### 2.7 Siri and Shortcuts

```swift
struct CaptureOpenAppsIntent: AppIntent {          // "New Group from Open Apps"
    @Parameter(title: "Name") var name: String?
    @Parameter(title: "Only Apps with Open Windows") var onlyAppsWithWindows: Bool?
    func perform() async throws -> some IntentResult & ReturnsValue<GroupEntity> & ProvidesDialog
}
struct AddOpenAppsIntent: AppIntent {              // "Add Open Apps to Group"
    @Parameter(title: "Group", requestValueDialog: "Which group?") var group: GroupEntity
    @Parameter(title: "Only Apps with Open Windows") var onlyAppsWithWindows: Bool?
    func perform() async throws -> some IntentResult & ProvidesDialog
}
```

- `GroupIntentHandling` gains `captureNewGroup(named:onlyAppsWithWindows:) -> CaptureOutcome` and
  `captureOpenApps(into:onlyAppsWithWindows:) -> CaptureOutcome` (`.created(DockGroup, count)`,
  `.added(count, alreadyIn)`, `.nothingToAdd`). The app plans a fresh snapshot with
  `leavingOut: ["com.apple.shortcuts"]` and the default selection; `nil` for the option means the
  remembered setting.
- The group is resolved through `GroupIntentSupport.resolve` (archived → error, unchanged).
- `DockGroupsShortcuts` gains one `AppShortcut` for `CaptureOpenAppsIntent` (phrases "Capture my
  open apps in \(.applicationName)", "Make a group from my open apps in \(.applicationName)"):
  6 of 10. Intent strings stay English literals like the others (`L10n.swift:12-13`).
- No `requestConfirmation`: the intents neither open nor quit anything (C+D+E asks only before
  quitting).

### 2.8 Links

- `URLCommand` gains `.captureNewGroup` (`capture`, no argument) and `.captureOpenApps(String)`
  (`capture/<group>`; the group may contain "/", as `settings/group/` allows). Throttle keys
  `capture` and `capture/<normalized token>`; `groupActionKey == nil`: the link only shows a sheet,
  like `groups` and `settings`.
- `AppDelegate.perform(_:)` calls `beginCapture`; `group(named:)` keeps its beep and log for an
  unknown or archived group.
- `GroupInvocations.captureLink(for:in:)` → "Add Open Apps" `cybokrondockgroups://capture/<token>`,
  listed after the switching links (`ShortcutsSettingsView.swift:229-242`).

### 2.9 Data schema and compatibility

Format versions stay **1** everywhere. `groups.json`, agent configurations, templates and the
backup document gain nothing. Captured items are written exactly as Add Apps… writes them:

```jsonc
// groups.json: an ordinary group with ordinary app items
{ "id": "…", "name": "Xcode +3", "emoji": "🗂️", "apps": [
    { "bundleIdentifier": "com.apple.dt.Xcode", "name": "Xcode", "path": "/Applications/Xcode.app" },
    { "bundleIdentifier": "com.apple.Safari", "name": "Safari", "path": "/Applications/Safari.app" } ], … }

// preferences.json: written only when not the defaults
{ …, "capture": { "order": "name", "selectsOnlyAppsWithWindows": true } }
```

| Saved | Read as |
| --- | --- |
| no `capture`, or not an object | defaults (recently used, window option off) |
| `order` unknown or not a string | `recentlyUsed` |
| `selectsOnlyAppsWithWindows` not a boolean | `false` |
| unknown keys inside `capture` | ignored |
| a backup's preferences with `capture` | restored with Replace All, as every preference; Merge doesn't touch preferences (unchanged) |

Older versions:

| Data | 0.9.0 and earlier | Result there |
| --- | --- | --- |
| groups made or extended by capture | ordinary groups and app items | identical behavior |
| `capture` in `preferences.json` | unknown key, ignored (`PopupPreferences.swift:174-204`) | nothing |
| **a save there** | preferences written without `capture` | after coming back, capture uses the defaults again |

No `DowngradeProtection` or `ReleaseHistory` change: only two settings can be lost, and they come
back as defaults. Encoding `capture` only when it isn't the default keeps a 0.9.0 preferences file
byte-identical after a 0.10.0 round trip (fixture test, §6).

### 2.10 Agents

`AgentConfiguration.init` (`AgentConfiguration.swift:22-32`) sets `snapshot.capture =
CaptureSettings()`: changing the order or the window option rebuilds no agent. Agents don't run
`CaptureController`, observe no activations and gain no menu item. An item added to a standalone
group by capture makes its agent `outdated` and rebuilt exactly as Add Apps… does
(`Standalone/AgentPlanner.swift:119`).

### 2.11 Localization plan

As the earlier specs: keys arrive with their code, each PR lists its prefixes in
`awaitingTranslation`, `docs/l10n-keys.md` gets sections marked "English only for now", and PR 4
translates them into the 25 languages.

| Prefix | Where | About |
| --- | --- | --- |
| `core.capture.` | name fallback and suggestion, unavailable footnote (one/other), the limit sentence | 5 |
| `capture.sheet.` | titles, header, order, option, captions, buttons, footer, empty states | 22 |
| `menuBar.capture.`, `groupWindow.capture.`, `popup.capture.` | menu items, tooltip, help | 5 |
| `core.invocation.capture.` | "Add Open Apps" link title | 1 |

About **33 keys** (792 → about 825). The suggestion "%1$@ +%2$ld" needs no plural forms; "Add
%ld Apps" and the footnote use `.one` / `.other` as other counts do (`L10n.swift:56-59`).

---

## 3. UX sketches

### 3.1 New Group from Open Apps

```
┌ New Group from Open Apps ───────────────────────────────────────────────┐
│ Name   [ Xcode +3                                              ]        │
│                                                                         │
│ Open Apps (7)                      Order: [Most Recently Used ▾]        │
│ ┌─────────────────────────────────────────────────────────────────────┐ │
│ │ [✓] 🔨 Xcode                                                         │ │
│ │ [✓] 🧭 Safari                                                        │ │
│ │ [✓] ⌨️ Terminal                                                      │ │
│ │ [✓] 📱 Simulator                                                     │ │
│ │ [ ] ✉️ Mail                                          Protected        │ │
│ │ [ ] 💬 Slack                                         Protected        │ │
│ │ [✓] 🎵 Music                                         Hidden           │ │
│ └─────────────────────────────────────────────────────────────────────┘ │
│ [ ] Select only apps with open windows        [Select All] [Select None] │
│ Background apps, Finder and Cybokron Dock Groups aren't listed.         │
│ Nothing is opened or quit.                                              │
│                                                  [Cancel] [Create Group]│
└─────────────────────────────────────────────────────────────────────────┘
```

With the window option on, Music (no open windows, say) loses its check and shows "No open
windows". With an unavailable app: "1 open app can't be added here: …" above the buttons.

### 3.2 Add Open Apps to a group

```
┌ Add Open Apps to “Coding” ──────────────────────────────────────────────┐
│ Open Apps (6)                      Order: [Name ▾]                      │
│ ┌─────────────────────────────────────────────────────────────────────┐ │
│ │ [✓] 🧭 Safari                                        In this group    │ │  (disabled)
│ │ [✓] 📱 Simulator                                                     │ │
│ │ [✓] ⌨️ Terminal                                      In this group    │ │  (disabled)
│ │ [✓] 🔨 Xcode                                         In this group    │ │  (disabled)
│ │ [✓] 🐙 GitHub Desktop                                                │ │
│ │ [ ] 💬 Slack                                         Protected        │ │
│ └─────────────────────────────────────────────────────────────────────┘ │
│ [ ] Select only apps with open windows        [Select All] [Select None] │
│                                                   [Cancel] [Add 2 Apps] │
└─────────────────────────────────────────────────────────────────────────┘

All open apps already in the group:
│ Every open app is already in “Coding”.                          [Done] │
```

### 3.3 Menu bar menu, group window, empty popup

```
Menu bar menu:                Sidebar + menu:                 A group's Add menu:
  Groups …  Most Used …         New Group                       Add Apps…
  ───────────────────           New Group from Template ▸       Add Open Apps…        (new)
  New Group from Open Apps…     New Group from Open Apps… (new) Add Files or Folders…
  Manage Groups…   ⌘G           ──────────                      Add Website…
  Settings…        ⌘,           Manage Templates…

Empty popup:   This group is empty
               (Add Apps…) (Add Open Apps…) (Add Files or Folders…) (Add Website…)
```

Four pills may not fit the one-column popup: they wrap to two lines there (checked in PR 2).

### 3.4 Keyboard and VoiceOver

- Return: Create Group / Add; Escape: Cancel; Space toggles the focused row; ⌘A: Select All.
- Each row is one element: "Xcode, selected" / "Mail, protected, not selected" / "Safari, in this
  group, dimmed"; the order pop-up and the window option have their visible labels.
- The limit and unavailable notes are announced when they appear
  (`AccessibilityNotification.Announcement`).

---

## 4. Security and privacy

### 4.1 Threat model

`SECURITY.md` ("Scope") names another process, a web page or link, a crafted `groups.json` or
`.dockgroups` backup making the app launch unintended apps or run code. Capture adds three inputs:
**the running processes** (any local app, including one that names itself after another),
**a link** that opens the sheet, and **two preferences**. It adds no output beyond app items.

### 4.2 Invariants

- **CP-S1 Read, don't act.** Capture never launches, activates, hides or quits anything, and
  never reads an app bundle's contents: it copies `NSRunningApplication` properties and resolves
  one path.
- **CP-S2 Apps, as app bundles.** A captured item is `.application`, its identity a bundle
  identifier (no "/", ":", whitespace or control characters, at most 255 characters) or an app
  bundle path
  (`FileLocation.isAppBundlePath`), its fallback path an app bundle path or nothing. No file,
  folder or website, no opener, delay, alias, tags or notes come from capture.
- **CP-S3 Same gate for every source.** `GroupStore.addItems` and `addGroup(named:items:)` apply
  `AppItemPolicy` and `FileItemPolicy`, so a bug in the sheet or an intent can't add what a backup
  couldn't.
- **CP-S4 Launching unchanged.** A captured app opens through `GroupLauncher`, which starts only
  app bundles (`GroupLauncher.swift:256-265`), resolving by identifier first.
- **CP-S5 Nothing from files.** `groups.json` gains no field; `capture` holds an enum and a
  boolean, never an app, path or command. The activation history isn't saved. A crafted file or
  backup can change at most the default order and checkboxes.
- **CP-S6 No silent writes from outside.** Links only show the sheet; the user's click writes. The
  intents write without a sheet because the user built or spoke that shortcut, and they only add
  apps running now; no intent opens or quits anything.
- **CP-S7 No permission.** No Accessibility, Screen Recording, Automation or Input Monitoring; no
  `AXIsProcessTrustedWithOptions`, no `CGRequestScreenCaptureAccess`; `kCGWindowName` never read.
- **CP-S8 Bounded.** 200 candidates, 50 items per capture, two window list calls per snapshot,
  history of 200 identities.

**Look-alike apps.** A process can claim another app's identifier (a copy of "Safari" in
Downloads). Capture records what LaunchServices reports, as Add Apps… records what the user
picked; the item then opens by identifier through LaunchServices, with the captured path only as
a fallback. Capture grants such an app nothing Add Apps… doesn't; the sheet shows the name and
icon the process has.

### 4.3 Privacy

Nothing leaves the Mac. The activation history is memory only and holds identities, not
timestamps of use; it's dropped when the app quits. Logs: "Captured 4 apps into group <id>" and
"capture: 2 unavailable" (counts, group ids; no names). Diagnostics: the two settings only.

---

## 5. Performance

- **Snapshot.** One `runningApplications` read (typically 60–150 processes, of which 10–40
  regular) and two `CGWindowListCopyWindowInfo` calls (a few hundred windows), on the main thread,
  once per capture. Budget: under 10 ms on an M1 with 40 regular apps and 400 windows, measured in
  the PR 1 spike; the sheet appears after it, so a slow window server only delays the sheet.
- **Planning.** O(n log n) in candidates with dictionary lookups; re-planning on an order or
  option change reuses the snapshot (no system calls).
- **History.** One dictionary update per activation (already a notification the app receives for
  Most Used); at most 200 entries.
- **Icons.** From the shared `AppIconProviding` cache by item; at most 200 rows, lazily in a
  `List`.
- **Store.** One change and one save per capture; for a standalone target, one agent rebuild (as
  for any item change, debounced by `StandaloneController`); a new group from capture builds none.
- **Idle cost.** None: no polling, no timers, no window list reads outside a capture.

---

## 6. Test plan

`Tests/DockGroupsCoreTests`, swift-testing, no real NSWorkspace, window server or LaunchServices.
Fakes in a new `CaptureFakes.swift`: `FakeOpenAppsReader` (apps, windows or `nil`) and helpers
building `OpenApp` values.

- **`CapturePlannerTests`**: regular only; this app, another copy, agents, Finder and `leavingOut`
  skipped; no bundle URL, non-`.app` URL, bad identifiers counted as unavailable; two instances →
  one item, path of the better-ranked one; translocated with identifier → no path, without →
  unavailable; name sanitizing and fallback; order by history, then on-screen order, then launch
  date, then name, stable; `.name` order Finder-like; notes (hidden, noWindows only with a known
  window list, protected, inGroup case-insensitive and by path identity); default selection rules
  with and without the window option; 50 cap in `defaultSelection` and `items(selecting:)` even
  when 60 ids are passed; 200 candidate bound; empty input; every open app in the group.
- **`CaptureNamingTests`**: "Xcode", "Xcode +3", "Open Apps", uniqueness against active and
  archived names, a localized suggestion format with reordered placeholders.
- **`ActivationHistoryTests`**: recency, re-activation moves to front, bound of 200, identities
  lowercased, seed.
- **`WindowSnapshotTests`**: the system reader's pure part (`WindowSnapshot.init(onScreen:all:)`
  over dictionaries): layer, alpha and size filters, front-to-back order, missing keys, a window
  name present or not makes no difference.
- **`CaptureSettingsCodingTests`**: defaults omitted; lenient values (§2.9 table); round trip;
  **0.9.0 fixtures** (`Version090PreferencesFixtures`, generated by building `2ea08df`'s Core:
  preferences with and without protected apps, a groups file, an agent configuration) re-encode
  byte for byte.
- **`AppItemPolicyTests`**: the backup rule moved without change (existing `SettingsBackupTests`
  pass untouched); `addItems` refuses a path-identified app at a script path and drops a
  non-bundle fallback path; Add Apps…-style and running-app-style items pass.
- **`GroupStoreCaptureTests`**: `addGroup(named:items:)` appends, one change of `groups`, one
  save, duplicates dropped, typed name kept, blank → default; add mode via `addItems` keeps order
  and Free Layout.
- **`AgentModelTests`** (addition): a `capture` change doesn't make an agent `outdated`.
- **`URLCommandTests`** (additions): `capture`, `capture/<group>`, `capture/a/b`, throttle keys,
  `groupActionKey == nil`, `capture?x=1` ignored query.
- **`DiagnosticsReportTests`**, **`LocalizationTests`** (prefixes).
- **Manual (recorded in PRs 1–3):** on macOS 14, 15 and 26 (this Mac runs 27.0.1), after
  `tccutil reset Accessibility com.cybokron.dockgroups` and `tccutil reset ScreenCapture
  com.cybokron.dockgroups`: capture from each surface shows no prompt and nothing appears in
  Privacy & Security; menu bar capture puts the front app first; group window capture puts the
  app used before it first; the window option's matrix (§2.3); a translocated app; an app on a
  mounted disk image; an AppleScript applet without an identifier; the user's Half-Life
  wrappers (expected: not listed, R5); a standalone target; Siri and the Shortcuts app (the
  Shortcuts app left out); links from Safari and Terminal; the sheet while Save as Template is open.

---

## 7. Risks and unknowns

| # | Risk or unknown | Effect | Mitigation |
| --- | --- | --- | --- |
| R1 | "Has an open window" is a heuristic without Accessibility | wrong default checkbox | pre-selection only, never eligibility; size/alpha filter; PR 1 spike matrix |
| R2 | A future macOS gates `CGWindowListCopyWindowInfo` | no window info, or a prompt | the reader returns `nil` → option disabled with its note; if it ever prompts, drop the window option (capture still works) |
| R3 | History empty right after login or app launch | order less useful | falls back to on-screen order, launch date, name; seeded with the front app |
| R4 | Translocated and disk image apps | stale paths | path dropped or app counted unavailable with advice; disk image paths kept (fallback only) |
| R5 | Script wrapper apps don't register with LaunchServices | not listed | documented; Add Apps… still adds them |
| R6 | The sheet collides with another sheet in the group window | request lost | queued until the other closes; newest wins |
| R7 | Capturing 30 apps clutters the group | messy groups | protected unselected, Select None, 50 cap, review step |
| R8 | The caller app is captured (Shortcuts, the browser of a link) | an unwanted item | Shortcuts left out for intents; links show the sheet, the user unchecks |
| R9 | Snapshot taken after the app activates | wrong first app | snapshot in the action, before `NSApp.activate()`; review in PR 2 |
| R10 | A look-alike process | a misleading item | as Add Apps…; opens via LaunchServices by identifier (§4.2) |
| R11 | Automations calling the intent repeatedly | many groups | user-authored; each run is one group; no rate limit (as other intents) |
| R12 | Four pills in a narrow empty popup | cramped popup | wrap; PR 2 checks the one-column popup |

---

## 8. PR plan

Four PRs, Core first: PR 1 touches `GroupStore.addItems`, which every add path uses, so it lands
alone and fully tested before anything can capture. Each keeps `scripts/test.sh` green, runs
`xcodegen generate` when files are added, and adds its keys and `awaitingTranslation` prefixes
(`AGENTS.md`).

| PR | Title (Conventional Commits) | Scope | Acceptance criteria |
| --- | --- | --- | --- |
| **1** | `feat(core): plan capturing open apps into groups` | Spike first (window list matrix, timing, no prompt after a TCC reset; results in the PR). `OpenApp`, `WindowSnapshot`, `OpenAppsSnapshot`, `OpenAppsReading` + `SystemOpenAppsReader`, `ActivationHistory`, `CaptureSettings` + `PopupPreferences.capture`, `CaptureTarget`, `CaptureCandidate`, `CapturePlan`, `CapturePlanner` + naming; `AppItemPolicy` (backup and `addItems` use it); `GroupStore.addGroup(named:items:)`; `AgentConfiguration` normalization; `URLCommand` capture links and `GroupInvocations.captureLink`; diagnostics line; `Version090PreferencesFixtures`. Keys: `core.capture.`, `core.invocation.capture.`. | Existing tests pass unchanged; §6 Core suites pass; 0.9.0 preferences fixtures byte-identical; no UI. |
| **2** | `feat: capture open apps from the menu bar, the group window and the popup` | `CaptureController` (history feed, snapshot), `CaptureSheet` + model, `GroupWindowSelection.capture`, `MainWindowController.capture`, sidebar + menu, Add menu, empty popup pill, menu bar item, link handling, Settings → Links row; README (features, link table), CHANGELOG, SECURITY.md scope sentence. Keys: `capture.sheet.`, `menuBar.capture.`, `groupWindow.capture.`, `popup.capture.`. | Manual list (§6) for the surfaces; no permission prompt anywhere; nothing opens or quits; an archived group is never a target. |
| **3** | `feat: capture open apps with Siri and Shortcuts` | `CaptureOpenAppsIntent`, `AddOpenAppsIntent`, `GroupIntentHandling` additions, one App Shortcut (6/10), README Siri section. | Shortcuts app runs both, returns the group entity, leaves itself out; Siri phrase works; archived group error unchanged. |
| **4** | `feat: translate capture keys to all languages` | The new prefixes in the 25 translations (one pass per language, reviewed); `awaitingTranslation` back to `[]`; `docs/l10n-keys.md`. | `LocalizationTests` green, no awaiting prefixes. |

Release order: PR 1 can merge any time (nothing visible; preferences unchanged until a setting is
changed). PRs 2–4 ship together. The version bump (`build: version 0.10.0`, build 1000) isn't part
of this plan: it follows when 0.10.0 is cut (Decision 7), then the `v0.10.0` tag → CI's notarized
universal DMG as a **draft** → the `release` environment approval → the user's explicit approval to
publish. Manual gates to record before tagging: the PR 1 spike and the §6 manual list.

---

## 9. DECISIONS

Recorded 2026-10-25 by the user; each one is final for this spec. (User-decided.)

1. **Review step.** **Decision (2026-10-25):** Capture always shows the review sheet; there is no
   ⌥-click one-click capture. Siri and the Shortcuts app are the only paths without a sheet.
   (User-decided.) One visible review keeps unwanted apps out of a new group.
2. **Finder and protected apps.** **Decision (2026-10-25):** Finder is never listed (Add Apps… can
   still add it); protected apps are listed but not selected. (User-decided.) Protected apps are the
   all-day apps (mail, chat, a password manager), which are rarely part of one task.
3. **Name suggestion.** **Decision (2026-10-25):** The suggestion is "Xcode +3" (the first selected
   app and how many more), made unique among groups. (User-decided.) It names the group after the
   app that matters and needs no plural forms, so every language reads it the same.
4. **The window option.** **Decision (2026-10-25):** "Select only apps with open windows" is off by
   default and only changes which apps start selected; it never hides or removes an app. (User-decided.)
   Window data is a heuristic without Accessibility, so it must not decide eligibility (R1).
5. **Siri phrase and link.** **Decision (2026-10-25):** Both intents appear in the Shortcuts app; one
   App Shortcut carries Siri phrases for New Group from Open Apps (6 of the 10 allowed); `capture`
   links only open the sheet. (User-decided.) A phrase for the main action fits the limit, and a link
   that only shows the sheet cannot write anything.
6. **Where the settings live.** **Decision (2026-10-25):** The order and the window option live only
   in the sheet, remembered in `preferences.json`; there is no Settings pane. (User-decided.) Two
   controls used only from the sheet don't justify a new Settings section.
7. **Release.** **Decision (2026-10-25):** Capture ships on its own as 0.10.0 once PR 4 lands;
   triggers (phase 4b) follow in a later release. (User-decided.) Capture is complete without
   triggers, so it ships first.
