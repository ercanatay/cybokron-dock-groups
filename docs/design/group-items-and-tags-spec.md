# Design spec: general group items (apps, websites, files, folders) and item details (alias, tags, task notes)

- **Status:** draft for review. Design only: no code, no commits.
- **Baseline:** `main` at `a1448db` (version 0.6.7, `project.yml` `MARKETING_VERSION: "0.6.7"`).
- **Features:** F1 (Pillar A): a group item can be an app, a website, a **file** or a **folder**.
  F2 (Pillar F): each item can have an optional **alias**, **tags** and **task notes**, and the
  popup filter finds items by them.
- **Clean room:** the behavior below comes from the written acceptance criteria and from this
  repository only. Every claim about current code cites `file:line` at `a1448db`.

## Acceptance criteria (behavior)

F1, items:

- **F1-1** A group holds any mix of apps, websites, files and folders, in one ordered list.
  Reordering, Free Layout, Sort A→Z, Move to and Remove work the same for every kind.
- **F1-2** File: a click (or Return) opens it in its default app. Other actions: **Show in Finder**
  (select it in its folder) and **Quick Look**, which only runs when the user asks for it. The app
  never reads, indexes or thumbnails file contents.
- **F1-3** Folder: a click opens it in the default file viewer (Finder). Other action: **Show in
  Finder**, which selects the folder in its parent folder.
- **F1-4** An item that was moved, renamed or deleted is shown as **missing**. It stays visible and
  removable. In the main app it can be **located** again, keeping its details and its place in the
  group.
- **F1-5** Backups: `.dockgroups` files written by 0.6.7 or earlier (apps and websites only) import
  exactly as they do today. A new backup with files and folders imports in 0.6.7 without errors.
  Items that 0.6.7 doesn't know show there as missing apps, and nothing unintended can be opened
  (§5.3).
- **F1-6** A crafted `groups.json` or `.dockgroups` file can't make a group run code through a file
  item. That covers scripts, executables, app bundles disguised as files, and location files
  (`SECURITY.md`, "Scope").

F2, details and search:

- **F2-1** Every item has an optional alias, any number of tags (typed comma-separated, within the
  limits in §1.4) and optional task notes. All three are entered by the user and stay on this Mac,
  inside the groups file and backups only.
- **F2-2** Typing in the popup finds an item by its name, alias, tags or task notes, matching tokens
  and substrings. Case, diacritics and width are ignored, as in `PopupFilter.normalize`. Matches on
  the name rank first.
- **F2-3** For a group without details, the popup filter's results are the same as today: the same
  items in the same order. New matches can only be added after them.
- **F2-4** Details are edited in the group's settings (the group window). Agents and the Most Used
  list show and search the details but don't edit them.

Non-goals: Spotlight or `NSMetadataQuery` integration; content search or thumbnails; new URL
verbs or App Intents for items; App Sandbox adoption; file items in the Most Used list.

---

## 0. Current-state inventory

### 0.1 Model: what a group item is today

There is no `GroupItem` type. **`AppReference` already is the general item**, with a two-case kind:

| Type / member | Where | What it is |
| --- | --- | --- |
| `DockGroup` | `Sources/DockGroupsCore/Model/DockGroup.swift:7` | `id: UUID`, `name`, `emoji`, `apps: [AppReference]` (display order, unique by normalized identity), `tile: TileAppearance`, `isPinned`, `isStandalone`, `popup: PopupOverrides`, `freeLayoutSlots: [String: Int]` (keyed by normalized identity) |
| `DockGroup` coding | `DockGroup.swift:101-139` | `id`, `name` required; `apps` `decodeIfPresent`; everything else `decodeLeniently` (`DockGroup.swift:142-146`); `freeLayoutSlots` written only when non-empty |
| `AppReference` | `Sources/DockGroupsCore/Model/AppReference.swift:6` | `bundleIdentifier: String` (**the item's identity**), `name`, `path: String?` (an app's fallback location), `kind: Kind` (`private(set)`); `id == bundleIdentifier` |
| `AppReference.Kind` | `AppReference.swift:8-12` | `.application`, `.website` |
| Identity rules | `AppReference.swift:14-18`, `:65` | an app has its bundle identifier, or its absolute bundle path (`"/…"`, `isIdentifiedByPath`) when it has none; a website has its normalized `http(s)` URL; they "never collide" |
| `normalizedBundleIdentifier` | `AppReference.swift:82` | lowercased identity, used for dedupe, Free Layout keys and tile keys |
| `resolvedURL(workspace:)` | `AppReference.swift:87-97` | LaunchServices lookup by bundle identifier, then `FileManager.fileExists(path)`; `nil` for websites |
| `logIdentity` | `AppReference.swift:75-78` | a website is logged by its host only (privacy) |
| `AppReference` coding | `AppReference.swift:102-143` | no `kind` means an app; a website is recognized by kind **or by its address**; an unknown kind or unreadable website is **kept as a missing app**; apps are written without `kind`; websites add `kind` and `url` |
| `WebsiteAddress` | `Model/WebsiteAddress.swift` | `parse`, `defaultName`, `looksLikeAddress` (`http://` / `https://` prefix) |

### 0.2 Persistence

| File | Where | Format |
| --- | --- | --- |
| `groups.json` | `Persistence/GroupPersistence.swift:32-43` | `GroupsDocument { formatVersion: 1, groups }`; a higher version is refused (`:61-63`), and the store then moves the file aside and starts empty (`Store/GroupStore.swift:308-340`) |
| `.dockgroups` backup | `Persistence/SettingsBackup.swift:31-36` | `schemaVersion: 1`, `app: "cybokron-dock-groups"`, 5 MB cap (`maximumFileSize`, `:36`, checked before reading `:84-92`), header read first (`:96-114`) |
| Backup import sanitizing | `SettingsBackup.swift:131-155` | `isAppBundlePath` (absolute, no `.`/`..`, no NUL, `< PATH_MAX`, ends in `.app`); `withAppBundlePathsOnly` drops path-identified apps outside app bundles and strips non-bundle fallback paths; websites pass through |
| Restore / merge | `Store/SettingsBackup+Stores.swift`, `GroupStore.swift:230`, `:259` | copies `groups.pre-import-<ts>.json` first and keeps 3 (`JSONFileSupport.copyAside`, `Persistence/JSONFileSupport.swift:31-52`) |
| Agent config | `Standalone/AgentConfiguration.swift:9-48` | `group-config.json` inside each agent bundle, `formatVersion: 1`, **embeds the whole `DockGroup`**, sorted keys (equal configs give equal bytes) |

### 0.3 Store, launcher, terminator

- `GroupStore` (`Store/GroupStore.swift`): `addApps` (`:120`), `removeApp` (`:130`), `moveApp`
  between groups (`:150`) and within a group (`:173`), `moveApps` (`:183`), `sortAppsByName`
  (`:192`), `arrangeApps` (`:200`), `updateGroup` (`:102`), `replaceGroups` / `mergeGroups`
  (`:230`, `:259`). Dedupe is always `normalizedBundleIdentifier` (`:387-390`).
- `GroupLauncher` (`Launching/GroupLauncher.swift`): `open` (`:55`) and `openAll` (`:84`) branch on
  `isWebsite` (`:56`, `:90`). Websites open in one browser request (`:135-144`).
- `ApplicationWorkspace` protocol (`Launching/ApplicationWorkspace.swift:5-23`): activate, reopen,
  locate, launch, `openWebsites`. It has no file or folder methods.
- `GroupTerminator.closeAll/hideAll` (`Launching/GroupTerminator.swift:95`, `:116`) skip websites
  through `runningInstances` (`:135-140`). `RunningApplicationLookup` returns `[]` for addresses
  (`Launching/RunningApplicationLookup.swift:10`).

### 0.4 Popup

- `PopupCell { app, icon, isInstalled }` (`CybokronDockGroups/Popup/PopupContentView.swift:23-29`).
  `isInstalled` is computed **once per popup build** in `PopupPanelController.update(for:)`
  (`Popup/PopupPanelController.swift:261`). The build runs on open and on every
  `store.$groups` / preferences / Most Used change (`:118-122`).
- Filter: `PopupFilter` (`DockGroupsCore/Popup/PopupKeyboard.swift:7-86`) normalizes text (case,
  diacritics, width, plus `ı ø ł đ ß æ œ`). It ranks the whole query against each name:
  `prefix < wordPrefix < contains`, keeping list order within a rank. It filters a `[String]` of
  names only (`PopupKeyboardState.swift:34`).
- `navigationItems(query:)` (`Popup/PopupKeyboardState.swift:32-44`) re-normalizes and re-filters
  every name **on every call**. It's called several times per keystroke: `setQuery` (`:511-514`
  of the controller), `selectedCell` (`:494-497`), `moveSelection`, `openSelection`, and twice in
  the view (`PopupContentView.swift:276`, `:664`).
- **Quick Look already exists.** `PopupQuickLook` (`PopupKeyboard.swift:147-195`) and
  `PopupPreviewController` (`Popup/PopupPreviewController.swift`) use the shared `QLPreviewPanel`
  (Quartz) with the popup panel as its controller (`Popup/PopupPanel.swift:45-55`). Space toggles it
  for the keyboard-selected **found app**. Websites and missing apps are `.notPreviewable`. The
  eligibility check `!isWebsite && resolvedURL() != nil` is written twice
  (`PopupPanelController.swift:476`, `:503`). Since 0.5.5 (`CHANGELOG.md:202-206`).
  AppKit has no `NSQuickLookPreviewPanel`; `QLPreviewPanel` is the API and is reused.
- Context menu (`PopupContentView.swift:762-797`): Open; Copy URL (websites) **or** Show in Finder
  (found apps); in editable popups also Move to, Remove from Group and Add Website….

### 0.5 Group window ("Group Settings")

- Group settings are **not** in the Settings window. They are `GroupDetailView`
  (`MainWindow/GroupDetailView.swift`), reached from the popup's gear, the "Group Settings…" menus
  and `cybokrondockgroups://settings/group/<group>` (`Commands/GroupSettingsDestination.swift`).
  Sections: Group, Apps, Dock Tile, Standalone, Popup (`GroupDetailView.swift:36-41`).
- The Apps header has six buttons: Add Apps…, Add Website…, Sort A→Z, Show Popup, Open All, Hide All
  (`:128-140`).
- `AppRowView` (`MainWindow/AppRowView.swift:12`) calls **`app.resolvedURL()` inside `body`**: a
  LaunchServices lookup plus a `stat` on every SwiftUI render. The new rules in §2.4 forbid this.
- `AppPicker` (`Support/AppPicker.swift:18`) accepts `.applicationBundle` only.
  `AddWebsiteView` is shown as a sheet (`GroupDetailView.swift:72-78`) and from a window controller
  (`Support/AddWebsite.swift:95-100`).

### 0.6 Icons, tiles, Most Used

- `WorkspaceAppIconProvider` (`Tiles/AppIconProvider.swift:16-44`) caches icons of found apps per
  normalized identity. `isInstalled` means "is a website, or `resolvedURL` isn't nil".
- `TileRenderKey` (`Tiles/TileRenderer.swift:25`) uses the identities of the first N items, so a
  grid tile shows the first N icons.
- Most Used counts **system-wide app launches** from `NSWorkspace` notifications
  (`Support/UsageMonitor.swift:26-50`). Group items aren't counted.
  `UsageTracker.isTracked` excludes website addresses (`Usage/UsageTracker.swift:34-38`).

### 0.7 Standalone agents

- Each agent runs a copy of the main executable and reads only `group-config.json`
  (`Agent/AgentAppDelegate.swift:22-26`, `:138-144`). Its `PopupPanelController` has
  `allowsEditing: false` (`:157`).
- Its Dock menu lists `group.apps` by name, enabled when running or installed (`:224-252`).
- **Any** config change rebuilds the agent bundle (`AgentPlanner.swift:118-119`, reason `outdated`):
  a full copy plus ad-hoc `codesign` and `--verify` (`AgentInstaller.swift:226-240`). Rebuilds are
  debounced 1.5 s after store changes (`Standalone/StandaloneController.swift:36`, `:98-106`).
  A changed host executable also rebuilds (`hostChanged`), so updates refresh agents.

### 0.8 Updates

`UpdateInstaller` replaces the **app bundle** only. Its `backups/` folder holds previous app bundles
(`Updates/UpdateInstaller.swift:82`, `:462-495`), not settings. It never reads `groups.json` or
`.dockgroups`. Settings → Updates → **Other Versions…** can install an **older** release
(`Updates/AutoUpdater.swift:15-16`, `Settings/OtherVersionsView.swift:4-7`), so downgrades are a
supported path.

### 0.9 Localization

- App strings go through `L10n.swift` `tr(key, english)`, Core strings through
  `Localization.string/format` (`Localization/Localization.swift`).
- `LocalizationTests`:
  - every looked-up key is in `en.lproj` with the **same English text**, and `en.lproj` has
    **no unused keys** (`Tests/DockGroupsCoreTests/LocalizationTests.swift:6`, `:164-165`);
  - each of the **25 translations** (26 `.lproj` folders) has the same keys and placeholders, except
    keys matching an `awaitingTranslation` prefix, which may be missing (`:38-42`, `:245-261`);
  - extra keys in a translation always fail (`:251`).
- `awaitingTranslation` is currently **`[]`** (`:38`).
- **Doc drift:** `docs/l10n-keys.md:674-701` still labels four sections "English only for now;
  `awaitingTranslation`: …", although those prefixes were translated and removed (commits
  `e602a63`, `10bca47`). Fix it in the first PR that edits the doc.

### 0.10 App Sandbox: not sandboxed (evidence)

- No `*.entitlements` file in the repository (`find . -name "*.entitlements"`, with `.build` and
  `build` excluded, returns nothing).
- `project.yml` has no `CODE_SIGN_ENTITLEMENTS` and no `com.apple.security.app-sandbox`. Only
  `ENABLE_HARDENED_RUNTIME: YES` (`project.yml:69`). `ENABLE_USER_SCRIPT_SANDBOXING: YES` (`:26`) is
  Xcode's build-phase script sandbox, which is unrelated.
- `scripts/build-app.sh:190-193`: "The app needs no entitlements", and `codesign … --options
  runtime` runs without `--entitlements`. Agents are signed ad hoc without entitlements
  (`AgentInstaller.swift:232`).
- **Consequence:** security-scoped bookmarks are **not needed**. They only matter under App Sandbox.
  The app reads paths with the user's own permissions, minus TCC-protected locations (§2.6).

### 0.11 Kind branching outside the model

These are the places a new kind must be taught. There are 20 sites in 12 files:

| File:line | Check | Meaning |
| --- | --- | --- |
| `Launching/GroupLauncher.swift:56, 90, 136` | `isWebsite`, `websiteURL` | how to open |
| `Launching/GroupTerminator.swift:136` | `!isWebsite` | has a process |
| `Launching/RunningApplicationLookup.swift:10` | `looksLikeAddress` | has a process |
| `Usage/UsageTracker.swift:36` | `looksLikeAddress` | counts for Most Used |
| `Tiles/AppIconProvider.swift:25, 41` | `isWebsite` | icon, presence |
| `Persistence/SettingsBackup.swift:145` | `isWebsite` | import sanitizing |
| `App/AppDelegate.swift:257` | `!isWebsite` | Accessibility prompt before restoring windows |
| `Support/RunningAppsMonitor.swift:35` | `!isWebsite` | running dot |
| `Popup/PopupPanelController.swift:476, 503` | `isWebsite` | Quick Look |
| `Popup/PopupContentView.swift:736, 738, 745-746, 771` | `isWebsite`, `websiteURL` | VoiceOver, help, menu |
| `MainWindow/AppRowView.swift:22, 43, 50, 55` | `isWebsite`, `websiteURL` | row caption, help, icon |
| `Support/AddWebsite.swift:72, 76` | construction | — |

---

## 1. Data model

### 1.1 Naming

`AppReference` keeps its name in the feature PRs. It has 167 references in 45 files, and `.apps`
has 166. Add `public typealias GroupItem = AppReference` and use `GroupItem` in **all new APIs**.
A rename to `struct GroupItem` (and `DockGroup.apps` → `items`) is an optional, mechanical,
behavior-free PR (§9, PR 8). **JSON keys never change** (`apps`, `bundleIdentifier`), because old
versions and agents read them.

### 1.2 `AppReference` / `GroupItem`

```swift
public typealias GroupItem = AppReference

public struct AppReference: Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case application
        case website
        /// A document, or a document package such as `.rtfd` / `.pages`, opened with its default app.
        case file
        /// A plain folder (not a package), opened in the default file viewer.
        case folder
    }

    /// The item's identity; JSON key `bundleIdentifier`, unchanged.
    /// - application: bundle identifier, or the bundle's absolute path ("/…") when it has none
    /// - website:     normalized http(s) address (`WebsiteAddress.parse`)
    /// - file:        `file://` URL string of its location ("file:///Users/me/Q3%20Report.pdf")
    /// - folder:      the same, always ending in "/" ("file:///Users/me/Projects/")
    /// "/" (path), "http(s)://" (website) and "file://" prefixes never collide, and bundle
    /// identifiers can't contain ":" or "/".
    public var bundleIdentifier: String
    /// Name captured when the item was added: an app's display name, a website's name, or a file's or
    /// folder's name as Finder shows it (`localizedNameKey`). The alias doesn't replace it.
    public var name: String
    /// Applications only: fallback location. Never set, and never written, for files and folders (§5.3).
    public var path: String?
    public private(set) var kind: Kind
    /// Alias, tags, task notes. Empty for most items; not written when empty.
    public var details: ItemDetails

    public init(bundleIdentifier: String, name: String, path: String? = nil)   // app (unchanged)
    public init(websiteURL url: URL, name: String? = nil)                       // website (unchanged)
    public init(applicationURL: URL) throws                                     // app bundle (unchanged)
    /// A file or folder at `url` (already classified, §2.2). Without a usable `name` it takes the
    /// last path component.
    public init(fileURL url: URL, kind: Kind, name: String? = nil)

    public var id: String { bundleIdentifier }
    public var isWebsite: Bool { kind == .website }                // kept for existing call sites
    public var fileURL: URL? { kind.isFileSystemItem ? FileLocation.url(fromIdentity: bundleIdentifier) : nil }
    /// What lists show: the alias when there is one, else the name.
    public var displayName: String { details.alias ?? name }
    /// Logs: files and folders by kind and extension only ("file .pdf", "folder"), never by path.
    public var logIdentity: String
}
```

### 1.3 Kind capabilities

Each of the 20 sites in §0.11 asks one of these questions instead of `isWebsite`:

```swift
extension AppReference.Kind {
    /// Has processes: running dot, Hide All / Close All, window restoring and its Accessibility
    /// prompt, Most Used.
    public var hasProcess: Bool { self == .application }
    /// Lives on disk: presence checks, Show in Finder, Quick Look, Locate….
    public var isOnDisk: Bool { self != .website }
    /// A file or a folder (identity is a file URL).
    public var isFileSystemItem: Bool { self == .file || self == .folder }
}
```

### 1.4 `ItemDetails` (F2)

```swift
public struct ItemDetails: Hashable, Sendable {
    public static let maximumAliasLength = 80     // characters (grapheme clusters)
    public static let maximumTagCount = 12
    public static let maximumTagLength = 32
    public static let maximumNotesLength = 500

    /// Another name, shown instead of `name` (OPEN QUESTION 1); `nil` when blank.
    public private(set) var alias: String?
    /// Unique, ignoring case and diacritics (`PopupFilter.normalize`), in the order entered.
    public private(set) var tags: [String]
    /// Free text, may span lines (OPEN QUESTION 2); `nil` when blank.
    public private(set) var notes: String?

    /// Sanitizes on the way in, so the invariants always hold (as `DockGroup.sanitizedName` does):
    /// - alias: trimmed, newlines become spaces, control characters removed, cut to the maximum
    /// - tags: trimmed, inner whitespace collapsed, a leading "#" dropped, empties dropped, dedupe,
    ///   at most `maximumTagCount` tags of at most `maximumTagLength`
    /// - notes: trimmed, CRLF/CR become LF, control characters other than LF removed, cut to the maximum
    public init(alias: String? = nil, tags: [String] = [], notes: String? = nil)

    /// Splits typed text on "," and the commas of the app's languages: "،" (ar, fa), "，" "、" (zh, ja).
    public static func tags(fromCommaSeparated text: String) -> [String]
    /// "finance, q3", for the text field.
    public var commaSeparatedTags: String { tags.joined(separator: ", ") }
    public var isEmpty: Bool { alias == nil && tags.isEmpty && notes == nil }
}
```

`DockGroup` doesn't change structurally: `apps` holds every kind. `DockGroup.sortedByName`
(`DockGroup.swift:86-96`) sorts by `displayName`.

### 1.5 Location helpers and the file policy (Core, pure, testable)

```swift
/// File and folder identities.
public enum FileLocation {
    /// `url` standardized ("." and ".." removed; symbolic links are *not* resolved, so the path the
    /// user chose is kept) as a file URL string; a folder's ends in "/".
    public static func identity(for url: URL, kind: AppReference.Kind) -> String
    /// The location an identity names, or `nil` unless all of these hold: scheme `file`; no host
    /// (or "localhost"); no user, password, query or fragment; an absolute path with no "." or ".."
    /// components and no NUL; shorter than `PATH_MAX` bytes (the preconditions of
    /// `SettingsBackup.isAppBundlePath`, shared).
    public static func url(fromIdentity identity: String) -> URL?
}

/// What a file or folder item may point to (F1-6).
public enum FileItemRefusal: LocalizedError, Equatable, Sendable {
    /// An executable, script, installer, location file or system extension.
    case program(name: String)
    /// An app bundle (the picker adds it as an app instead; a backup can't smuggle one in as a file).
    case application(name: String)
}

public struct ItemTypeInfo: Equatable, Sendable {
    /// UTType identifiers of the item, its supertypes included (`UTType.supertypes`).
    public var typeIdentifiers: Set<String>
    public var isDirectory: Bool
    public var isPackage: Bool
}

public enum FileItemPolicy {
    /// Refused by name, with no disk access (used on backup import; the file may not exist on this Mac).
    public static let refusedExtensions: Set<String> = [
        "app", "command", "tool", "terminal", "sh", "bash", "zsh", "csh", "tcsh", "ksh", "fish",
        "py", "pyw", "pl", "rb", "jar", "workflow", "action", "scpt", "scptd", "applescript",
        "fileloc", "inetloc", "webloc", "pkg", "mpkg", "mobileconfig", "prefpane", "saver",
        "qlgenerator", "kext", "plugin", "bundle", "framework", "xpc", "osax",
    ]
    /// Refused by type, checked on the resolved item (symbolic links followed) when it's added and
    /// again when it's opened.
    public static let refusedTypeIdentifiers: Set<String> = [
        "public.executable",               // includes public.unix-executable and com.apple.application
        "public.script",                   // includes shell scripts and .command (com.apple.terminal.shell-script)
        "com.apple.application-bundle",
        "com.apple.installer-package-archive",
        "com.apple.internet-location", "com.apple.web-internet-location",
        "com.apple.file-location",         // to be confirmed against the macOS type tree in PR 1
    ]
    public static func refusal(byName url: URL, kind: AppReference.Kind) -> FileItemRefusal?
    public static func refusal(for info: ItemTypeInfo, name: String, kind: AppReference.Kind) -> FileItemRefusal?
}
```

The exact type identifiers, `com.apple.file-location` in particular, are checked against the
current macOS type tree in PR 1, and the extension list is the fallback. Strictness is OPEN QUESTION 4.

### 1.6 Presence (F1-4)

```swift
public enum ItemPresence: Equatable, Sendable {
    /// App, file or folder found here (resolved location).
    case available(URL)
    /// A website: always openable, never checked.
    case online
    /// Not where it was, or it changed kind (a file that's now a folder).
    case missing
    /// Its path is on "/Volumes/<name>", which isn't mounted.
    case volumeUnavailable(name: String)
    /// macOS refused the check (EPERM/EACCES, e.g. TCC): shown neutrally, opening is still attempted.
    case unverified

    public var isOpenable: Bool   // available, online, unverified
}

@MainActor public protocol ItemLocating: AnyObject {
    func presence(of item: GroupItem) -> ItemPresence
    func typeInfo(at url: URL) -> ItemTypeInfo?
}
```

`WorkspaceItemLocator` implements both. Apps keep today's `resolvedURL` logic. Files and folders
use `URL.resourceValues([.isDirectoryKey, .isPackageKey, .contentTypeKey])` on the standardized
URL and map the error codes to the cases above. `AppIconProviding.isInstalled` becomes
`presence(of:).isOpenable`, and the icon provider gains `presence(of:)`. For a missing or
unverified file the icon comes from its type (`NSWorkspace.icon(for: UTType(filenameExtension:))`),
and a folder uses `.folder`, so no disk access is needed.

### 1.7 `ApplicationWorkspace` additions

```swift
/// Opens files and folders with their default apps (folders: the default file viewer), grouped by
/// handler app, one request per handler (as `openWebsites` does), and brings the handler forward.
func openFileItems(_ urls: [URL]) async throws
/// Shows the items selected in Finder windows (`activateFileViewerSelecting`).
func revealFileItems(_ urls: [URL])
```

Test fakes (`Tests/DockGroupsCoreTests/GroupLauncherTests.swift:92` `FakeWorkspace`) record the
calls. Tests never touch LaunchServices, as `AGENTS.md` requires.

### 1.8 Persistence schema (JSON)

The key set of existing items is **unchanged**. The new keys are `kind: "file" | "folder"`, and
`alias`, `tags`, `notes` on any kind, written only when set.

```jsonc
// app (unchanged; no kind)
{ "bundleIdentifier": "com.apple.iWork.Numbers", "name": "Numbers", "path": "/Applications/Numbers.app" }
// app with details
{ "bundleIdentifier": "com.apple.iWork.Numbers", "name": "Numbers", "path": "/Applications/Numbers.app",
  "alias": "Budget", "tags": ["finance", "q3"], "notes": "Monthly budget; send totals to Ayşe" }
// file: no "path", no "url"; the identity is the location
{ "bundleIdentifier": "file:///Users/me/Documents/Finance/Q3%20Report.pdf", "kind": "file", "name": "Q3 Report.pdf",
  "tags": ["finance"] }
// folder: identity ends in "/"
{ "bundleIdentifier": "file:///Users/me/Projects/cybokron/", "kind": "folder", "name": "cybokron" }
// website (unchanged)
{ "bundleIdentifier": "https://github.com", "kind": "website", "url": "https://github.com", "name": "github.com" }
```

The keys are flat, not a nested `details` object, so each field decodes **leniently on its own**:
a malformed `tags` value loses only the tags, as `decodeLeniently` does for preferences.

Decoding rules in the new version extend `AppReference.swift:112-131`:

| Saved | Result |
| --- | --- |
| no `kind`, identity `http(s)://…` | website (unchanged) |
| no `kind`, identity starts with `file://` | **recovered**: `.folder` if the identity ends in "/", else `.file`, as long as `FileLocation.url(fromIdentity:)` accepts it. This covers items re-saved by an old version that dropped `kind`. |
| `kind: "file" / "folder"`, valid identity | that kind; any `path` is ignored and dropped |
| `kind: "file" / "folder"`, invalid identity | kept as a **missing app** (the existing rule for unreadable websites) |
| unknown `kind` | missing app (unchanged) |
| `alias` / `tags` / `notes` unreadable | that field is empty; `ItemDetails.init` sanitizes the rest |

**Versions:** `GroupsDocument.formatVersion` stays **1**, `SettingsBackup.currentSchemaVersion`
stays **1**, and `AgentConfiguration.formatVersion` stays **1**. The changes are additive,
following the precedent set when websites were added in 0.5.5 without a bump
(`CHANGELOG.md:207-213`; the test `backupKeepsWebsitesAndOldBackupsStillRead`). A bump would make
0.6.7 refuse the file. For `groups.json` that means moving it aside and starting with an **empty
list** (`GroupStore.swift:308-340`), which is worse than reading it leniently. §5.3 has the
trade-off.

### 1.9 Store additions

```swift
@discardableResult public func addItems(_ items: [GroupItem], toGroup id: DockGroup.ID) -> Int   // addApps forwards here
/// No-op (no save, no agent rebuild) when unchanged.
@discardableResult public func updateDetails(_ details: ItemDetails, ofItem identity: String, inGroup id: DockGroup.ID) -> Bool
/// Files and folders: points the item at `url` (same kind). Keeps details, list position and the
/// Free Layout cell (re-keyed). `false` when the group already has an item there.
@discardableResult public func relinkItem(_ identity: String, inGroup id: DockGroup.ID, to url: URL) -> Bool
```

---

## 2. File and folder behaviors

### 2.1 Actions per kind

| Action | App | Website | File | Folder |
| --- | --- | --- | --- | --- |
| Click / Return | activate or launch (unchanged) | default browser (unchanged) | open in default app | open in default file viewer (Finder) |
| Open All | yes | yes, one browser request | **yes**, batched per handler app | **yes**, one window each (OPEN QUESTION 3) |
| Hide All / Close All | yes | ignored | ignored | ignored |
| Show in Finder | found app | — | select the file | select the folder in its parent |
| Quick Look | found app (card) | — | preview | folder card |
| Copy URL | — | yes | — | — |
| Locate… (main app, editable) | — | — | when missing | when missing |
| Running dot, Most Used | yes | no | no | no |

Order in Open All: apps (concurrent, as today `GroupLauncher.swift:89-115`), then files and
folders (one request per handler), then websites (as today). Report entries keep the group's order.

### 2.2 Adding (group window)

- A new picker, `ItemPicker.chooseFilesAndFolders`, opens an `NSOpenPanel` with
  `canChooseFiles` and `canChooseDirectories` on, `treatsFilePackagesAsDirectories` off, multiple
  selection, and no `allowedContentTypes`.
- Each chosen URL is classified with `ItemTypeInfo`:
  - app bundle → `AppReference(applicationURL:)`, the same as Add Apps…;
  - directory and not a package → `.folder`;
  - otherwise, document packages included → `.file`;
  - then `FileItemPolicy`; refused items are listed in one alert, the way `addAppsProblem` works
    today (`GroupDetailView.swift:61-70`).
- Drag and drop from Finder onto the Items list: later (not v1).

### 2.3 Opening: guard order (main app and agents, `GroupLauncher`)

1. `FileLocation.url(fromIdentity:)` must succeed, else `.failed(reason:)`.
2. Presence: `.missing` → `.notFound`; `.volumeUnavailable(name)` → `.failed(reason:
   core.item.error.volume)`.
3. Resolve symbolic links, read `ItemTypeInfo`, apply `FileItemPolicy`. A refusal gives
   `.failed(reason:)` and **the workspace isn't called**.
4. A kind mismatch (file item now a directory, or the reverse) → `.notFound`.
5. `workspace.openFileItems`.

The Accessibility prompt (`AppDelegate.swift:257`) and window restoring apply only when
`kind.hasProcess`.

### 2.4 When presence is checked ("heartbeat")

There are **no timers, no polling, no FSEvents watchers.** Checks are event-driven, cached per
view, and **never run inside a SwiftUI `body`**.

| Where | When | Cost |
| --- | --- | --- |
| Popup, main app and agents | once per popup build, `PopupPanelController.update(for:)` (open, and refresh after store, preferences or Most Used changes); stored in `PopupCell.presence` | n `stat`s / LaunchServices lookups |
| Show in Finder, Quick Look | when invoked, for that item | 1 |
| Launch (click, Return, Open All, Dock menu, links, Siri) | when invoked; authoritative | n |
| Group window rows | a new `ItemPresenceCache` (`@MainActor ObservableObject`, keyed by identity), refreshed on window appear, group selection change, `didBecomeKey`, after add or relink, and on `NSWorkspace.didMountNotification` / `didUnmountNotification`. Rows read the cache. | n per trigger |
| Agent Dock menu | when the Dock asks (`applicationDockMenu`) | n |
| Tiles | icon provider cache; a missing file gets its type icon | — |

`AppRowView`'s current per-render `resolvedURL()` (`AppRowView.swift:12`) moves to the cache in
the PR that touches the row (PR 3).

### 2.5 Bookmarks

- **Security-scoped bookmarks: not required** (§0.10).
- **Plain bookmarks** (`URL.bookmarkData()`, no security scope) would follow moves and renames on
  the same volume. **v1 uses paths only, plus "Locate…"** (OPEN QUESTION 5). If bookmarks are
  added later:
  - they're a hint in `groups.json` and the agent config only;
  - **`SettingsBackup` never writes or reads them**, because bookmarks are specific to one Mac,
    opaque, and would widen what a crafted backup can point to;
  - a resolved bookmark is checked exactly like a path (§2.3);
  - only the main app writes a changed location back, at most once per popup build, and only when
    it really changed, so there are no save or rebuild loops.
- Under a future App Sandbox, the bookmark slot would become security-scoped
  (`com.apple.security.files.bookmarks.app-scope`). Keeping bookmarks out of backups now keeps that
  path open.

### 2.6 TCC (privacy-protected locations). Assumption to verify in PR 3

The app isn't sandboxed but is subject to TCC for `~/Desktop`, `~/Documents`, `~/Downloads`,
iCloud Drive, and removable and network volumes.

- **Assumption A1:** a `stat` (`resourceValues`) or `icon(forFile:)` of an item in those locations
  may prompt for access ("… would like to access files in your Documents folder") or fail with
  EPERM. A file chosen in an `NSOpenPanel` is accessible right after it's chosen (user intent); it
  is not established that this lasts across launches.
- **Assumption A2:** `NSWorkspace.open` and `activateFileViewerSelecting` don't need the app's
  own access, because the handler app and Finder open the file.
- **Assumption A3:** every agent has its own bundle identifier
  (`com.cybokron.dockgroups.agent.<uuid>`), so TCC tracks it separately. **Each agent could
  prompt on its own.**
- **Design consequence:** EPERM/EACCES map to `.unverified` (not missing, not dimmed). In agents,
  items under the protected roots aren't checked ahead of time: they show `.unverified` until
  opened, and their icon comes from the type.
- **PR 3 gate (manual test):**
  1. `tccutil reset SystemPolicyDocumentsFolder com.cybokron.dockgroups`
  2. Add `~/Documents/x.pdf`, relaunch, open the popup, and note whether a prompt appears.
  3. Repeat with a standalone agent.
  4. If prompts appear: add purpose strings (`NSDocumentsFolderUsageDescription`,
     `NSDesktopFolderUsageDescription`, `NSDownloadsFolderUsageDescription`,
     `NSRemovableVolumesUsageDescription`, `NSNetworkVolumesUsageDescription`) to
     `Resources/Info.plist` **and** to the agent's generated Info.plist (`AgentBundleLayout`).
     Info.plist strings aren't covered by `LocalizationTests`, so they stay English.

### 2.7 Quick Look

- Reuse `PopupPreviewController` and `QLPreviewPanel`.
- **The tile's behavior doesn't change:** a click still opens the item. There are no hover buttons
  on tiles.
- Quick Look has two triggers:
  1. **Space** on the keyboard-selected item. This exists today; it extends to files and folders.
  2. A new **"Quick Look"** item in the cell's context menu, in the main app and agents.
- Before showing the preview, the context-menu path sets `keyboard.selectedID` to that cell.
  Otherwise `syncPreview()` (`PopupPanelController.swift:501-508`) would close it straight away,
  because it closes the preview when there's no selection.
- The decision moves to Core: `PopupQuickLook.target(for: GroupItem, presence: ItemPresence) ->
  URL?` replaces the two inline checks at `:476` and `:503`. `.unverified` items are previewable
  (Quick Look reports its own errors); `.missing` and `.volumeUnavailable` items aren't.
- Privacy: the preview is drawn by the system's Quick Look service only on request. The app never
  calls `QLThumbnailGenerator`, never reads file contents, and never logs paths (`logIdentity`).

---

## 3. Search model (F2-2, F2-3)

### 3.1 Index

```swift
/// Built once per popup build (with the cells), so typing never re-normalizes the items.
public struct ItemSearchIndex: Sendable {
    public init(items: [GroupItem])
    /// Matching item indices, best first; list order within a rank. An empty query returns every index in order.
    public func matches(for query: String) -> [ItemSearchMatch]
}
public struct ItemSearchMatch: Equatable, Sendable {
    public let index: Int
    public let rank: ItemSearchRank
    /// The tag or notes excerpt that matched, for the footer (§4.4); `nil` for title matches.
    public let reason: MatchReason?
}
public enum ItemSearchRank: Int, Comparable, Sendable {
    case titlePrefix, titleWordPrefix, titleContains   // stage 1, the existing PopupFilter.Rank on a title
    case tags                                         // stage 2, every token found in titles or tags
    case notes                                        // stage 2, at least one token found only in notes
}
```

Each entry stores normalized forms (`PopupFilter.normalize`) of `name` and `alias` (the
"titles"), each tag, and the notes, plus word-start offsets for titles and notes.

### 3.2 Algorithm

- **Stage 1, the current behavior unchanged.** For each item, the best
  `PopupFilter.rank(of: title, query:)` over its titles (alias, name) with the **whole** query.
  Without an alias the titles are `[name]`, so stage 1 gives exactly what `PopupFilter.filter`
  gives today. That is F2-3.
- **Stage 2, only for items stage 1 didn't match.**
  - Split the normalized query on whitespace into tokens, deduplicated.
  - An item matches when **every** token is a **word prefix** in some field: a word of a title, a
    word of a tag, or a word of the notes.
  - Word prefix, not substring, to avoid noise: "a b" doesn't match everything containing those
    letters. Turkish suffixes still match ("fatura" finds "faturayı").
  - Rank: `.tags` if every token was found in titles or tags, otherwise `.notes`.
  - Ties keep list order, as today (`PopupKeyboard.swift:74-76`).
- Typed characters are unchanged (`PopupFilter.acceptsCharacter`): space separates tokens, and
  "#" or "," can't be typed and aren't needed.

### 3.3 Performance rules

- n is small: a group has no hard item limit, but its popup shows at most 10 columns × 10 rows
  before it scrolls (`PopupOverrides.allowedCountRange = 1...10`), and real groups are expected
  to stay well under 100 items. One keystroke costs O(n × total field length) over
  pre-normalized strings, with no allocation per item for normalization.
- `PopupContent` holds the index. A one-entry memo `(query → matches)` in a reference-type holder
  owned by `PopupPanelController` serves the five or more `navigationItems(query:)` calls of one
  keystroke (§0.4).
- No metadata queries in the search path: presence is decided at build time (§2.4).
- Test budget: `matches(for:)` over 200 synthetic items × 50 queries stays far below a frame. The
  bound is generous, because CI runners are slow (`def2959` relaxed a similar bound).

### 3.4 Where else

- The agent popup searches the same index (details are in `group-config.json`).
- The Most Used list has no details: stage 1 only, the same as today.
- Siri's `GroupLookup.search` matches group names only. Unchanged.

---

## 4. UX mock texts

### 4.1 Group window, Items section (was "Apps")

```
Items                                   [Add ▾] [Sort A→Z] [Show Popup] [Open All] [Hide All]
                                         ├ Add Apps…
                                         ├ Add Files or Folders…
                                         └ Add Website…
 [▣] Numbers                    #finance #q3   com.apple.iWork.Numbers             (ⓘ) (⊖)
 [📄] Quarterly report          #finance       ~/Documents/Finance/Q3 Report.pdf   (ⓘ) (⊖)
      Name: Q3 Report.pdf
 [📁] cybokron                                  ~/Projects/cybokron                 (ⓘ) (⊖)
 [📄] Old Plan.key   Can't be found · ~/Desktop/Old Plan.key        [Locate…]      (ⓘ) (⊖)
 [📄] Shots.zip      On “Backup SSD”, which isn't connected · /Volumes/Backup SSD/Shots.zip  (⊖)
 [🌐] github.com                                https://github.com                  (ⓘ) (⊖)
To move an item to another group, drag it onto that group in the sidebar, or use Move to in its context menu.
```

UX change: "Add Apps…" and "Add Website…" move into one **Add** menu, because the header already
has six buttons (`GroupDetailView.swift:127-140`). The README screenshot
`docs/screenshots/groups-window.png` needs to be retaken. Row context menu: Show in Finder,
Quick Look, Edit Details…, Locate… (when missing), Move to ▸.

### 4.2 Details editor: three options

**A. Inline disclosure row.** The row expands in place:

```
 ▾ [📄] Q3 Report.pdf                                   ~/Documents/Finance      (⊖)
        Alias        [ Quarterly report                       ]
        Tags         [ finance, q3                            ]  Separate tags with commas.
        Task notes   [ Send the totals to Ayşe on Fridays     ]
                     [                                        ]
```

Pros: easy to find, nothing new to open. Cons: the Form grows long, it gets in the way of
`.onMove` drags, and edits are as-you-type, so a standalone group's agent rebuilds after every
pause (§0.7).

**B. Popover from an info button (recommended).**

```
 [📄] Q3 Report.pdf   #finance   ~/Documents/Finance   (ⓘ)(⊖)
                                     ┌─────────────────────────────────────────┐
                                     │ Details of “Q3 Report.pdf”              │
                                     │ Alias       [Quarterly report         ] │
                                     │             Another name, shown instead │
                                     │ Tags        [finance, q3              ] │
                                     │             Separate tags with commas.  │
                                     │ Task notes  [Send the totals to Ayşe  ] │
                                     │             [on Fridays               ] │
                                     │ Typing any of these in the popup finds  │
                                     │ this item.                     [Done]   │
                                     └─────────────────────────────────────────┘
```

Changes are **committed once, on Done or when the popover closes**: one save and at most one
agent rebuild. The row stays compact and shows tags as chips. "Edit Details…" in the row's
context menu opens the same popover.

**C. Sheet ("Item Details", like `AddWebsiteView`).** A modal with the same fields plus kind,
location and Locate…. Pros: room for long notes and file info; the popup's context menu could
open it through the group window. Cons: modal, and heavier for a quick tag.

Recommendation: **B** in v1. C stays possible later if notes grow, and can reuse B's view.

### 4.3 Popup cells and menus

- File cell: the Finder icon, and the title is `displayName`.
  - Help: "Open Quarterly report in its default app. Drag to reorder, or out of the popup to
    remove it from the group."
  - VoiceOver: "File Quarterly report", hint "Opens the file in its default app".
- Folder cell: help "Open the folder cybokron.", hint "Opens the folder in Finder".
- Missing cell: icon at 0.35 opacity, as missing apps are today (`PopupContentView.swift:705`).
  Help: "“Old Plan.key” can't be found. It may have been moved, renamed or deleted. Drag it out of
  the popup to remove it from the group."
- Context menu, file or folder:

  ```
  Open
  Quick Look
  Show in Finder
  ───────────
  Move to ▸            (editable only)
  Remove from Group    (editable only)
  ───────────
  Add Website…         (editable only, unchanged)
  ```

  A missing item shows Open and Remove, plus "Locate…" in the main app. Locate… opens the group
  window, because the popup can't host an open panel.
- Tags and notes appear in the help text after the action: "Tags: finance, q3 · Notes: Send the
  totals to Ayşe…", cut to one line.

### 4.4 Filter footer

```
Filter: “inv”  ·  ↩ opens the selected item  ·  esc clears
Filter: “inv”  ·  tag “invoice” of Numbers  ·  ↩ opens it  ·  esc clears
Filter: “friday”  ·  in the task notes of Quarterly report  ·  ↩ opens it  ·  esc clears
```

The match reason is shown for the selected cell (best match by default). The current text says
"opens the selected app" (`en.lproj:98`), which is wrong once a group holds files.

### 4.5 Alerts

- Add refused: title **"Some items couldn't be added"**. Message: "“run.command” is a program or
  script, so it can't be added as a file."
- Open problems: the existing `problems.launch.item` "• %1$@: %2$@".
  - Missing: "• Old Plan.key: not found on this Mac." (existing `problems.launch.notFound`).
  - Refused: "• run.command: wasn't opened, because programs and scripts open only as apps."
- Backup confirmation: counts become items: "The backup has 3 groups with 14 items." Only the
  `%2$@` argument changes, from `appCount` to `itemCount`. Add: "1 item in the backup was left out:
  it can't be opened safely."
- Other Versions…, installing a version before item support while a group has files, folders or
  details: "Version 0.6.7 can't show files, folders, aliases, tags or task notes. A copy of your
  groups is kept before it's installed; editing groups in that version drops these items' details."

### 4.6 Agent (standalone Dock tile)

- Dock menu items use `displayName`. A file or folder is enabled when `presence.isOpenable` and
  opens it; files and folders are never checked as running.
- The agent popup gets Quick Look and Show in Finder (shared `PopupPanelController`), but not
  Locate… or Edit Details… (`allowsEditing: false`).

---

## 5. Migration and backup compatibility

### 5.1 New version reading old data

`groups.json`, `.dockgroups` and agent configs from 0.5.5–0.6.7 decode **unchanged**: no kind
means an app, and websites are recognized by kind or address. Items written without details stay
**byte-identical** when re-encoded with sorted keys. That's test-locked (§8) and also prevents
spurious `outdated` agent rebuilds after an update. No migration step runs and nothing is
rewritten until the user changes something.

### 5.2 Backup import sanitizing (new `SettingsBackup.sanitizedForImport`)

This replaces `withAppBundlePathsOnly` (`SettingsBackup.swift:142-155`) and keeps all its app
rules. For files and folders:

1. The identity must pass `FileLocation.url(fromIdentity:)`. A folder identity must end in "/" and
   a file identity must not.
2. `FileItemPolicy.refusal(byName:)` drops `.app` and the refused extensions. No disk access: the
   backup may come from another Mac.
3. `path` is cleared, and any bookmark field (if one ever exists) is dropped.
4. `ItemDetails` is sanitized (limits).
5. Dropped items are counted in a non-encoded `SettingsBackup.leftOutItemCount`, which feeds
   `SettingsRestoreSummary` and the confirmation text (§4.5).
6. `freeLayoutSlots` are re-sanitized, as today (`:153`).

A crafted **`groups.json`** doesn't go through import sanitizing (`GroupStore.loadFromDisk`). It
is covered by the launch-time guard (§2.3), which runs for every source, so F1-6 holds for both
files.

### 5.3 Old version (0.6.7 and earlier) reading new data

| Data | Old decoder (`AppReference.swift:112-131` at 0.6.7) | User-visible result in 0.6.7 |
| --- | --- | --- |
| file or folder item | `kind: "file"` isn't `"website"`, and `looksLikeAddress("file://…")` is false, so it becomes `.application` with the identity `file:///…` and `path == nil` (never written) | **missing app**: dimmed, "Not found on this Mac · file:///…" in the group window. `urlForApplication(withBundleIdentifier:)` returns nil and there's no path, so Open reports "not found". `runningApplications(withBundleIdentifier:)` returns `[]`, so Hide All and Close All skip it. Nothing is opened. |
| file or folder in a backup | `withAppBundlePathsOnly`: not a website, not `isIdentifiedByPath` (no "/" prefix), no path | kept as a missing app, removable |
| `alias`, `tags`, `notes` | unknown keys, ignored | not shown |
| **old version saves** (any edit) | writes `bundleIdentifier`, `name` and `path` only | the kind comes back in the new version from the `file://` prefix and the trailing "/" (§1.8). **Details are lost.** |

This is why file items **must never write `path`**. An old version would otherwise use it as an
app's fallback location (`AppReference.swift:92-95`) and call `openApplication(at:)` on a
document.

**Downgrade protection** is a release gate (PR 4). Before Other Versions… installs a version
earlier than the first one with item support, the app:

1. copies `groups.json` aside with `JSONFileSupport.copyAside(label: "pre-downgrade")`, which
   keeps 3 copies;
2. if any group has file or folder items or details, adds the warning in §4.5 to the existing
   install confirmation.

`UpdateInstaller` itself stays untouched: it never reads settings (§0.8).

### 5.4 Agents across versions

- After an update, `hostChanged` rebuilds every agent with the new executable and new config
  together (`AgentPlanner.swift:120-121`).
- A running agent with the **old** executable that receives `configurationChanged` before it's
  rebuilt reads the new config leniently, with the same results as §5.3. It never saves.
- Edits to details rebuild the agent, as any edit does (§0.7). Committing on Done (§4.2 B) keeps
  this to one rebuild per edit session.

### 5.5 Schema version decision

Versions stay at 1 (§1.8), for three reasons:

1. it follows the websites precedent;
2. a bumped `groups.json` would leave a downgraded app with an empty group list;
3. the lenient path in §5.3 has been checked to open nothing unintended.

The cost is that details are lost if the user edits groups in a downgraded version. §5.3's
pre-downgrade copy mitigates that.

---

## 6. GroupCommand distribution report

### 6.1 Group-level commands

| Command | Entry points (file:line) | Wrappers → core implementation | Count |
| --- | --- | --- | --- |
| **Show popup** | menu bar item `StatusBarController.swift:190` → `AppDelegate.swift:141` (toggle); group window `GroupDetailView.swift:134` → `AppDelegate.swift:56` (show); link `open`/`show` `AppDelegate.swift:337`; link `shortcut` `:357`; global shortcut `:78` → `:288` (toggle); Siri `GroupIntents.swift:135` → `AppDelegate.swift:396`; reopen `:187`; popup Tab `PopupPanelController.swift:537`; agent tile `AgentAppDelegate.swift:84` | `PopupPanelController.show/toggle` | 9 entry points, 1 implementation, 2 variants (show/toggle) |
| **Open All** | menu ⌥ `StatusBarController.swift:195`; group window `GroupDetailView.swift:136`; sidebar `GroupSidebarView.swift:37`; popup `PopupPanelController.swift:314`; link `launch` `AppDelegate.swift:339`; Siri `GroupIntents.swift:28`; agent popup `AgentAppDelegate.swift:160`; agent Dock menu `:271`; agent ⌥-click `:104` | `AppDelegate.openAll` `:266`, `AppDelegate.launchAll` `:400` (no alerts), `AgentAppDelegate.openAll` `:303` → `GroupLauncher.openAll` `:84` | 9 entry points, **3 wrappers** |
| **Hide All** | menu ⇧⌥ `StatusBarController.swift:200`; group window `GroupDetailView.swift:138`; sidebar `GroupSidebarView.swift:39`; popup `PopupPanelController.swift:324`; link `hide` `AppDelegate.swift:355`; agent popup `:162`; agent Dock menu `:277` | `AppDelegate.hideAll` `:281`, `AgentAppDelegate.hideAll` `:313` → `GroupTerminator.hideAll` `:116` | 7 entry points, **2 wrappers** |
| **Close All** | popup `PopupPanelController.swift:319`; link `quit` `AppDelegate.swift:341`; Siri `GroupIntents.swift:69`; agent popup `:161`; agent Dock menu `:283` | `AppDelegate.closeAll` `:273` → `GroupQuitRequests.request` `:115`; `AppDelegate.quitAll` `:405` → `requestFromIntent` `:130`; `AgentAppDelegate.closeAll` `:309` → **`GroupTerminator.closeAll` directly** | 5 entry points, **3 wrappers, 2 policies** |
| **Group settings** | popup gear/menu `PopupPanelController.swift:331` → `AppDelegate.swift:93`; link `:368`; agent popup/Dock menu `AgentAppDelegate.swift:164`, `:289` → link `:325` | `MainWindowController.showSettings(ofGroup:)` | 3 paths |
| **Manage groups** | popup `:326` → `AppDelegate.swift:92`; link `:375`; menu bar `showMainWindow`; agent `:163` → link `:318` | `MainWindowController.show` | 4 paths |

### 6.2 Item-level commands (what F1 and F2 extend)

| Command | Entry points | Implementation | Count |
| --- | --- | --- | --- |
| **Open item** | popup click/Return `PopupPanelController.swift:306`, `:528`; Most Used menu `StatusBarController.swift:209` → `AppDelegate.swift:161`; agent popup `AgentAppDelegate.swift:159`; agent Dock menu `:262` | `AppDelegate.open` `:255` (asks for Accessibility, `:257`), `AgentAppDelegate.open` `:296` (never asks) → `GroupLauncher.open` `:55` | 4 entry points, **2 wrappers** |
| **Show in Finder** | popup menu `PopupContentView.swift:779` | inline `PopupPanelController.swift:345-349`, using `NSWorkspace.shared` and `app.resolvedURL()` directly instead of the injected provider | 1, inline |
| **Copy URL** | popup menu `PopupContentView.swift:772` | inline pasteboard code in the view | 1, inline |
| **Quick Look eligibility** | Space `PopupPanelController.swift:475`, selection sync `:501` | `!isWebsite && resolvedURL()`, **written twice** (`:476`, `:503`) | 2 copies |
| **Remove** | popup menu `PopupContentView.swift:790`; popup drag-out `:495`, `:566`, `:584`; group window row `GroupDetailView.swift:110` | `GroupStore.removeApp` | 3 entry kinds |
| **Move to group** | popup menu `PopupContentView.swift:786`; group window menu `GroupDetailView.swift:113`; sidebar drop `GroupSidebarView.swift:33` | `GroupStore.moveApp` | 3 |
| **Reorder / sort** | popup drag `PopupPanelController.swift:350-358`, group window `.onMove` `GroupDetailView.swift:121`; sort: popup footer `PopupContentView.swift:644`, group window `GroupDetailView.swift:131` | store | 2 + 2 |
| **Add website** | group window sheet `GroupDetailView.swift:72-78`; popup → `AddWebsiteWindowController` `AddWebsite.swift:95-100` | `AddWebsiteView` | 2 presenters |
| **Item availability** (enabled / shown / help) | popup menu `PopupContentView.swift:762-797`; cell help `:742-757`; agent Dock menu `AgentAppDelegate.swift:241`; group window row `AppRowView.swift:22-31` | hand-written per site | **4 independent copies** |

### 6.3 Observations (facts)

- **D1.** Close All has two policies. The main app goes through `GroupQuitRequests`; the agent
  calls the terminator directly (`AgentAppDelegate.swift:309-311`). The outcome is the same today,
  because only links ask and agents have no links, but the code paths and logs differ.
- **D2.** Open differs on purpose. The main app may ask for Accessibility; the agent never does
  (documented at `AgentAppDelegate.swift:11-13`).
- **D3.** The kind checks (`isWebsite`) are in 20 places (§0.11), and item availability is
  hand-written in 4 places (§6.2). This is where F1 would add the most code if nothing changed.
- **D4.** New item actions (Quick Look, Show in Finder, Locate…) live in `PopupPanelController`,
  which the main app and agents **already share**. F1 doesn't need group-level command
  consolidation.
- **D5.** The URL scheme rate-limits links only, by design (`URLCommand.swift:157-162`). Menus,
  Siri and shortcuts must not be routed through `URLCommand`.
- **D6.** Count wording is mixed. The popup counts items (`PopupContentView.swift:206`); the backup
  texts count apps for every item (`SettingsBackupController.swift:130`, `:174`, `:198`;
  `BackupSettingsView.swift:72`); menu bar tooltips say apps (`L10n.swift:112-115`); Siri summaries
  say apps (`Launching/ReportSummaries.swift`).

### 6.4 Recommendation, from the evidence above

- **R1 (PR 2, needed by F1).** Kind capabilities (§1.3) replace the 20 kind checks, and a Core
  `ItemAction` with `ItemAction.available(for:presence:context:)` builds all three item menus (popup
  context menu, group window row menu, agent Dock menu) and the help or hint texts. Context is
  `.popup(editable:)`, `.groupWindow` or `.dockMenu`. That replaces the 4 copies in §6.2 and makes
  the availability matrix testable in `DockGroupsCoreTests`.

  ```swift
  public enum ItemAction: Hashable, Sendable {
      case open, quickLook, showInFinder, copyURL, locate, editDetails, moveTo, remove
  }
  public enum ItemActionContext: Sendable { case popup(isEditable: Bool), groupWindow, dockMenu }
  extension ItemAction {
      public static func available(for item: GroupItem, presence: ItemPresence, in context: ItemActionContext) -> [ItemAction]
  }
  ```

- **R2 (PR 7, optional, no behavior change).** A `@MainActor final class GroupActionPerformer` in
  the app target, owning the launcher, terminator, quit requests and report presenter, with a
  `Policy` (`asksForAccessibility: Bool`, `quitRequests: GroupQuitRequests?`). Both delegates build
  one. It removes the 3 + 2 + 3 + 2 wrappers in §6.1 and makes D1 explicit. Not needed for F1 or
  F2 (D4).
- **Not recommended:** a single `GroupCommand` enum routed through `URLCommand` or `URLCommandGate`
  (D5).

---

## 7. Localization keys

### 7.1 Rules

1. A key is added **with the code that looks it up**. `LocalizationTests` fails on unused
   `en.lproj` keys, so keys can't be added ahead of time.
2. Each PR adds its key prefixes to `LocalizationTests.awaitingTranslation`. Translations may lack
   those keys but may **never** have keys `en.lproj` lacks.
3. To **replace** a key (for example `popup.footer.filter.matches`), remove the old key from
   `en.lproj` **and from all 25 translations** in the same PR, and add the new one under an
   awaiting prefix.
4. Update `docs/l10n-keys.md`: add a section per prefix, marked "English only for now", update
   the key count (498 today), and fix the drift noted in §0.9.
5. Reuse existing keys: `popup.menu.open` (Open), `common.showInFinder` (Reveal: "Show in Finder"
   is the macOS wording and matches the app), `common.removeFromGroup`, `common.moveTo`,
   `problems.launch.item`, `problems.launch.notFound`, `common.itemCount.*`,
   `popup.cell.help.drag.*`.

### 7.2 New key groups (by `awaitingTranslation` prefix)

| Prefix | Key | English | PR |
| --- | --- | --- | --- |
| `core.item.` | `core.item.error.program` | “%@” is a program or script, so it can't be added as a file. | 1 |
| | `core.item.error.notOpened` | wasn't opened, because programs and scripts open only as apps. | 2 |
| | `core.item.error.noHandler` | No app on this Mac opens “%@”. | 2 |
| | `core.item.error.volume` | It's on “%@”, which isn't connected. | 2 |
| `addItems.` | `addItems.menu` | Add Files or Folders… | 3 |
| | `addItems.title` | Add Files and Folders to Group | 3 |
| | `addItems.message` | Choose files and folders to add to “%@”. Apps you choose are added as apps. | 3 |
| | `addItems.problem.title` | Some items couldn't be added | 3 |
| `groupWindow.items.` | `groupWindow.items.section` | Items | 3 |
| | `groupWindow.items.add` | Add | 3 |
| | `groupWindow.items.add.help` | Add apps, files, folders or a website to this group. | 3 |
| | `groupWindow.items.empty` | Nothing here yet. Use “%@” to add apps, files, folders or a web link. | 3 |
| | `groupWindow.items.moveHint` | To move an item to another group, drag it onto that group in the sidebar, or use %@ in its context menu. | 3 |
| | `groupWindow.items.remove.file` | Remove %@ from this group. The file itself isn't affected. | 3 |
| | `groupWindow.items.remove.folder` | Remove %@ from this group. The folder itself isn't affected. | 3 |
| `item.` | `item.kind.file.accessibility` | File %@ | 3 |
| | `item.kind.folder.accessibility` | Folder %@ | 3 |
| | `item.action.quickLook` | Quick Look | 3 |
| | `item.action.locate` | Locate… | 3 |
| | `item.missing.help` | “%@” can't be found. It may have been moved, renamed or deleted. | 3 |
| | `item.missing.row` | Can't be found · %@ | 3 |
| | `item.volume.row` | On “%1$@”, which isn't connected · %2$@ | 3 |
| | `item.unverified.row` | Can't check this location · %@ | 3 |
| | `item.locate.message` | Choose where “%@” is now. Its details and place in the group are kept. | 3 |
| | `item.locate.duplicate` | “%@” is already in this group. | 3 |
| `popup.item.` | `popup.item.hint.file` | Opens the file in its default app | 3 |
| | `popup.item.hint.folder` | Opens the folder in Finder | 3 |
| | `popup.item.help.openFile` | Open %@ in its default app. | 3 |
| | `popup.item.help.openFolder` | Open the folder %@. | 3 |
| `item.problems.` | `item.problems.allFailed` | The items in “%@” couldn't be opened. (replaces `problems.launch.allFailed`) | 3 |
| | `item.problems.someFailed` | Some items in “%@” couldn't be opened. (replaces `problems.launch.someFailed`) | 3 |
| `updates.otherVersions.items.` | `updates.otherVersions.items.warning` | Version %@ can't show files, folders, aliases, tags or task notes. A copy of your groups is kept before it's installed; editing groups in that version drops these items' details. | 4 |
| `settings.backup.leftOut.` | `settings.backup.leftOut.one` / `.other` | 1 item in the backup was left out: it can't be opened safely. / %ld items in the backup were left out: they can't be opened safely. | 1 (Core count) + 3 (text) |
| `item.details.` | `item.details.title` | Details of “%@” | 5 |
| | `item.details.alias` | Alias | 5 |
| | `item.details.alias.placeholder` | Another name, shown instead | 5 |
| | `item.details.tags` | Tags | 5 |
| | `item.details.tags.placeholder` | finance, q3 | 5 |
| | `item.details.tags.hint` | Separate tags with commas. | 5 |
| | `item.details.notes` | Task notes | 5 |
| | `item.details.notes.placeholder` | What you use it for | 5 |
| | `item.details.hint` | Typing any of these in the popup finds this item. | 5 |
| | `item.details.button.help` | Alias, tags and task notes of %@ | 5 |
| | `item.details.originalName` | Name: %@ | 5 |
| | `item.details.menu` | Edit Details… | 5 |
| `popup.search.` | `popup.search.footer.matches` | Filter: “%@”  ·  ↩ opens the selected item  ·  esc clears (replaces `popup.footer.filter.matches`) | 6 |
| | `popup.search.footer.tag` | Filter: “%1$@”  ·  tag “%2$@” of %3$@  ·  ↩ opens it  ·  esc clears | 6 |
| | `popup.search.footer.notes` | Filter: “%1$@”  ·  in the task notes of %2$@  ·  ↩ opens it  ·  esc clears | 6 |
| | `popup.search.help.tags` | Tags: %@ | 5 |
| | `popup.search.help.notes` | Notes: %@ | 5 |

That is about 50 keys. All `%@`/`%ld` placeholders follow the "all numbered or none" rule
(`LocalizationTests.swift:265-282`).

Optional wording audit in PR 3, under its own prefix:

- `menuBar.group.openAll.tooltip.*` says "apps";
- `common.noAppsInGroup` says "No apps in this group yet";
- the Siri summaries in `ReportSummaries.swift` are English-only and not in the string tables.

Info.plist purpose strings, if A1 is confirmed (§2.6), aren't in `Localizable.strings` and stay
English.

---

## 8. Test plan (`Tests/DockGroupsCoreTests`, swift-testing, no real Dock or LaunchServices)

- **`GroupItemCodingTests`** (new; extends `WebsiteItemTests`, `DockGroupCodingTests`):
  - fixtures of 0.6.7 `groups.json` and agent config (apps, path-identified app, websites, Free
    Layout) decode to the same values and **re-encode byte-identical** with sorted keys;
  - file and folder round trip;
  - a file item writes no `path` and no `url`, its identity starts with `file://`, and a folder's
    ends with "/". These are the invariants the old decoder relies on (§5.3).
  - kind recovered when `kind` is missing; invalid file identity → missing app; unknown kind →
    missing app;
  - `tags` of the wrong type → empty tags, other fields kept; details limits, dedupe, "#"
    stripping and the ar/fa/zh/ja commas;
  - `displayName` uses the alias; `sortedByName` uses `displayName`.
- **`SettingsBackupTests`** (additions):
  - files and folders round trip; old fixtures (apps and websites) still read (unchanged test
    stays green); `schemaVersion` stays 1;
  - import drops: relative path, `..`, NUL, `PATH_MAX + 1`, host, query, fragment, a file ending
    in ".app", `.command`, `.sh`, `.py`, `.webloc`, a folder identity without "/", a file identity
    with "/";
  - `leftOutItemCount` and the summary `itemCount`; details sanitized; merge keeps details.
- **`FileItemPolicyTests`** (new): refusal by name (table); refusal by type with injected
  `ItemTypeInfo` (`public.unix-executable`, `public.shell-script`, `com.apple.application-bundle`);
  `.rtfd` package as a file is allowed; a plain folder is allowed; a package as a folder is
  refused or routed.
- **`ItemPresenceTests`** (new, `TemporaryDirectory`):
  - existing file → `.available`; deleted → `.missing`; file replaced by a folder → `.missing`;
  - `/Volumes/<random>/x` → `.volumeUnavailable`;
  - EPERM through an injected `FileSystemProbing` fake → `.unverified` (TCC can't be produced in
    tests); website → `.online`; app through a fake workspace.
- **`GroupLauncherTests`** (additions, `FakeWorkspace` records `openFileItems`):
  - open a file or folder → one call; missing → `.notFound` with **no** workspace call; refused
    (symlink to a `.command` in a temp dir) → `.failed` with **no** workspace call; kind mismatch →
    `.notFound`;
  - Open All order (apps, files batched, websites) with entries in group order;
  - `GroupTerminatorTests`: Close All and Hide All ignore files and folders.
- **`ItemSearchTests`** (new):
  - **equivalence:** for groups without details, `ItemSearchIndex.matches` equals
    `PopupFilter.filter` for every query in the `PopupKeyboardTests` fixtures (F2-3);
  - alias prefix beats name contains; tag word-prefix; notes word-prefix; multiple tokens (AND,
    any order); "a b" doesn't match "Xcode"; diacritics and Turkish ("faturayi" finds
    "Faturayı"); empty query; stable order within a rank; the reason holds the matched tag or
    notes excerpt;
  - performance smoke (§3.3).
- **`PopupQuickLookTests`** (extends `PopupKeyboardTests:143-170`): `target(for:presence:)` for
  each kind and presence; the Space action table is unchanged for apps.
- **`ItemActionTests`** (new, R1): availability matrix of kind × presence × context. Examples:
  a missing file in `.popup(isEditable: false)` (agent) → `[.open]`; the same file in
  `.popup(isEditable: true)` → `[.open, .locate, .moveTo, .remove]`; a found folder in
  `.groupWindow` → `[.showInFinder, .quickLook, .editDetails, .moveTo]`; a website in
  `.dockMenu` → `[.open]`.
- **`GroupStoreTests`** (additions):
  - `addItems` dedupe by identity (case-insensitive);
  - `relinkItem` keeps details, list position and the Free Layout cell (re-keyed), and refuses a
    duplicate;
  - `updateDetails` unchanged → no save (counting persistence fake), so no agent rebuild;
  - remove and move keep details.
- **`AgentModelTests` / `AgentPlannerTests`**: a config with files and details round trips; a
  config without details is byte-identical to 0.6.7, so no `outdated` rebuild.
- **`UsageTrackerTests`**: `file://` identities are never tracked (in `isTracked`).
- **`DiagnosticsReportTests`**: the report has per-kind counts but no paths, aliases, tags or
  notes (`DiagnosticsReport.swift:6`).
- **`LocalizationTests`**: unchanged code; only `awaitingTranslation` gains prefixes.
- **Manual (each UI PR):** the TCC gate (§2.6), downgrade to 0.6.7 with a new `groups.json` and a
  backup (§5.3 table, using the 0.6.7 build in `build/release`), Quick Look from Space and from the
  context menu in the main app and an agent, VoiceOver labels.

Run `scripts/test.sh` for every PR. Run `xcodegen generate` and commit the regenerated project
whenever source files are added (`AGENTS.md`).

---

## 9. Phased implementation plan (PR order)

The **first PR is PR 1**. The data format is the riskiest part, it is Core-only and fully
testable, and it fixes the compatibility invariants before any UI can create such items. There
are **7 PRs** (6 needed, 1 optional), plus an optional rename.

| PR | Title (Conventional Commits) | Scope | Acceptance criteria |
| --- | --- | --- | --- |
| **1** | `feat(core): file and folder items in the group model` | `Kind.file/.folder`, `FileLocation`, `FileItemPolicy` (by name + by type info), coding rules (§1.8), `sanitizedForImport` (§5.2) + `leftOutItemCount`, kind capabilities (§1.3) in Core files, `UsageTracker` / `RunningApplicationLookup` / `GroupTerminator` guards, `GroupStore.addItems` / `relinkItem`, `GroupItem` typealias. Keys: `core.item.error.program`. | All existing tests pass **unchanged** (notably `appsAreWrittenAsBefore`, `backupKeepsWebsitesAndOldBackupsStillRead`, `appLocationsMustBeAppBundles`); the new §8 coding, backup, policy and store tests pass; fixtures prove 0.6.7 data is byte-identical; no UI change. |
| **2** | `feat(core): open, reveal and check file and folder items` | `ItemPresence`, `ItemLocating` + `WorkspaceItemLocator`, `ApplicationWorkspace.openFileItems/revealFileItems`, `GroupLauncher` guard sequence (§2.3) and Open All order, `PopupQuickLook.target`, `ItemAction` availability (R1). Keys: the rest of `core.item.`. | §8 presence, launcher, Quick Look and action tests pass; every launch-refusal case calls no workspace method; no UI change. |
| **3** | `feat: add files and folders to groups` | Group window Add menu and `ItemPicker`, `ItemPresenceCache` (also removes the `body` lookup in `AppRowView`), rows per kind, Locate…; popup cells, help, VoiceOver, context menus from `ItemAction`, Space and menu Quick Look; agent Dock menu; backup texts counting items; README, CHANGELOG, screenshot. Keys: `addItems.`, `groupWindow.items.`, `item.` (kind, action, missing, volume, locate), `popup.item.`, `item.problems.`, `settings.backup.leftOut.`. | Manual TCC gate done and result recorded in the PR; files open in their default app and folders in Finder; Show in Finder selects the item; a missing item is dimmed with help text and can be located (details and cell kept); agent popup and Dock menu work; `scripts/test.sh` is green; `docs/l10n-keys.md` updated. **Must not be released without PR 4.** |
| **4** | `feat: keep a copy of the groups before installing an older version` | Pre-downgrade `copyAside` + warning (§5.3). Keys: `updates.otherVersions.items.`. | Installing 0.6.7 from Other Versions… (dry run, `CYBOKRON_UPDATE_DRY_RUN`) creates `groups.pre-downgrade-*.json` and shows the warning only when files, folders or details exist; the manual downgrade table (§5.3) is verified. |
| **5** | `feat: alias, tags and task notes for group items` | `ItemDetails` + coding + sanitizing, `GroupStore.updateDetails`, details popover (option B), `displayName` everywhere a name is listed (popup, rows, Dock menu, launch reports, sort, move targets unaffected), help showing tags and notes. Keys: `item.details.`, `popup.search.help.*`. | Details round-trip through `groups.json`, backup and agent config; an unchanged edit makes no save; one Done gives one agent rebuild; 0.6.7 reads a file with details (manual); tests pass. |
| **6** | `feat: find group items by alias, tags and task notes` | `ItemSearchIndex` (§3), index built with `PopupContent`, one-entry memo, footer match reasons. Keys: `popup.search.footer.*` (replaces `popup.footer.filter.matches` in all 26 tables). | Equivalence test (F2-3) passes; tag and notes matches rank after title matches; agent popup searches details; performance smoke passes. |
| 7 *(optional)* | `refactor: share group actions between the app and its agents` | `GroupActionPerformer` (R2). | No user-visible change; Close All policy (D1) is explicit and tested at the Core boundary; diff removes the duplicate wrappers in §6.1. |
| 8 *(optional)* | `refactor: rename AppReference to GroupItem` | Mechanical rename, JSON keys untouched. | Build + tests green; no behavior or format change. |

Releases: PR 1 and 2 can ship in any release (nothing visible). PR 3 and 4 ship **together**.
PR 5 and 6 can follow in the next release. Each release bumps the version and build number
together (`AGENTS.md`, `scripts/check-version.sh`).

---

## OPEN QUESTIONS

1. **Alias meaning.** Should the alias **replace the shown name** everywhere the item is listed,
   with the original name kept for search and shown as "Name: …" (recommended)? Or should it only
   be an extra search keyword that is never displayed?
2. **Task notes format.** Should notes be **multi-line**, up to 500 characters, edited in a 2–5
   line field and shown cut to one line in help text (recommended)? Or a single line of up to 120
   characters?
3. **Open All and files or folders.** Should Open All open files and folders too, with every folder
   becoming a Finder window (recommended: yes, no per-item switch in v1)? Or apps and websites only,
   with files and folders opened individually?
4. **Programs and scripts as files.** Should `.command`, shell, Python and other executable or
   script files, location files and installers **always be refused** (recommended, §1.5)? Or
   allowed when the user adds them locally, with a confirmation each time one is opened (never
   through backups)?
5. **Following moved files.** Is **paths plus Locate…** enough for v1 (recommended)? Or should
   v1 store plain bookmarks (in `groups.json` and agent configs only, never in backups) so moved
   or renamed files on the same volume are followed automatically?
