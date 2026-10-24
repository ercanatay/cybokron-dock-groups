# Design spec: group shortcuts, and duplicating, archiving and templating groups

- **Status:** design decided (2026-10-25), ready for implementation. Design only: no code. The seven decisions in §9 were
  made by the user on 2026-10-25.
- **Baseline:** `main` at `8127967` (version 0.8.0, `project.yml` `MARKETING_VERSION: "0.8.0"`),
  906 `@Test` functions, 677 `en.lproj` keys, `LocalizationTests.awaitingTranslation` empty.
- **Features:** G (a global keyboard shortcut per group) and I (Duplicate, Archive and Templates).
  Target release: **0.9.0**.
- **Builds on:** `docs/design/group-items-and-tags-spec.md` (A+F, 0.7.0) and
  `docs/design/context-switching-spec.md` (C+D+E, 0.8.0). Their Core/App split, lenient JSON
  rules, backup sanitizing, agent snapshot normalization, downgrade protection and PR format are
  reused; C+D+E §3.7 left notes for G that this spec follows.
- **Clean room:** behavior comes from the written acceptance criteria and this repository only.
  Claims about current code cite `file:line` at `8127967` (paths relative to `Sources/` unless they
  start with `Tests/`, `docs/` or name a file at the repository root).

## Acceptance criteria (behavior)

G, group shortcuts:

- **G-1** Any group can have one global keyboard shortcut. Pressing it, in any app, does the
  action chosen for it: **show the popup** (the default; pressing again closes it), **Open All**, or
  **Start** (Finish when the group is current).
- **G-2** A shortcut is a key plus at least two of Control, Option and Command (Shift may be added).
  Keys that typing, editing or macOS itself need are refused, whoever sets them: the recorder,
  `groups.json`, a backup.
- **G-3** Two groups never share a shortcut; a group shortcut never takes the keys of the number
  shortcuts (⌃⌥1…9, I6) or of a macOS shortcut. When it can't be turned on, the group window and
  Settings say why, and nothing else changes: the number shortcuts keep working as hot keys.
- **G-4** Group shortcuts are hot keys like I6: no Accessibility access, no prompt, ever. If one
  can't be registered, only that one is off; there is no event-monitor fallback for them.
- **G-5** A shortcut never acts on its own: only a key press does something. A Start or Finish
  from a shortcut that would quit apps asks first (§1.4, Decision 1).

I, Duplicate, Archive and Templates:

- **I-1** **Duplicate** makes a new group with a new identity, the same items (with their details
  and launch options) and settings, named "<name> copy" (then "copy 2", …). It isn't standalone and
  has no shortcut.
- **I-2** **Archive** hides a group without deleting it. An archived group isn't in the popup, the
  menu bar menu, Tab order, the number shortcuts, Siri suggestions, links or Focus filters; its
  shortcut is off; it has no standalone app. The group window lists it under **Archived**, where it
  can be **restored** (at the end of the list, as it was) or deleted.
- **I-3** **Save as Template** keeps a copy of a group's items and settings; **New Group from
  Template** makes a group from it. Templates are listed, renamed and deleted in **Manage
  Templates**.
- **I-4** Nothing in an archived group or a template opens, runs or is looked up on disk until the
  user restores the group or makes a group from the template; then the usual launch checks apply.
- **I-5** Version 0.8.0 reads the files 0.9.0 writes without errors: it ignores shortcuts and
  templates, and shows archived groups as ordinary groups at the end of its list.

Non-goals (this wave): more than one shortcut per group; shortcuts for Hide All, Close All or
items; shortcuts in standalone groups' own apps; built-in starter templates (Decision 7);
sharing a single template as a file; editing a template in place; Siri, links or Focus for
templates or archiving; time-based auto-archiving; iCloud sync (P).

---

## 0. Summary and scope

### 0.1 Summary

Two small features finish the "workspace" story: a group can be reached by its own key, and the
list stays tidy without losing work. Three decisions carry most of the weight:

1. **Archived groups leave `GroupStore.groups` but not `groups.json`** (§2.3, §2.9). The store
   publishes active groups as `groups`, exactly as today, and archived ones separately as
   `archivedGroups: [ArchivedGroup]`. About 70 references in 13 files read `store.groups`,
   `store.group(withID:)` or `$groups` (menus, popup, Tab order, number shortcuts, links, Siri,
   Focus, agents, delayed launches, the session); all of them ignore archived groups without a
   change, so a forgotten filter can't expose one (fail closed).
   On disk, archived groups stay in the same `groups` array, after the active ones, marked
   `"archived": true`: 0.8.0 shows them as ordinary groups instead of dropping them on its next save.
2. **Shortcuts are planned in Core, as a pure function, and registered one by one under their own
   Carbon signature** (§2.4, §2.5). Static rules (key, modifiers, built-in reserved keys) are
   enforced when data is read: a shortcut that breaks them is dropped. Rules that depend on the
   moment (number shortcuts, macOS shortcuts, another group) are evaluated at registration, turning
   into a visible status. The number shortcuts stay all-or-none and are registered first; a group
   shortcut can't make them fall back to event monitors.
3. **Templates live in their own file, `templates.json`** (§2.8), holding a normalized `DockGroup`
   per template. 0.8.0 never opens that file, so templates survive any downgrade untouched, and the
   blueprint reuses `DockGroup`'s lenient coding and the backup sanitizer.

### 0.2 Scope

| In | Out (and where it would go) |
| --- | --- |
| One shortcut per group, with an action: popup, Open All, Start/Finish (G) | Several shortcuts per group; shortcuts for items, Hide All, Close All |
| Recorder in the group window, overview in Settings → Shortcuts & Siri | A new Settings pane |
| Conflict rules: number shortcuts, macOS shortcuts, other groups (G) | Detecting other apps' menu shortcuts (impossible without Accessibility) |
| Duplicate (I) | Duplicate across Macs or as a file |
| Archive, restore, delete from the archive (I) | Auto-archive by age or schedule |
| Save as Template, New Group from Template, Manage Templates (I) | Built-in starter templates, template files, editing a template in place |
| Archived groups and templates in backups | Siri, links or Focus to archive, restore or instantiate |

### 0.3 Current-state inventory (what this wave builds on)

| Area | Where | What it does today |
| --- | --- | --- |
| Number shortcuts (I6) | `DockGroupsCore/Shortcuts/GroupHotKeys.swift:97-114` | 18 hot keys (number row and keypad 1…9) with one modifier set, registered all or none |
| Hot key system | `DockGroupsCore/Shortcuts/GroupHotKeys.swift:48-58`, `CybokronDockGroups/Shortcuts/CarbonHotKeys.swift:12-57` | one `onPress` closure; `unregisterAll()` drops every hot key of the process |
| Registrar wiring | `GroupHotKeys.swift:84-89` | the registrar sets `system.onPress` in its `init`: a second registrar would take it over |
| Fallback | `CybokronDockGroups/Shortcuts/GlobalShortcutMonitor.swift:78-116` | when a hot key fails, event monitors; the local one swallows ⌃⌥digit (`:107-113`) |
| Number → group | `DockGroupsCore/Shortcuts/GroupShortcuts.swift:60-63`, `CybokronDockGroups/App/AppDelegate.swift:384-390` | digit *n* is the *n*-th group of `store.groups`: positional |
| Modifier sets | `GroupShortcuts.swift:4-17` | `controlOption`, `optionCommand`, `controlCommand`, `controlOptionCommand`: two of ⌃⌥⌘ each |
| Shortcut prefs | `DockGroupsCore/Model/PopupPreferences.swift:34-37`, `:160-161` | `globalShortcutsEnabled`, `globalShortcutModifiers` |
| Settings → Shortcuts & Siri | `CybokronDockGroups/Settings/ShortcutsSettingsView.swift:24-36`, `:101-127` | keyboard section, number assignments, Siri phrases, links |
| Settings panes | `CybokronDockGroups/Settings/SettingsWindowController.swift:121-130` | Popup, Shortcuts & Siri, Switching, Most Used, Updates, Backup, Changelog, Support |
| Group model | `DockGroupsCore/Model/DockGroup.swift:13-31`, `:108-110` | `id, name, emoji, apps, tile, isPinned, isStandalone, popup, freeLayoutSlots, switching` |
| Group coding | `DockGroup.swift:114-149` | `id`, `name` required; the rest lenient; unknown keys ignored; defaults not written |
| Store | `DockGroupsCore/Store/GroupStore.swift:32`, `:52-54`, `:102-114` | one `groups` array; `group(withID:)`; `updateGroup` keeps invariants |
| New names | `GroupStore.swift:62-72`, `:479-487` | only default names are made unique; `renameGroup` accepts any name (`:76-83`) |
| Merge | `GroupStore.swift:355-375` | backup groups skipped by name (case-insensitive) or id, against `groups` only |
| Groups file | `DockGroupsCore/Persistence/GroupPersistence.swift:32-42`, `:57-69` | `{formatVersion: 1, groups: […]}` |
| JSON writer | `DockGroupsCore/Persistence/JSONFileSupport.swift:11-19` | default `JSONEncoder` date strategy (seconds since 2001), unlike backups (ISO 8601) |
| Backups | `DockGroupsCore/Persistence/SettingsBackup.swift:165-180`, `:259-291` | `sanitizedForImport` per group; document `groups` + `preferences` |
| Restore, merge | `DockGroupsCore/Store/SettingsBackup+Stores.swift:20-43` | Replace All: preferences, then groups (rolled back together); Merge: groups only |
| Agents | `DockGroupsCore/Standalone/AgentConfiguration.swift:21-30` | snapshot normalized (`switching` reset, protected apps reduced) so unrelated edits don't rebuild |
| Standalone sync | `CybokronDockGroups/Standalone/StandaloneController.swift:197-200`, `:179-189` | a group gone from `store.groups` is "turned off or deleted": agent quit, removed; a standalone group without a Dock tile is turned off |
| Intents | `CybokronDockGroups/Intents/GroupIntentSupport.swift:30-36`, `:40-50`; `Intents/GroupEntity.swift:31-51` | groups from the handler, or read from disk before it's set |
| Session | `DockGroupsCore/Switching/ContextSwitcher.swift:62-64` | the session forgets groups missing from `store.groups` |
| Triggers | `DockGroupsCore/Switching/TransitionPlanner.swift:5-22`; `Switching/TransitionConfirmation.swift:87-93` | `userAction, link, intent, focus`; the alert's source line always says "a link" |
| Menu bar menu | `CybokronDockGroups/MenuBar/StatusBarController.swift:171-224` | group item plus ⌥, ⇧⌥, ⌃⌥ alternates (empty key equivalents, modifier masks) |
| Group window | `CybokronDockGroups/MainWindow/GroupSidebarView.swift:22-101`, `GroupDetailView.swift:91-98` | sidebar with context menu (Open All, Hide All, Rename, Delete) and +/−; sections Group, Items, Start and Finish, Dock Tile, Standalone, Popup |
| Downgrades | `DockGroupsCore/Updates/DowngradeProtection.swift`, `Updates/ReleaseHistory.swift:29-37` | copies `groups.json` and `preferences.json` before installing a version older than 0.8.0 |

### 0.4 What C+D+E left that matters here

- C+D+E §3.7: "Start keys must be separate registrations whose failure doesn't fall back for the
  popup keys", and two-modifier sets plus Shift collide with ⌃⌘⇧3/4 (screenshots). §2.4 and §2.5
  turn both into rules.
- C+D+E §2.5: only links and Siri ask before quitting; a click doesn't. A key press sits between
  the two (§1.4).
- C+D+E §3.9: every new per-group field is normalized out of `AgentConfiguration` unless the agent
  uses it. Shortcuts follow that rule; archive and templates add nothing to agents.

---

## 1. User behavior

### 1.1 Words used in this spec and in the app

| Term | Meaning |
| --- | --- |
| **Number shortcuts** | The existing ⌃⌥1…9 (I6), positional: the *n*-th group. Settings calls them "Shortcut keys". |
| **Group shortcut** | One group's own keys, set in its settings. Shown as "Keyboard Shortcut". |
| **Action** | What a group shortcut does: Show the Popup, Open All, Start (Finish when current). |
| **Archived group** | A group kept but hidden everywhere except the group window's Archived list. |
| **Restore** | Bring an archived group back to the end of the list. |
| **Template** | A saved copy of a group's items and settings that new groups are made from. |

### 1.2 Assigning a shortcut

1. Group window → the group → **Keyboard Shortcut** section (new, after Start and Finish).
2. Click the recorder field: it shows "Type a shortcut" and the modifiers held so far. While it
   records, all of the app's hot keys (number and group shortcuts) are paused, so the keys reach it.
3. Press the keys. **Escape** cancels, **Delete** removes the shortcut; clicking elsewhere, closing
   the window or switching apps cancels. The hot keys come back as soon as recording ends.
4. The keys are checked at once (§1.3). Refused keys leave the previous shortcut as it was and say
   why under the field; accepted keys are saved and registered right away.
5. **When pressed**: Show the Popup (default), Open All, or Start (Finish when current).
6. The status line under the field says whether it works (§1.5).

Settings → Shortcuts & Siri gets a read-only **Group Shortcuts** section: each group with a
shortcut, its keys, action and status, and a **Change…** button that opens the group window on that
group. Setting shortcuts in the group window follows C+D+E §3.10 ("per-group settings … are in the
group window"); the overview keeps the Shortcuts pane the one place that lists every key the app
takes (Decision 3).

### 1.3 Rules for the keys

Applied by the recorder, when `groups.json`, a backup or a template is read, and at registration.

| # | Rule | Kind | Refusal text (en-US) |
| --- | --- | --- | --- |
| K1 | At least two of ⌃, ⌥, ⌘ (⇧ may be added, doesn't count) | static | "Use at least two of Control (⌃), Option (⌥) and Command (⌘), so the shortcut doesn't take keys that apps and typing need." |
| K2 | The key is a letter, digit, punctuation, keypad key, F1–F20, an arrow, Home, End, Page Up or Page Down; not Escape, Return, Enter, Tab, Space, Delete, Forward Delete, Help, Caps Lock, fn, a modifier, a media or input-source key | static | "Escape, Return, Tab, Space and Delete can't be part of a group shortcut." |
| K3 | Not one of the built-in reserved shortcuts (§2.4) | static | "macOS uses ⌥⌘Esc. Choose another shortcut." |
| K4 | Not an enabled macOS shortcut (System Settings → Keyboard → Keyboard Shortcuts) | dynamic | "macOS uses ⌃⌥Space (System Settings → Keyboard → Keyboard Shortcuts). Choose another shortcut." |
| K5 | Not a number shortcut while those are on (same key code and exactly the same modifiers; number row and keypad) | dynamic | "⌃⌥3 shows the third group's popup (Settings → Shortcuts & Siri). Choose another shortcut, or change the number shortcuts' keys." |
| K6 | No other active group has it | dynamic | "“Design” already uses ⌃⌥D." |

Static rules never change: data breaking them is dropped when it's read (§2.9). Dynamic rules can
change after the shortcut was set (the user turns on a macOS shortcut, changes the number keys, a
backup merges in another group): the shortcut is kept and shown as off, with the reason (§1.5).
Keys are physical keys (virtual key codes, as I6's), shown with the current keyboard layout's
character.

### 1.4 What a press does

| Action | Press | Again |
| --- | --- | --- |
| **Show the Popup** (default) | toggles the group's popup, as a number shortcut does | closes it |
| **Open All** | opens the group's items, launch options included (C+D+E §2.9) | opens what isn't open; harmless |
| **Start** (Finish when current) | starts the group (C+D+E §2.2); when it's current and was started at least 3 seconds ago, finishes it | the 3-second rule absorbs a double press |

- Presses of the same shortcut within 0.4 seconds count once (key repeat, bouncing keys).
- Start and Finish from a shortcut run with a new trigger, **`.shortcut`**: they may quit apps,
  and **ask first** when they would, with the link alert (Cancel, Hide Instead, Quit and Switch;
  confirm button after 0.7 s). Hiding settings, the default, never ask. A key press can be
  accidental and doesn't show what it does, unlike a labelled button (Decision 1). The
  alert's source line: "A keyboard shortcut asked for this."
- Shortcuts work while Cybokron Dock Groups runs; standalone groups' own apps don't register any.
- Hot keys take the key press: the app in front doesn't receive it (as I6). Other apps' global
  hot keys with the same keys still fire too (registration isn't exclusive).

### 1.5 Statuses (group window and Settings overview)

| Status | Text (en-US) |
| --- | --- |
| on | "✓ Works in every app while Cybokron Dock Groups is running. The app in front doesn't receive ⌃⌥C." |
| number shortcut | "⚠ Off: ⌃⌥3 is also a number shortcut, which comes first." |
| another group | "⚠ Off: “Design”, earlier in the list, uses the same keys." |
| macOS | "⚠ Off: macOS uses these keys (System Settings → Keyboard → Keyboard Shortcuts)." |
| registration failed | "⚠ Off: macOS didn't accept these keys (error -9878). Another app may have reserved them." |
| limit | "⚠ Off: at most 100 group shortcuts can be on at once." |
| paused | "Paused while a shortcut is being recorded." |

No alert ever appears for a status: a shortcut going off at launch isn't worth interrupting the
user, and the reason is where they look for it. The menu bar menu's group tooltip adds the group
shortcut when it's on ("Show “Coding” (⌃⌥C)"); it isn't set as the item's key equivalent, which
would break the ⌥, ⇧⌥ and ⌃⌥ alternates (`StatusBarController.swift:171-224`).

### 1.6 Duplicate

- Sidebar context menu → **Duplicate**. The copy is added **at the end of the list** and selected.
  It's never inserted next to the original: that would shift the number shortcuts of every group
  after it.
- Name: "Coding copy"; if taken, "Coding copy 2", "Coding copy 3" … Duplicating "Coding copy"
  gives "Coding copy 2", not "Coding copy copy". Taken means any active or archived group's name,
  ignoring case and surrounding spaces (`GroupStore.mergeName`, `GroupStore.swift:379-381`).
- Copied: emoji, items (all kinds, with alias, tags, task notes and launch options), Free Layout
  cells, Dock tile, pinning, popup overrides, Start and Finish settings.
- Not copied: identity (new UUID, so Siri shortcuts, Focus filters and links naming the original
  keep naming the original), Standalone (off: no agent build, no Dock restart), the shortcut.
- No dialog; one save.

### 1.7 Archive

- Sidebar context menu → **Archive**. No question for a regular group: archiving is reversible.
- A **standalone** group asks first, because its Dock icon goes away:

  ```
  Archive “Coding”?
  Its own app and Dock icon are removed until you restore it. The group, its items and its
  settings are kept.
                                                            [Cancel]  [Archive]
  ```

- Archiving never touches running apps. What changes:

  | Where | Effect |
  | --- | --- |
  | Popup, menu bar menu, Tab order | gone; an open popup of it closes |
  | Number shortcuts | the groups after it move up one digit (Settings' footer says so) |
  | Its group shortcut | unregistered; kept with the group for a restore |
  | Current group | if it was current, no group is current (as for a deleted group); the previous group isn't shown again |
  | Delayed launches | its pending items are cancelled |
  | Standalone app | quit and removed, Dock tile removed (one Dock restart); remembered for a restore |
  | Links, Siri, Shortcuts app | "no group matches" (links beep); Siri says it's archived (§2.11) |
  | Focus filters naming it | do nothing (logged), as for a deleted group |
  | Backups | included, still archived |

### 1.8 The Archived list, restore and delete

- The sidebar ends with a collapsed **Archived (2)** disclosure; archived rows are dimmed, newest
  first, not draggable, take no item drops.
- Selecting one shows a read-only summary (§3.4): name, emoji, when it was archived, its item names
  and kinds, its shortcut (off), whether its Dock icon comes back. No icons are looked up, no
  presence is checked, no Quick Look or Show in Finder: nothing of it touches the disk.
- **Restore** puts it at the end of the active list, selected, with all its settings.
  - A standalone group gets its app and Dock icon back (the Standalone toggle's path, with its
    failure alert) (Decision 4).
  - If another active group took its shortcut meanwhile, the restored group loses it, and says so:

    ```
    “Coding” is back without its keyboard shortcut
    “Design” uses ⌃⌥C now. Choose another shortcut in “Coding”'s settings.
                                                                    [OK]
    ```

  - The name is kept even if an active group has the same one (renaming allows that too); links
    then match the first in list order, as today (`GroupLookup.swift:32-43`).
- **Delete…** asks as deleting a group does today ("Delete “Coding”?").

### 1.9 Templates

- Sidebar context menu → **Save as Template…** opens a sheet:

  ```
  Save “Coding” as a Template
  Template name  [ Coding                                ]
  A template keeps the group's items, with their details and launch options, and its Dock tile,
  popup, and Start and Finish settings. Groups made from it don't get its keyboard shortcut or its
  own Dock icon.
                                                            [Cancel]  [Save]
  ```

  - Same name as a template (ignoring case): "A template named “Coding” already exists. Replace it
    with this group?" [Cancel] [Replace].
  - At 50 templates, Save is disabled: "You can keep up to 50 templates. Delete one in Manage
    Templates… first."
- The sidebar's **+** becomes a button with a menu (click: New Group, as today):
  **New Group**, **New Group from Template ▸** (the templates by name; "No Templates" when empty),
  **Manage Templates…**.
- A group made from a template: new UUID, at the end of the list, selected; named as the template,
  or "Coding 2", "Coding 3" … when taken; not standalone, no shortcut. Nothing opens.
- **Manage Templates…** (sheet): each template with emoji, item count and save date; New Group,
  Rename…, Delete… ("Delete the template “Coding”? Groups made from it aren't affected.").
  To change a template: make a group from it, edit, Save as Template with the same name, Replace.
- Templates don't follow later edits of the group they came from, and don't change groups made from
  them. A file or folder of a template that has moved shows as missing in the new group (A+F F1-4).

### 1.10 Backups

- Export includes archived groups (marked) and templates.
- **Replace All** replaces the archived groups too; templates are replaced **only if the backup has
  templates** (a backup from 0.8.0 or earlier has none, so current templates stay). The summary
  says so: "Your 2 archived groups are replaced. The backup has no templates; yours are kept."
- **Merge** adds the backup's groups (active or archived) whose name or identifier no group here
  has, active or archived, and templates whose name or identifier no template here has. A merged
  group whose shortcut another group already has comes in without it: "1 group came in without its
  keyboard shortcut: another group uses those keys."
- Imported shortcuts pass K1–K3; templates and archived groups pass `sanitizedForImport` exactly as
  groups do (left-out items, refused openers) (Decisions 5 and 6).

Other en-US drafts sit with their sketches: Settings footers (§3.2), the archived detail (§3.4),
Siri's error (§2.11) and the downgrade warning (§2.9).

---

## 2. Architecture

### 2.1 Layers and files

| Layer | New or changed | Purpose |
| --- | --- | --- |
| Core model | `Model/GroupShortcut.swift` (new) | `KeyModifiers`, `KeyCombination`, `GroupShortcutAction`, `GroupShortcut` + coding and static rules |
| Core model | `Model/ArchivedGroup.swift` (new) | `ArchivedGroup`, `StoredGroups` |
| Core model | `Model/GroupTemplate.swift` (new) | the template value |
| Core model | `Model/GroupNaming.swift` (new) | "copy" and numbered unique names |
| Core model | `DockGroup.swift` (changed) | `shortcut: GroupShortcut?`, key `"shortcut"` |
| Core shortcuts | `Shortcuts/ReservedShortcuts.swift`, `Shortcuts/GroupShortcutPlanner.swift` (new) | built-in reserved list, validator, pure plan and statuses |
| Core shortcuts | `Shortcuts/GroupHotKeys.swift` (changed) | signature-scoped unregistering; the registrar gains the group set, suspend/resume, press debounce |
| Core store | `GroupStore.swift`, `GroupPersistence.swift` (changed) | archive, restore, duplicate, from template, shortcuts; `StoredGroups` on disk |
| Core store | `Store/TemplateStore.swift`, `Persistence/TemplatePersistence.swift` (new) | `templates.json` |
| Core persistence | `SettingsBackup.swift`, `SettingsBackup+Stores.swift`, `AgentConfiguration.swift`, `DowngradeProtection.swift`, `ReleaseHistory.swift` (changed) | backups, agent snapshot, downgrades |
| Core switching | `TransitionPlanner.swift`, `TransitionConfirmation.swift`, `ContextSwitcher.swift` (changed) | `.shortcut` trigger |
| App | `Shortcuts/CarbonHotKeys.swift`, `Shortcuts/GlobalShortcutMonitor.swift` (changed); `Shortcuts/SystemShortcuts.swift`, `Shortcuts/KeyNames.swift`, `MainWindow/ShortcutRecorder.swift` (new) | Carbon, macOS shortcut list, key names, recorder |
| App | `GroupDetailView.swift`, `GroupSidebarView.swift`, `MainWindowView.swift`, `ShortcutsSettingsView.swift`, `StatusBarController.swift`, `AppDelegate.swift`, `GroupEntity.swift`, `GroupIntentSupport.swift`, `SettingsBackupController.swift` (changed); `MainWindow/ArchivedGroupView.swift`, `MainWindow/TemplateSheets.swift` (new) | surfaces |

### 2.2 Model

```swift
/// Modifier keys of a key combination; Caps Lock, fn and the keypad flag never count.
public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public static let control = KeyModifiers(rawValue: 1 << 0), option = KeyModifiers(rawValue: 1 << 1)
    public static let shift = KeyModifiers(rawValue: 1 << 2), command = KeyModifiers(rawValue: 1 << 3)
    public var symbols: String                          // "⌃⌥⇧⌘" order, as ShortcutModifiers.symbols
    public var carbonBits: UInt32                       // controlKey | optionKey | shiftKey | cmdKey
    /// How many of control, option and command are held (shift doesn't count, rule K1).
    public var commandLikeCount: Int
}

/// A physical key (virtual key code) with exactly these modifiers, as Carbon matches hot keys.
public struct KeyCombination: Hashable, Sendable {
    public let keyCode: UInt16                          // 0…127
    public let modifiers: KeyModifiers
}

public enum GroupShortcutAction: String, Codable, CaseIterable, Sendable {
    case showPopup, openAll, startOrFinish
}

public struct GroupShortcut: Hashable, Sendable {
    public let keys: KeyCombination
    public var action: GroupShortcutAction = .showPopup
    /// Rules K1–K3; `nil` when the keys may be a group shortcut.
    public static func staticRefusal(for keys: KeyCombination) -> GroupShortcutRefusal?
}

public enum GroupShortcutRefusal: Equatable, Sendable {
    case tooFewModifiers, keyNotAllowed, reserved            // static (K1–K3)
    case systemShortcut, numberShortcut(digit: Int), takenByGroup(DockGroup.ID)   // dynamic (K4–K6)
}

extension DockGroup {
    public var shortcut: GroupShortcut?                  // new stored property, key "shortcut", omitted when nil
}

/// A group kept out of sight (I-2): never in `GroupStore.groups`.
public struct ArchivedGroup: Identifiable, Hashable, Sendable {
    public var group: DockGroup                          // isStandalone is false while archived
    public let archivedAt: Date?                         // nil when the file's date was unreadable
    /// It was standalone when archived: restoring turns Standalone on again (Decision 4).
    public let restoresStandalone: Bool
    public var id: DockGroup.ID { group.id }
}

/// What the groups file holds: the active list, in order, and the archived groups.
public struct StoredGroups: Equatable, Sendable {
    public var active: [DockGroup]
    public var archived: [ArchivedGroup]
}

/// A saved blueprint of a group (I-3).
public struct GroupTemplate: Identifiable, Hashable, Sendable {
    public static let maximumCount = 50
    public let id: UUID
    public let savedAt: Date?
    /// Normalized: its id is the template's, not standalone, no shortcut.
    public private(set) var group: DockGroup
    public var name: String { group.name }
    public init(saving group: DockGroup, name: String, id: UUID = UUID(), at date: Date = Date())
    /// A new group from the blueprint: new UUID, `name`, everything else copied.
    public func makeGroup(named name: String) -> DockGroup
}

public enum GroupNaming {
    /// "Coding copy", "Coding copy 2"…; a trailing localized "copy [n]" is stripped first.
    public static func copyName(of name: String, taken: Set<String>) -> String
    /// `name`, or "name 2", "name 3"… (as `GroupStore.nextDefaultName`, `GroupStore.swift:479-487`).
    public static func uniqueName(_ name: String, taken: Set<String>) -> String
}
```

The archive flag lives in `ArchivedGroup`, not in `DockGroup`: every `DockGroup` the app hands
around is active by construction, so no consumer can forget to check a flag.

### 2.3 `GroupStore` extensions

```swift
@Published public private(set) var groups: [DockGroup]                 // unchanged meaning: active only
@Published public private(set) var archivedGroups: [ArchivedGroup]     // new
public func group(withID:) -> DockGroup?                               // unchanged: active only
public func archivedGroup(withID:) -> ArchivedGroup?
@discardableResult public func duplicateGroup(_ id: DockGroup.ID) -> DockGroup?
@discardableResult public func archiveGroup(_ id: DockGroup.ID, at: Date = Date()) -> ArchivedGroup?
@discardableResult public func restoreGroup(_ id: DockGroup.ID) -> GroupRestoreResult?   // .group, .removedShortcut
public func deleteGroup(_ id: DockGroup.ID)                            // active or archived
@discardableResult public func addGroup(from template: GroupTemplate) -> DockGroup
@discardableResult public func setShortcut(_ shortcut: GroupShortcut?, forGroup id: DockGroup.ID) -> GroupShortcutAssignment
// .assigned, .unchanged, .refused(GroupShortcutRefusal) (K1–K3, K6 only: the store knows no
// preferences or macOS shortcuts), .unknownGroup (archived or missing)
```

- **Invariants** (enforced by every mutation, including `updateGroup` and restores): ids unique
  across active and archived groups; no two active groups share `shortcut.keys`; an archived group
  isn't standalone. `updateGroup` keeps the original shortcut when the edited one breaks K1–K3 or
  K6. Archived groups can't be edited (`updateGroup`, item edits, moves find no index): read-only
  until restored.
- Names made by the store (`nextDefaultName`, Duplicate, from template) are unique across active
  and archived groups; renames and restores keep what the user had (as today).
- Each operation is one change of `groups`/`archivedGroups` and one save.
- **Persistence protocol.** `GroupPersisting.loadGroups() -> [DockGroup]` keeps its meaning
  (active only; the intents' disk fallback, `GroupIntentSupport.swift:30-36`, uses it and stays
  correct). New: `loadStoredGroups() -> StoredGroups` (default: active from `loadGroups()`, no
  archived) and `saveGroups(_: StoredGroups)` replacing `saveGroups(_: [DockGroup])` **without a
  default implementation**, so no persistence can drop archived groups silently. `replaceGroups`
  (backup restore) takes `StoredGroups`; `mergeGroups` returns added archived groups and a
  `clearedShortcutCount`.

### 2.4 Planning shortcuts (pure, Core)

```swift
/// Shortcuts macOS uses that the symbolic list may not include, or that should be refused even
/// when the user turned them off: Force Quit ⌥⌘Esc, Lock Screen ⌃⌘Q, full screen ⌃⌘F, Character
/// Viewer ⌃⌘Space, Dock hiding ⌥⌘D, Hide Others ⌥⌘H, Minimize All ⌥⌘M, Close All ⌥⌘W, Finder
/// search ⌥⌘Space, screenshots to the clipboard ⌃⇧⌘3 and ⌃⇧⌘4, Zoom ⌥⌘8 / ⌥⌘= / ⌥⌘-,
/// Accessibility Shortcuts ⌥⌘F5. (Checked against Apple's "Mac keyboard shortcuts" article in PR 1.)
public enum ReservedShortcuts {
    public static let builtIn: Set<KeyCombination>
}

public struct NumberShortcutSettings: Equatable, Sendable {
    public let enabled: Bool
    public let modifiers: ShortcutModifiers
    /// The 18 combinations of `GroupHotKeys.all` with these modifiers, and their digits; empty when off.
    public var combinations: [KeyCombination: Int]
}

public enum GroupShortcutStatus: Equatable, Sendable {
    case on, paused, limitReached, unavailable(OSStatus)
    case off(GroupShortcutRefusal)                 // a dynamic refusal (K4–K6)
}

public struct GroupShortcutPlan: Equatable, Sendable {
    public struct Registration: Equatable, Sendable {
        public let id: UInt32                      // 1…n, this plan's hot key ids
        public let groupID: DockGroup.ID
        public let shortcut: GroupShortcut
    }
    public let registrations: [Registration]
    public let statuses: [DockGroup.ID: GroupShortcutStatus]   // before registering; failures added by the registrar
}

public enum GroupShortcutPlanner {
    public static let maximumRegistrations = 100
    /// Shared by the recorder: `nil` when `keys` may be `group`'s shortcut now.
    public static func refusal(for keys: KeyCombination, group: DockGroup.ID, groups: [DockGroup],
                               numbers: NumberShortcutSettings, system: Set<KeyCombination>) -> GroupShortcutRefusal?
    public static func plan(groups: [DockGroup], numbers: NumberShortcutSettings,
                            system: Set<KeyCombination>) -> GroupShortcutPlan
}
```

`plan`, for the active groups in list order: skip groups without a shortcut; K1–K3 again (defense
in depth: data is already filtered); K4 against `system`; K5 against `numbers.combinations`; K6
against groups planned earlier (first in list order wins, as links' name matching does); beyond
100 registrations, `limitReached`. Archived groups are never passed in. The recorder calls
`refusal` with the same inputs, so its message and the status after saving can't disagree.

### 2.5 Hot key registration

**Changes to `HotKeyRegistering`** (`GroupHotKeys.swift:48-58`): `unregisterAll()` becomes
`unregisterAll(signature: OSType)`. `CarbonHotKeys` keeps its `EventHotKeyRef`s per signature
(`[OSType: [EventHotKeyRef]]`); one Carbon handler serves both (`CarbonHotKeys.swift:48-52`).
`onPress` stays a single closure, owned by the one registrar.

**`GroupHotKeyRegistrar` grows into the owner of both sets** (one instance, one `onPress`, so a
second registrar can't steal the handler, `GroupHotKeys.swift:84-89`):

```swift
public static let groupSignature: OSType = "CDGs"          // number shortcuts keep "CDGr"
public var onGroupShortcut: ((DockGroup.ID, GroupShortcutAction) -> Void)?
public private(set) var groupStatuses: [DockGroup.ID: GroupShortcutStatus]
/// Number shortcuts, unchanged rules (all or none); unregisters and re-applies the group set
/// around them, so a group shortcut can never be registered first and make a digit fail.
public func apply(enabled: Bool, modifiers: ShortcutModifiers) -> GlobalShortcutMode
/// Group shortcuts only: unregisters "CDGs", registers each planned one alone; a failure marks
/// that group `unavailable(status)` and registration goes on. Never touches "CDGr", never falls back.
public func applyGroupShortcuts(_ plan: GroupShortcutPlan)
/// Recording: unregisters both signatures (and stops event monitors through the monitor);
/// `resume` re-applies the last settings and plan.
public func suspend()
public func resume()
```

Presses: signature "CDGr" → digits as today; "CDGs" → the id's registration in the current plan
(a table replaced at each apply) → `onGroupShortcut` unless the same id fired less than 0.4 s ago
(injected clock). Other signatures → not handled (`eventNotHandledErr`).

**`GlobalShortcutMonitor`** (App) adds: `store` (for the shortcut projection), a
`SystemShortcutListing`, `@Published groupStatuses`, `beginRecording()` / `endRecording()`, and
`onGroupShortcut`. It re-plans when the projection `[(id, shortcut)]` of active groups changes
(`removeDuplicates`, so typing a name doesn't re-register), when the number settings change, and
when the macOS list is read again. Recording ends on Escape, a recorded key, Delete, the field
losing focus, the window resigning key, or `onDisappear`; `endRecording` always runs `resume`, so
the hot keys can't stay paused (R6).

### 2.6 macOS's shortcuts (App)

`SystemShortcuts: SystemShortcutListing` reads Carbon's `CopySymbolicHotKeys` (HIToolbox,
`CarbonEvents.h`; in the macOS SDK on this Mac): the "system-wide symbolic hotkeys … defined in the
Keyboard preferences pane", each with `kHISymbolicHotKeyCode`, `kHISymbolicHotKeyModifiers` and
`kHISymbolicHotKeyEnabled`. Only enabled ones count. The header says there's "no way to determine
which hotkey … corresponds to a specific dictionary", so the message can't name it (§1.3), and
that it costs O(number of hotkeys): it's read at launch, when recording starts, and when the group
window or the Shortcuts pane appears, never per press. App-specific menu shortcuts aren't listed
and can't be read without Accessibility (R2).

`PushSymbolicHotKeyMode` (disabling macOS's shortcuts while recording) is **not** used: the same
header says it only works with assistive access enabled, which I6 set out to avoid.

### 2.7 Pressing a group shortcut (App, Core trigger)

- `AppDelegate.performGroupShortcut(id, action)`: `showPopup` → `popupController.toggle(groupID:)`;
  `openAll` → `openAll(group)`; `startOrFinish` → `switcher.finish(id, trigger: .shortcut)` when
  `session.current == id` and the start isn't repeated (`ContextSession.isRepeatedStart`), nothing
  when it is, else `switcher.start(id, trigger: .shortcut)`. Reports through
  `LaunchReportPresenter`, as the popup's buttons.
- `TransitionTrigger.shortcut` (`TransitionPlanner.swift:5-22`): `mayQuit == true`,
  `asksBeforeQuitting == true`. `ContextSwitcher.confirmed` sends it the link way, through
  `questions.askBeforeTransition` (`ContextSwitcher.swift:179-185`), so its question never shows
  together with a link's. `TransitionConfirmation.message` picks its source line by trigger: links
  keep "A link opened by another app, a script or a web page asked for this."
  (`TransitionConfirmation.swift:87-93`); shortcuts get "A keyboard shortcut asked for this."

### 2.8 Templates (`TemplateStore`, `templates.json`)

```swift
public protocol TemplatePersisting {   // as GroupPersisting: load, save, preserveUnreadableData, preserveCopy
    func loadTemplates() throws -> [GroupTemplate]
    func saveTemplates(_ templates: [GroupTemplate]) throws
}
@MainActor public final class TemplateStore: ObservableObject {
    @Published public private(set) var templates: [GroupTemplate]
    @Published public private(set) var issue: GroupStoreIssue?
    public init(persistence: TemplatePersisting, saveDelay: Duration = .milliseconds(250))
    public func save(_ group: DockGroup, named: String, replacing: Bool) -> TemplateSaveResult  // .saved, .nameTaken, .limitReached
    public func rename(_ id: UUID, to name: String) -> Bool
    public func delete(_ id: UUID)
    public func replaceTemplates(with: [GroupTemplate]) throws -> URL?     // Replace All; copies aside first
    public func mergeTemplates(_: [GroupTemplate]) throws -> Int            // Merge; by name or id
    public func flushPendingSave()
}
```

Same patterns as `GroupStore` and `PreferencesStore`: debounced atomic writes through
`JSONFileSupport`, an unreadable file moved aside (`templates.unreadable-<ts>.json`) with an issue
shown in Manage Templates, `*.pre-import-<ts>.json` copies before Replace All. Lazy in the app
delegate, like the other stores (a second copy of the app never reads it). Saved on quit.

### 2.9 Data schema and compatibility

Format versions stay **1**: `GroupsDocument`, `SettingsBackup.currentSchemaVersion`,
`PreferencesDocument`, `AgentConfiguration`; `TemplatesDocument` starts at 1. Keys are added, never
renamed; new values are written only when they differ from their defaults.

```jsonc
// groups.json: active groups first, in list order, then archived ones
{ "formatVersion": 1, "groups": [
  { "id": "…", "name": "Coding", "emoji": "💻", "apps": [ … ], …,
    "shortcut": { "keyCode": 8, "modifiers": ["control", "option"], "action": "showPopup" } },
  { "id": "…", "name": "Old Client", "emoji": "📁", "apps": [ … ], …, "isStandalone": false,
    "archived": true, "archivedAt": "2026-10-25T09:12:00Z", "restoresStandalone": true,
    "shortcut": { "keyCode": 31, "modifiers": ["control", "option"], "action": "startOrFinish" } } ] }

// templates.json (new, next to groups.json)
{ "formatVersion": 1, "templates": [
  { "id": "…", "savedAt": "2026-10-25T09:30:00Z",
    "group": { "id": "<the template's id>", "name": "Coding", "emoji": "💻", "apps": [ … ], … } } ] }

// .dockgroups backup: archived groups inside "groups", marked as in groups.json; "templates" optional
{ "schemaVersion": 1, "app": "cybokron-dock-groups", …, "groups": [ … ], "preferences": { … },
  "templates": [ … ] }
```

- `archived`, `archivedAt` and `restoresStandalone` are written by the groups file's entry type
  around `DockGroup`'s own keys (one JSON object), so `DockGroup` itself has no archive field and
  agent configurations and template blueprints can't carry one. Dates are ISO 8601 strings written
  by hand, so groups.json (default `JSONEncoder` date strategy, `JSONFileSupport.swift:16-18`) and
  backups (ISO 8601, `SettingsBackup.swift:87`) spell them the same.
- Archiving sets `isStandalone` to `false` and `restoresStandalone` to what it was. 0.8.0 then
  never sees a standalone group without a Dock tile, which it would turn off at launch
  (`StandaloneController.swift:179-189`) and save, dropping every group's archive mark.

Decoding rules:

| Saved | Result |
| --- | --- |
| no `shortcut`, or unreadable | none |
| `shortcut` with `keyCode` outside 0…127, an unknown modifier name, or breaking K1–K3 | dropped (fail closed) |
| `shortcut.action` missing or unknown | `showPopup`, the least that a press can do |
| `archived` missing, `false` or unreadable | active |
| `archived: true`, `archivedAt` missing or unreadable | archived, date unknown |
| `archived: true` and `isStandalone: true` (crafted) | archived, not standalone, `restoresStandalone: true` |
| active and archived groups interleaved | each keeps its relative order; written back active first |
| the same id twice, across both lists | the first is kept (as `sanitizedForRestore`, `GroupStore.swift:383-394`) |
| two active groups with the same keys | both kept; the later one is off (K6) until changed |
| `templates.json` unreadable | moved aside, empty list, issue shown |
| more than 50 templates | the first 50 |
| a template's `group` with `isStandalone` or `shortcut` | normalized away |
| backup without `templates` | Replace All keeps the current templates |

Older versions reading these files (I-5):

| Data | 0.8.0 and earlier | User-visible result there |
| --- | --- | --- |
| `shortcut` | unknown group key, ignored (`DockGroup.swift:114-129`) | number shortcuts as before; no group shortcuts |
| `archived`, `archivedAt`, `restoresStandalone` | unknown keys, ignored | archived groups are ordinary groups at the end of the list (so active groups keep their number shortcuts); their apps can be opened there |
| `templates.json` | never read | nothing |
| backup `templates` | unknown key, ignored (`SettingsBackup.swift:281-290`) | templates aren't imported |
| **any save there** | writes groups without the new keys | shortcuts are lost and archived groups become active for good; templates are untouched |

`DowngradeProtection` grows in PR 6: `ReleaseHistory.firstGroupShortcutsVersion = 0.9.0`,
`lacksGroupShortcuts(_:)`; `preserveCopies` applies to targets older than 0.9.0 (copying
`groups.json` and `preferences.json` as it does for 0.8.0; `templates.json` needs no copy); the
question warns when an active group has a shortcut or any group is archived:

```
Version 0.8.0 doesn't know archived groups, group shortcuts or templates. Archived groups show
there as ordinary groups, and editing groups there drops their shortcuts and which groups are
archived. A copy of your groups is kept before it's installed; templates stay for when you come back.
```

**Backups.** `SettingsBackup` gains `archivedGroups: [ArchivedGroup]` and `templates:
[GroupTemplate]?` (`nil`: the file had no `templates`). `sanitizedForImport` runs on every archived
group and every template's blueprint; shortcuts already passed K1–K3 when decoded; duplicate keys
within the backup lose their shortcut after the first (in order: active, archived). Restore copies
and writes three stores, rolling back together (preferences, groups, templates);
`SettingsRestoreSummary` gains archived and template counts and "the backup has no templates".

### 2.10 Agents and standalone groups

- `AgentConfiguration.init` sets `group.shortcut = nil`: assigning or changing a shortcut rebuilds no
  agent. Agents don't register hot keys (`Agent/AgentAppDelegate.swift:36`).
- Archive: the group leaves `store.groups`, so `StandaloneController` treats it as turned off
  (`StandaloneController.swift:197-200`): the agent is quit, removed and its Dock tile removed in
  the next pass (debounced 1.5 s, one Dock restart). Nothing new in the controller.
- Restore with `restoresStandalone`: the app calls `standalone.setStandalone(true, for:)`, the
  toggle's own path (`StandaloneController.swift:110-129`): Dock tile requested, agent built, and on
  failure Standalone off again with the existing alert.
- Duplicates and groups from templates are never standalone: no build, no Dock restart.

### 2.11 Siri, Shortcuts, links, Focus

- Links resolve through `store.groups` (`AppDelegate.swift:509-516`): an archived group isn't
  found (beep); the log adds "archived" when the name matches one. No new verbs. Settings lists
  links and phrases for active groups only.
- `GroupEntityQuery`: `suggestedEntities` and `entities(matching:)` return active groups only;
  `entities(for:)` also returns archived ones, so saved shortcuts and Focus filters keep showing
  their group's name. `GroupIntentSupport.resolve` throws a new
  `GroupIntentError.groupArchived(name:)`: "“Coding” is archived. Restore it in Cybokron Dock
  Groups to use it." (an English literal, as the existing errors, `GroupIntentSupport.swift:59-66`). `GroupIntentHandling` gains `archivedGroups`; the disk fallback
  uses `loadStoredGroups()`. `updateAppShortcutParameters` already follows active names
  (`AppDelegate.swift:183-188`). App Shortcuts stay at 5 of 10.
- Focus: `FocusRequestHandling.group(withID:)` returns active groups only, so a filter naming an
  archived group does nothing (logged). Settings → Switching's status line may say "…which is
  archived" (small, optional in PR 5).
- `cybokrondockgroups://shortcut/<n>` stays positional over active groups.

### 2.12 Localization plan

As A+F §7.1 and C+D+E §3.11: keys arrive with their code, each PR lists its prefixes in
`awaitingTranslation`, `docs/l10n-keys.md` gets sections marked "English only for now", and PR 7
translates them into the 25 languages.

| Prefix | Where | About |
| --- | --- | --- |
| `core.shortcut.` | refusals, statuses, action names, special key names | 20 |
| `core.group.copyName`, `core.switching.confirmation.shortcut` | Duplicate's name, the question's source line | 2 |
| `groupWindow.shortcut.` | Keyboard Shortcut section, recorder | 9 |
| `settings.shortcuts.groups.` | Group Shortcuts overview, footer sentence | 6 |
| `groupWindow.archive.` | menu items, Archived list, detail, questions, restore alert | 15 |
| `templates.` | menus, sheets, alerts | 18 |
| `settings.backup.library.` | import summary lines | 5 |
| `updates.otherVersions.library.` | downgrade warning | 1 |

About **76 keys** (677 → about 753). Key names shown in shortcuts come from the keyboard layout
(`UCKeyTranslate`) or are symbols (←, ⇞, F5), not translated strings.

---

## 3. UX sketches

### 3.1 Group window: Keyboard Shortcut section

```
Keyboard Shortcut
  Shortcut        [  ⌃⌥C                    ⓧ ]
  When pressed    [Show the Popup              ▾]   Show the Popup / Open All / Start (Finish when current)
  ✓ Works in every app while Cybokron Dock Groups is running. The app in front doesn't receive ⌃⌥C.

Recording:
  Shortcut        [  Type a shortcut…   ⌃⌥     ]   Escape cancels · Delete removes the shortcut
Refused (⌃⌥3 pressed; ⌃⌥C kept):
  Shortcut        [  ⌃⌥C                    ⓧ ]
  ⚠ ⌃⌥3 shows the third group's popup (Settings → Shortcuts & Siri). Choose another shortcut, or
    change the number shortcuts' keys.
Start chosen:
  ⓘ A shortcut that would quit apps asks first. Hiding, the default, doesn't.
```

The field is a button-like control with VoiceOver label "Keyboard shortcut, ⌃⌥C" and hint
"Press to record a new shortcut"; ⓧ is "Remove shortcut".

### 3.2 Settings → Shortcuts & Siri

```
Keyboard Shortcuts
  [✓] Open group popups with keyboard shortcuts
  Shortcut keys                         [⌃⌥ 1…9 ▾]
  ✓ Works in every app
Assigned Groups
  💻 Coding                                   ⌃⌥1
  🎨 Design                                   ⌃⌥2
  Shortcuts follow the order of the groups in Manage Groups. Archiving or deleting a group
  renumbers the groups after it; a group's own keyboard shortcut stays the same.
Group Shortcuts                                                        (new)
  💻 Coding      ⌃⌥C   Show the Popup     ✓                            [Change…]
  🎨 Design      ⌃⌥3   Start              ⚠ Off: number shortcut 3         [Change…]
  Each group can have its own shortcut, set in its settings. These keys work in every app while
  Cybokron Dock Groups is running, and the app in front doesn't receive them.
Siri and Shortcuts …   Links …                                          (unchanged)
```

Without any group shortcut, the section shows "No group has its own shortcut yet." and the footer.

### 3.3 Sidebar

```
┌──────────────────────────────┐
│ 💻 Coding                  8 │   context menu:
│ 🎨 Design                  5 │     Open All · Hide All · Rename…
│ 🏠 Home                    3 │     Duplicate · Save as Template…
│ ▾ Archived (2)               │     Archive
│     📁 Old Client          6 │     ──────────
│     🧪 Spike               2 │     Delete…
├──────────────────────────────┤
│ [+ ▾] [−]           3 groups │   + menu: New Group · New Group from Template ▸ · Manage Templates…
└──────────────────────────────┘
```

Archived rows: secondary text color; their context menu is Restore · Delete…; − deletes the selected
row (active or archived) after the usual question.

### 3.4 Archived group detail

```
📁 Old Client                                         Archived on October 25, 2026
Archived groups don't appear in the popup, the menu bar menu, Siri, links or Focus filters,
and their keyboard shortcut is off. Restore the group to use or edit it.

Items (6)       Xcode · Slack · cybokron (folder) · Report.pdf (file) · github.com · Figma
Shortcut        ⌃⌥O (off while archived)
Dock icon       comes back when the group is restored
                                                                  [Delete…]  [Restore]
```

### 3.5 Templates

```
Manage Templates
┌──────────────────────────────────────────────────────────────────┐
│ 💻 Coding     7 items · saved October 25, 2026      [New Group]  │
│ ✍️ Writing    3 items · saved October 20, 2026      [New Group]  │
└──────────────────────────────────────────────────────────────────┘
[Rename…] [Delete…]                                          [Done]
```

---

## 4. Security and privacy

### 4.1 Threat model

`SECURITY.md` ("Scope") names a crafted `groups.json` or `.dockgroups` backup making the app launch
unintended apps or run code. 0.7.0 and 0.8.0 closed that for items and launch options: every item
is checked every time it opens, whatever its source (A+F §2.3, C+D+E §5.3). A backup is the
realistic vector; `groups.json` and the new `templates.json` need a write into the user's Library,
but are treated the same as defense in depth. This wave adds two new surfaces: **keys the app takes
from other apps**, and **data kept out of sight**.

### 4.2 Shortcut invariants

- **K-1 No press, no action.** Reading `groups.json`, a backup or a template never performs an
  action. The only path from a shortcut to an action is a Carbon `kEventHotKeyPressed` for an id of
  the current plan.
- **K-2 No hijacking of typing, editing or menus.** K1 refuses ⌘-only, ⌘⇧, ⌥-only (typed
  characters), ⌃-only (Cocoa's text-editing keys such as ⌃A, ⌃E, ⌃K) and Shift-only combinations
  from every source; K2 refuses Escape, Return, Tab, Space and Delete; K3 and K4 refuse macOS's own. A crafted file
  setting ⌘C, ⌘V or ⌘Q gets no shortcut at all.
- **K-3 Bounded.** At most 100 group shortcuts are registered; a crafted file with thousands of
  groups can't make registration costly.
- **K-4 Least action.** An unknown action reads as Show the Popup. Open All runs the launch checks;
  Start and Finish from a key press ask before quitting (Decision 1); nothing a shortcut does
  is new capability: each action already exists behind a click.
- **K-5 No permission.** Hot keys need no Accessibility or Input Monitoring; group shortcuts never
  fall back to event monitors, and `PushSymbolicHotKeyMode` isn't used (§2.6).
- **K-6 Not exclusive.** The app never passes `kEventHotKeyExclusive`, so it never blocks another
  app's global hot key; residual: a two-modifier shortcut can take a key press meant for the front
  app's menu (R2), which the recorder text and README say.
- **K-7 Backups.** Imported shortcuts pass K1–K3 and lose their keys on a conflict; the import
  summary counts them (Decision 6).

### 4.3 Archive and template invariants

- **A-1 Archived means inert.** An archived group isn't in `store.groups`, so it can't be opened,
  started, finished, shown, hidden or quit by the popup, menus, number or group shortcuts, links,
  Siri, Focus, delayed launches (they resolve groups through `store.group(withID:)`,
  `AppDelegate.swift:30-34`), or an agent (removed).
- **A-2 Out of sight, off the disk.** The Archived detail and Manage Templates show stored names
  and counts only: no icons, presence checks, Quick Look or Show in Finder for their items.
- **A-3 Templates open nothing.** Saving or making a group from a template opens nothing; the new
  group is visible, selected, and its items are checked at launch like any group's.
- **A-4 Same sanitizing for every source.** Templates and archived groups from a backup pass
  `sanitizedForImport` (`SettingsBackup.swift:165-180`): left-out items, refused openers (folder
  terminals included) are handled as for groups. Templates saved on this Mac keep what the group
  had, as a duplicate does.
- **A-5 Restore is explicit.** Only the user's Restore makes an archived group active again. An
  `archived` value other than `true` reads as active: damaged data can only make a group visible,
  never keep one hidden while it acts.

### 4.4 Privacy

Nothing leaves the Mac. The diagnostics report adds counts only: "Group shortcuts: 3 (2 on, 1 off:
number shortcut)", "Archived groups: 2", "Templates: 3" — no names, keys or items. Logs name groups
by id (as today) and keys by symbols; no template or archived group names.

---

## 5. Performance

- **Registration.** One `RegisterEventHotKey` per group shortcut, on the main thread, only when the
  plan's inputs change: the projection of active groups' shortcuts (`removeDuplicates`; renames,
  item edits and drags don't count), the number settings, or the macOS list. Planning is O(groups)
  with a dictionary. Budget: under 10 ms for 100 shortcuts, measured in the PR 4 spike.
- **Number shortcuts** are re-registered only when their settings change (as today,
  `GlobalShortcutMonitor.swift:78-81`), plus around a recording.
- **macOS shortcuts list.** `CopySymbolicHotKeys` is O(hotkeys) per its header: read at launch, at
  recording start and when the group window or Shortcuts pane appears; cached otherwise.
- **Presses.** A dictionary lookup and a timestamp compare.
- **Agents.** Shortcut edits rebuild none (normalized). Archiving a standalone group costs one
  removal and Dock restart; restoring it, one build and restart; duplicates and template groups
  none.
- **Store.** Archive, restore, duplicate and template instantiation are one change and one save;
  the archived list doesn't feed `TileImageCache.synchronize` (`AppDelegate.swift:179-181`), popup
  refreshes or presence tracking.
- **Templates.** `templates.json` is a few KB, read once, saved debounced.

---

## 6. Test plan (`Tests/DockGroupsCoreTests`, swift-testing, no real Carbon, Dock or LaunchServices)

Suites are named as today, `@MainActor` where the code is, with fakes in a shared
`ShortcutFakes.swift` (the existing `FakeHotKeySystem` moves there, gaining
`unregisterAll(signature:)`).

- **`GroupShortcutModelTests`**: `KeyModifiers` symbols and Carbon bits; `GroupShortcut` coding
  (modifier names, omitted when nil); K1 (every one- and two-modifier set, with and without ⇧),
  K2 (each refused key), K3 (each reserved entry); unknown action → `showPopup`; malformed values
  dropped; **0.8.0 fixtures** (`Version080Fixtures`, generated by building `8127967`'s Core: groups,
  preferences, an agent configuration, a backup) decode to the same values and re-encode **byte for
  byte**.
- **`GroupShortcutPlannerTests`**: K5 against each `ShortcutModifiers` set, number row and keypad,
  numbers off → no conflict, ⌃⌥⇧3 isn't ⌃⌥3; K6 first in list order wins; K4 with a fake system
  list (disabled entries ignored); limit 100; `refusal(for:)` agrees with `plan` for the same
  inputs; archived groups can't be passed (type).
- **`GroupHotKeysTests`** (additions): number set re-applied without dropping or reordering the
  group set; a group registration failure marks only that group and leaves the number mode
  `.hotKeys`; presses dispatched by signature; ids replaced per plan; debounce 0.4 s with an
  injected clock; `suspend` unregisters both signatures and `resume` restores them exactly; the
  existing 18-key tests unchanged.
- **`ShortcutTriggerTests`**: `.shortcut` plans may quit and ask through `questions` (Hide Instead,
  Cancel); hiding plans don't ask; `startOrFinish` starts, finishes the current group after 3 s,
  ignores a repeat within 3 s; the question's source line.
- **`GroupArchiveTests`**: archive/restore/delete; `groups` and `group(withID:)` exclude archived;
  archived not editable; restore appends and clears a taken shortcut; standalone flag moves to
  `restoresStandalone`; ids unique across lists; session pruned on archive (through `ContextSwitcher`);
  persistence round trip, interleaved input, unreadable `archived`/`archivedAt`, crafted standalone
  archived; `loadGroups()` (intents' fallback) returns active only; a file without archived groups
  is byte-identical to 0.8.0's.
- **`GroupDuplicateTests`**: new id; names ("copy", "copy 2", stripping a trailing "copy n",
  case-insensitive against active and archived, localized suffix); items with details and launch
  options, Free Layout, switching copied; standalone off; shortcut nil; appended at the end; one
  save; `nextDefaultName` considers archived names.
- **`GroupTemplateTests`**: normalization on save; `makeGroup` new id and name; `TemplateStore`
  save/replace/limit/rename/delete; unreadable file moved aside; `addGroup(from:)` unique naming.
- **`SettingsBackupTests`** (additions): archived groups and templates round trip; templates absent
  vs empty; Replace All with and without templates; merge by name against active and archived;
  shortcut conflicts cleared and counted; `sanitizedForImport` applied to archived groups and
  blueprints (left-out items, runner openers); three-store rollback.
- **`AgentModelTests`** (additions): a shortcut edit doesn't make an agent `outdated`; an archived
  standalone group yields a removal in `AgentPlanner`.
- **`DowngradeProtectionTests`**, **`UpdateInstallerTests`** (additions): `firstGroupShortcutsVersion`;
  copies for targets below 0.9.0; warning only with a shortcut or an archived group.
- **`DiagnosticsReportTests`** (counts, no names), **`LocalizationTests`** (prefixes).
- **Manual (recorded in PRs 4 and 5):** shortcuts in Safari, Terminal, a full-screen app and with a
  password field focused (Secure Event Input); holding a key; Dvorak and Turkish-Q layouts (shown
  character); turning a macOS shortcut on in System Settings, then re-opening the group window;
  recording with Escape, Delete, focus loss and window close (hot keys back each time); 100
  shortcuts registration time; archive and restore of a standalone group (Dock tile out and back);
  Siri with an archived group; a backup round trip; downgrade to 0.8.0 with archived groups,
  shortcuts and templates, then back to 0.9.0. macOS 14, 15 and 26 (this Mac runs 27.0.1).

---

## 7. Risks and unknowns

| # | Risk or unknown | Effect | Mitigation |
| --- | --- | --- | --- |
| R1 | A hot key on keys macOS also uses: does it fail, fire too, or never fire? | a shortcut that silently doesn't work | K3/K4 refuse them; PR 4 spike records the behavior for a symbolic hotkey and a built-in one |
| R2 | Other apps' menu shortcuts can't be detected | ⌥⌘I (say) stops reaching Safari | recorder text and README; the user changes the keys; nothing exclusive |
| R3 | Number shortcuts are positional: archive, delete, move renumber them | ⌃⌥3 opens another group | Duplicate and templates append; Settings footer; group shortcuts are the stable way |
| R4 | Downgrade to 0.8.0: archived groups show, and a save there drops archive and shortcuts | archive lost, shortcuts lost | `restoresStandalone` avoids 0.8.0's auto-save at launch; pre-downgrade copies and warning (PR 6) |
| R5 | Replace All with an old backup removes archived groups | surprise loss | summary counts them; the `pre-import` copy |
| R6 | Recording leaves hot keys suspended | all shortcuts dead | `endRecording` on every exit path; registrar tests for suspend/resume pairs |
| R7 | Secure Event Input and key repeat behavior of Carbon hot keys | presses lost or repeated | manual test; 0.4 s debounce; 3-second Start rule |
| R8 | Keyboard layouts | shown letter differs from the key cap | physical key stored (as I6), character from the current layout |
| R9 | Crafted file with many groups and shortcuts | slow launch | 100-registration cap; static rules at decode |
| R10 | Shortcut-triggered Start asks, which may feel slow | friction | only when the plan quits; hiding (default) never asks; Decision 1 |
| R11 | `CopySymbolicHotKeys` is old Carbon API | may change in a future macOS | behind `SystemShortcutListing`; an empty list keeps K1–K3 and the built-in list |
| R12 | Templates drift from moved files | missing items in new groups | the existing missing state and Locate… (A+F F1-4) |

---

## 8. PR plan

The first PR is the **Core of G**: the hot key change touches the I6 registrar, which every user
has on by default, so it lands first, alone and fully tested, before anything can write a
shortcut. There are **8 PRs**; each keeps `scripts/test.sh` green, runs `xcodegen generate` when
files are added, and adds its keys and `awaitingTranslation` prefixes (`AGENTS.md`).

| PR | Title (Conventional Commits) | Scope | Acceptance criteria |
| --- | --- | --- | --- |
| **1** | `feat(core): keyboard shortcuts for groups` | `KeyModifiers`, `KeyCombination`, `GroupShortcutAction`, `GroupShortcut` + coding and K1–K3; `ReservedShortcuts`; `NumberShortcutSettings`; `GroupShortcutPlanner` (`refusal`, `plan`, statuses); `HotKeyRegistering.unregisterAll(signature:)`; registrar group set, suspend/resume, debounce; `GroupStore.setShortcut` and the `updateGroup` invariant; `TransitionTrigger.shortcut` and its question line; `AgentConfiguration` normalization; `Version080Fixtures`. Keys: `core.shortcut.`, `core.switching.confirmation.shortcut`. | Existing tests pass (only the fake's `unregisterAll` changes); 0.8.0 fixtures byte-identical; §6 model, planner, hot key and trigger tests pass; no UI. |
| **2** | `feat(core): archive and duplicate groups` | `ArchivedGroup`, `StoredGroups`, `GroupPersisting` changes, the groups file's entry type, `GroupStore` archive/restore/delete/duplicate, `GroupNaming`, unique default names; backup archived round trip, merge and summary; intents' disk fallback active-only. Keys: `core.group.copyName`. | §6 archive, duplicate and backup tests pass; a file without archived groups is byte-identical to 0.8.0's; no UI. |
| **3** | `feat(core): group templates` | `GroupTemplate`, `TemplatesDocument`, `TemplatePersisting` + JSON file, `TemplateStore`, `GroupStore.addGroup(from:)`; backup `templates`, three-store restore and merge. | §6 template and backup tests pass; no UI. |
| **4** | `feat: assign a keyboard shortcut to each group` | Spike first (R1, R7, layouts, timing; results in the PR). `CarbonHotKeys` per signature; `SystemShortcuts` (`CopySymbolicHotKeys`); `KeyNames`; `GlobalShortcutMonitor` group plan, statuses, recording; `ShortcutRecorder`; group window Keyboard Shortcut section; Settings → Shortcuts & Siri Group Shortcuts overview and footer sentence; `AppDelegate.performGroupShortcut`; menu tooltip; diagnostics counts; README, CHANGELOG, SECURITY.md scope line. Keys: `groupWindow.shortcut.`, `settings.shortcuts.groups.`. | Manual list (§6) for shortcuts; number shortcuts stay `.hotKeys` through every group change; no Accessibility prompt anywhere. **Must not be released without PR 6.** |
| **5** | `feat: duplicate, archive and restore groups, and make groups from templates` | Sidebar context menu (Duplicate, Save as Template…, Archive), + menu, Archived section, `ArchivedGroupView`, standalone archive question and restore via `setStandalone`, restore alert, Save as Template and Manage Templates sheets, `TemplateStore` in the app delegate (flushed on quit), Siri entity and `groupArchived`, link log, backup summaries, Focus status line (optional); README, CHANGELOG. Keys: `groupWindow.archive.`, `templates.`, `settings.backup.library.`. | Manual list (§6) for archive and templates; archived groups appear nowhere outside the group window. **Must not be released without PR 6.** |
| **6** | `feat: keep a copy of the groups before installing a version without group shortcuts` | `ReleaseHistory.firstGroupShortcutsVersion`, `DowngradeProtection` copies and warning. Keys: `updates.otherVersions.library.`. | Installing 0.8.0 from Other Versions… (dry run) copies `groups.json` and `preferences.json` and warns only with a shortcut or an archived group; the §2.9 table is verified by hand. |
| **7** | `feat: translate group shortcut, archive and template keys to all languages` | The new prefixes in the 25 translations (one translation pass per language, reviewed); `awaitingTranslation` back to `[]`; `docs/l10n-keys.md`. | `LocalizationTests` green, no awaiting prefixes. |
| **8** | `build: version 0.9.0` | `MARKETING_VERSION` 0.9.0 and build 900 in `project.yml`, `scripts/build-app.sh`, `project.pbxproj` (xcodegen); CHANGELOG `[0.9.0]`. | `scripts/check-version.sh` and CI green. |

Release order: PRs 1–3 can merge any time (nothing visible, nothing new written). PRs 4, 5 and 6
ship **together** as 0.9.0, with PR 7 (as 0.8.0 did with its translations). PR 8 last; then the
`v0.9.0` tag → CI builds the notarized universal DMG as a **draft** → the `release` environment
approval → the user's explicit approval to publish. Manual gates to record before tagging: the PR 4
spike, the §6 manual list, and the downgrade round trip.

---

## 9. DECISIONS

All seven were decided by the user on 2026-10-25 and match the recommendations this spec was
written around. They are settled, not open.

1. **Shortcut presses and quitting.** **Decision (2026-10-25):** Start or Finish from a group
   shortcut asks before quitting apps (the link alert, Hide Instead); hiding settings never ask.
   Reason: a key press can be accidental and doesn't show what it does. (User-decided.)
2. **What a shortcut can do.** **Decision (2026-10-25):** one shortcut per group with a chosen
   action: Show the Popup (default), Open All, or Start; Finish when the group is current.
   Reason: one key per group keeps the recorder and the K rules simple. (User-decided.)
3. **Where shortcuts are set.** **Decision (2026-10-25):** in the group window (new Keyboard
   Shortcut section), with a read-only Group Shortcuts overview and Change… buttons in Settings →
   Shortcuts & Siri. Reason: the shortcut belongs to the group, while the Shortcuts pane stays the
   one place that lists every key. (User-decided.)
4. **Archiving a standalone group.** **Decision (2026-10-25):** its app and Dock icon are removed,
   and restoring brings them back (`restoresStandalone`). Reason: an archived group should leave
   nothing in the Dock, and a restore should return it as it was. (User-decided.)
5. **Templates in backups.** **Decision (2026-10-25):** templates go into backups under an
   optional `templates` key; Replace All replaces templates only when the backup has them, Merge
   adds new ones. Reason: templates are user work that a restore should not lose. (User-decided.)
6. **Shortcuts from a backup.** **Decision (2026-10-25):** imported shortcuts are kept when they
   pass K1–K3; conflicting ones are cleared and counted in the import summary. Reason: a restore
   should bring back working shortcuts without ever breaking the key rules. (User-decided.)
7. **Starter templates.** **Decision (2026-10-25):** none in 0.9.0; templates come only from the
   user's own groups. Reason: built-in starters would need bundle-identifier matching and add
   scope without being needed. (User-decided.)
