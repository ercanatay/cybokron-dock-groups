# Launch actions (E phase 2): design options and threat model

- **Status:** design and threat model only. No code, no release decision, no spike run. Nothing
  here is implemented.
- **Baseline:** `main` at `10233ff`. File references are `path:line` at that commit, relative to
  `Sources/` unless they start with `Tests/`, `docs/` or a root file.
- **Builds on:** [context-switching-spec.md](context-switching-spec.md) (E phase 1: delay and Open
  With, invariants L-1…L-7 in §5.3, residual risks §5.4),
  [group-items-and-tags-spec.md](group-items-and-tags-spec.md) (item model, file checks, backups),
  [app-presence-threat-model.md](app-presence-threat-model.md) (format of this document),
  [quit-authentication.md](quit-authentication.md) (authentication and confirm-delay patterns),
  `SECURITY.md` "Scope".
- **Marking:** claims about Apple or third-party app behaviour that were not checked on a Mac for
  this document are marked **(unverified)**. Guarantees that cannot be given are marked **not
  achievable**.

## 1. Scope and user stories

E phase 2 was deferred by every earlier spec (context-switching-spec.md non-goals and L-1;
`ItemLaunchOptions.swift:7-9`: "no arguments, commands or scripts"). The research idea
(context-switching-spec.md §1.3) is a small launch recipe per item. Three features:

| # | Feature | User story | What it would do |
| --- | --- | --- | --- |
| F1 | **Arguments per item** | "Open VS Code on `~/Projects/cybokron`", "open Xcode with this workspace", "open an app with a flag it documents". | Pass extra launch arguments to an app item (or to the app chosen to open a file/folder/website). |
| F2 | **Browser profile** | "Open GitHub in Chrome's *Work* profile, YouTube in *Personal*." | Open a website item in a chosen browser **and** a chosen profile of that browser. |
| F3 | **Terminal command / script** | "Open Terminal in the project folder and run `npm run dev`." "Run my setup script when I Start the group." | Run a shell command or script, in a terminal window or headless. |

Part of F1 is already covered: "open a folder or file with a chosen app" is Open With
(`ItemOpenerPolicy.swift:74-139`), and "Terminal in a folder" is the folder-terminal exception
(DECISION 5, `ItemOpenerPolicy.swift:105-106`, `:133-134`). The new value of F1 is flags and
non-document arguments; of F2, the profile; of F3, actually running code.

## 2. Today's boundary

### 2.1 How items open

Every item opens through `GroupLauncher` (`Launching/GroupLauncher.swift:64`) and the
`ApplicationWorkspace` protocol (`Launching/ApplicationWorkspace.swift:5-32`):

| Item | Path | API | Data from the file |
| --- | --- | --- | --- |
| App, running | `GroupLauncher.swift:109-113`, `:170-171` | `NSRunningApplication.activate`, or `NSWorkspace.openApplication(at:)` to bring it forward (`ApplicationWorkspace.swift:55-73`, `:158-165`) | `bundleIdentifier` |
| App, not running | `GroupLauncher.swift:114-117`, `:172-195`; bundle check `:256-265` | `NSWorkspace.openApplication(at:configuration:)` with only `activates = true` (`ApplicationWorkspace.swift:79-90`, `:167-171`) | `bundleIdentifier`, fallback `path` (must be a `.app` path: `AppItemPolicy.swift:22-34`, `FileLocation.swift:61-64`) |
| Website | `GroupLauncher.swift:222-254` | `NSWorkspace.open(_:withApplicationAt:configuration:)` with the default browser or the chosen opener (`ApplicationWorkspace.swift:92-98`, `:137-151`) | `bundleIdentifier`/`url` (http/https only, no credentials: `WebsiteAddress.swift:37-67`), `openWith` |
| File / folder | `GroupLauncher.swift:270-297`, checks `:344-363` | same, one request per handler; refused handlers `ApplicationWorkspace.swift:100-129` | `file://` identity (`FileLocation.swift:20-30`, `:54-57`), `openWith` |
| Delayed item | `DelayedLaunches.swift:118-135` | re-reads the group at fire time; opens only items whose identity, kind and `launch` are unchanged | `launchDelay` |

The opener is a bundle identifier only (`ItemLaunchOptions.swift:39-71`), checked at every launch
(`ItemOpenerPolicy.swift:124-139`); a refusal opens nothing (`ItemOpenerDecision.refused`,
`:61-72`). Imports drop runner openers (`Persistence/SettingsBackup.swift:196-215`).

**No group-data path uses `Process`, a shell, AppleScript or `NSWorkspace.OpenConfiguration`
`arguments`/`environment`.** `Process` exists only for fixed tools with fixed arguments:
`codesign`/`lsregister`/`killall` with `stdin = /dev/null` (`DockGroupsCore/Standalone/SystemTools.swift:25-75`)
and the update relaunch through `/bin/sh -c <constant script>` with paths passed as positional
arguments, never spliced (`DockGroupsCore/Updates/UpdateInstaller.swift:604-620`,
`CybokronDockGroups/Updates/AutoUpdater.swift:499-501`). Those patterns are reusable *as
technique*; none of their inputs come from group data.

### 2.2 What group data can already make the app do

From `AppReference` decoding (`Model/AppReference.swift:164-247`): any installed app by bundle
identifier, any `.app` bundle by path, any http(s) URL in a browser macOS lists for it, any
non-program file or plain folder with a listed non-runner app, a folder in Terminal/iTerm2. Unknown
keys are not read and are **dropped on the next save** (fixed `CodingKeys`, `:165-167`, `:225-247`).

`groups.json` is loaded with no sanitizing pass (`Store/GroupStore.swift:749-753`); safety comes
from launch-time checks. Backups are sanitized on decode (`SettingsBackup.swift:147-164`,
`:200-232`) and again on restore (`GroupStore.swift:610`, `:646`, `:704-720`). Templates keep
launch options (`Model/GroupTemplate.swift:4`). Standalone groups read their own
`Contents/Resources/group-config.json` (`Standalone/AgentBundleLayout.swift:9`, `:38`;
`CybokronDockGroups/Agent/AgentAppDelegate.swift:55`, `:172-181`) and launch through the same
`GroupLauncher`.

The governing rule (`SECURITY.md` "Scope"; Turkish project notes `06_GUVENLIK.md` rules 1, 2, 5,
9): **a write to a data file must not become code execution.** Every option below is judged
against that rule.

## 3. Attack surface

Attacker model as in `app-presence-threat-model.md` §2: not root, not a kernel or TCC bypass. The
interesting attackers are those who can **write or hand over data** or **trigger** a group, but
cannot already run arbitrary code as the user.

| Surface | How data/trigger arrives | What the attacker gains if launch actions are naive |
| --- | --- | --- |
| **S1 Hand-edited / foreign-written `groups.json`** | A user pastes a "recipe" from a blog; a sync tool, dotfiles repo or another app with file access writes `~/Library/Application Support/Cybokron/DockGroups/groups.json` | F3: the next click/Open All/Start/trigger runs their shell. F1: flags that load code into an app (see T2). F2: their profile/data dir. Today the same write yields at most "open an installed app/URL/file". |
| **S2 Backup import / restore / merge** (`.dockgroups`) | Anyone can send a backup; Replace All and Merge both bring groups, archived groups and templates (`SettingsBackup.swift:151-160`) | Same as S1 — the most realistic vector (context-switching-spec.md §5.1). |
| **S3 Templates** | Templates come from backups and keep launch options | An action planted in a template is re-created in every group made from it. |
| **S4 Links** `cybokrondockgroups://launch|start/<group>` | Any web page or app (`Commands/URLCommand.swift:101-110`, rate limited `:144`) | Cannot choose the action, but **chooses when** an already-configured action runs, unattended. |
| **S5 Siri / Shortcuts / Focus filter** | Intents name a group (`CybokronDockGroups/Intents/*`) | Same as S4: timing, no presence of the user. |
| **S6 Triggers** (time, login, display, Wi-Fi, app presence) | `triggers.json`; backup triggers come in off (`SettingsBackup.swift:166-170`) | Unattended execution; with app-presence triggers, a chain "another app opens → Start → run script". |
| **S7 CLI** `cybokrondockgroups start|finish|open` | Only group names, mapped to links (`Commands/DockGroupsCLI.swift:3-35`) | Same as S4; any local process can call it. |
| **S8 Standalone group app** | `group-config.json` inside an ad-hoc signed agent bundle | Second copy of the action data, outside `groups.json`; a write there also becomes execution. |
| **S9 Delayed launch** | Action runs up to 60 s after the command (`ItemLaunchOptions.swift:12-13`) | Window for swapping the file/app between decision and launch (TOCTOU). |
| **S10 Item editor / paste** | The user types or pastes arguments | Social engineering: "paste this into the Arguments field". |

## 4. Threat table

"Option" refers to §5: **A** templates, **B** free argv via LaunchServices, **C** shell/terminal.

| Threat | Reachable guarantee | Verification | Residual risk | Fail-closed behaviour |
| --- | --- | --- | --- | --- |
| **T1 Arbitrary command execution** | **A:** none can occur — the stored data is a template ID plus typed parameters; no field is a program, path to a program, or code. **B:** no *shell*, but **not** "no code execution" (T2). **C:** **not achievable** — running user-supplied code is the feature. | A: decoder fixtures with crafted `command`, `script`, `executable`, `shell`, `argv` keys prove they are not read or kept (same pattern as `06_GUVENLIK.md` rule 5 for triggers). | A: a template author bug. C: everything. | Unknown template ID, unknown key → action ignored, item **not opened**, report says why. |
| **T2 Argument injection (option/flag injection)** | **A:** each parameter is exactly one argv element, validated against a per-template grammar (e.g. Chromium profile dir `^(Default\|Profile [1-9][0-9]{0,2})$`), never starts with `-`, built as `--flag=value` in one element. **B:** **not achievable** in general. Many apps treat arguments as code or configuration: Chromium `--load-extension=`, `--remote-debugging-port=` (opens the whole browser profile to any local process), `--user-data-dir=`; Electron apps `--inspect`, `--js-flags`, VS Code `--extensionDevelopmentPath`; every Cocoa app reads `-SomeDefault value` into its argument defaults domain **(app-specific behaviour, unverified per app)**. A denylist of flags cannot be complete. | A: per-template property tests (random strings, leading `-`, `=`, spaces, NUL, newlines, RTL marks, very long input) all refused. B: fixtures for known dangerous flags are only examples, not proof. | B: an approved argv can still be dangerous; the user is the only check. | Parameter fails grammar → action invalid → item not opened. |
| **T3 Path traversal (`../`, `~`, symlink)** | A path parameter (if a template needs one) is a `file://` identity under the existing rules: absolute, no `.`/`..`, no NUL, no `%2F`, `< PATH_MAX` (`FileLocation.swift:20-30`, `:54-57`), checked on disk with symlinks resolved and `FileItemPolicy` applied (`GroupLauncher.swift:344-363`). `~` is **never expanded** (no shell); a leading `~` is just refused by "absolute". Symlink retargeting after the check: **not achievable** to exclude completely (the target app opens the path itself later). | Reuse `FileItemPolicyTests`/`FileItemLauncherTests` fixtures; new fixtures for the parameter field. | Symlink swapped between check and the target app reading it. Equivalent to today's file items. | Invalid path → not opened, "isn't where it was" / "can't be opened safely". |
| **T4 Environment variable leakage / injection** | **No action ever carries an environment.** `NSWorkspace.OpenConfiguration.environment` stays unset; `Process` is not used (§5). Env injection (`DYLD_INSERT_LIBRARIES`, `NODE_OPTIONS`, `ELECTRON_RUN_AS_NODE`, `PYTHONSTARTUP`) is code execution, so there is no "allowed env" list. | Decoder fixture with `environment`/`env` keys: not read, not written; a fake workspace asserts that the configuration passed has an empty environment. | C (if ever): a shell inherits the app's environment unless cleared — and clearing is not enough, the script itself is code. | Data with env keys → ignored; no fallback needed (it was never a field). |
| **T5 Shell interpretation (metacharacters)** | **A, B:** no shell anywhere; argv goes to LaunchServices as an array, so `;`, `\|`, `&`, `$()`, backticks, `>`, globbing have no meaning. **A additionally** refuses those characters in parameters (defence in depth and a clear error). **C:** **not achievable**: a terminal command is shell by definition; quoting can only protect *parameters spliced into* a fixed script (the `UpdateInstaller` pattern), not a user-written command. | Unit test that the workspace receives the exact array; fixtures with metacharacters refused by A's grammar. | C only. | A: refused parameter → not opened. |
| **T6 Browser profile data leakage** | Validated profile **name/dir only, never a path**: no `--user-data-dir`, no Firefox `--profile <path>` (would point the browser at an attacker-supplied profile with planted extensions or settings). **Not achievable:** guaranteeing the URL really opens in that profile — vendor behaviour, can change, and an already running browser may ignore launch arguments **(unverified; spike required, §10)**. Safari profiles: no public launch API known **(unverified)** → not offered. | Grammar tests; spike on Chrome, Edge, Brave, Firefox with the browser running and not running; downgrade test (old version opens the URL without the profile, §8). | A work URL opening in a personal profile (or the reverse) when the browser ignores the argument, on downgrade, or when the profile was deleted. | Unknown browser template, invalid name → not opened. A profile that does not exist: decision §10 (default: let the browser decide — it cannot be checked without reading the browser's files). |
| **T7 Stdin / output leakage** | LaunchServices-launched apps do not inherit the app's stdio **(macOS behaviour, unverified in this repo)**. No action output is captured, shown or logged. Logs keep `logIdentity` only (`AppReference.swift:124-139`); **arguments are never logged** (they may contain tokens). | Log-privacy test: a launch with a secret-looking parameter leaves no trace in the `Logger` fake / report text beyond the template name. | C: a script's output, files it writes, and the terminal's scrollback. | n/a |
| **T8 User-approval race (TOCTOU, clickjacking)** | Approval binds to a **digest of the normalized action** (item identity + kind + opener bundle ID + template ID + parameters, or the argv array in B). At launch, the digest is recomputed and must match; a delayed launch re-checks at fire time (extends the `DelayedLaunches.swift:124-129` comparison). The confirm button is enabled after a delay (`GroupQuitRequests.swift:30-33`, 0.7 s). **Not achievable against a same-user attacker who writes both the action and its approval** — any approval store in the user's Library can be forged, and a Keychain HMAC was already rejected (context-switching-spec.md §5.4; `06_GUVENLIK.md` "Yapılmaması gerekenler"). Synthetic clicks need the attacker's own Accessibility trust (out of model). | Unit tests: change one parameter after approval → refused; change during the sheet → refused; delayed item changed → not opened. | Forged approval by a same-user writer (who could already install a LaunchAgent). | Digest mismatch or missing approval → **not opened**, "needs your approval", one click away from the review sheet. |
| **T9 Parent-process identity** | With `NSWorkspace.openApplication`, LaunchServices starts the app, not as our child **(widely documented, unverified here)**; it is its own TCC "responsible process". With `Process`, the child is ours: it is attributed to Cybokron Dock Groups for TCC (it could inherit or prompt under our name — Location, Accessibility if granted) **(TCC responsible-process attribution, unverified here)**, it shows as spawned by a Developer ID signed app to EDR tools, and it dies or is orphaned with us. Hence: **no `Process` for launch actions.** | Code review rule + a test that the production workspace has no `Process` path for items (grep-style test, as `SECURITY.md` claims are tested today). | C would need `Process`, AppleScript to Terminal (Automation permission, which the app never requests: `06_GUVENLIK.md` "Entitlements ve TCC") or writing a `.command` file (refused type: `FileItemPolicy.swift:48-69`). | n/a |
| **T10 Unattended execution (S4–S7)** | A: templates are harmless enough to run from every path. B: argv runs only from **user-present paths** (click in popup/group window, Open All/Start from the app's own UI); links, intents, Focus, triggers, CLI, agents skip it. | Tests per source (`URLCommand`, intents fakes, `TriggerCoordinator` fakes) that a B item is skipped with a reason. | A web page can still time an A action. | B item from an unattended source → skipped, report "opens with its arguments only when you open it yourself". |
| **T11 Import / template propagation (S2, S3)** | Actions from backups and templates come in **disabled** ("needs review"), never silently enabled; counted in `SettingsRestoreSummary` like `resetLaunchOptionCount` (`SettingsBackup.swift:262-264`). | Backup fixtures: action present → item kept, action disabled, count shown. | User approves without reading. | Disabled action → item not opened (decision §10: or opened plain). |
| **T12 Downgrade / unknown fields** | Old versions don't read the new key and drop it on save (§8). | Real-binary downgrade test with 0.11.x/0.12 copies. | Old version opens the item without the action (privacy for F2), then forgets it. | Old version: plain open. New version reading an action written by a newer one with unknown template ID → not opened. |
| **T13 Standalone agent copy (S8)** | Agents don't run B actions in the first slices; A actions only if the agent re-validates identically. | `AgentConfiguration` coding tests. | A writer of an agent's bundle (ad-hoc signed) already replaces its executable. | Agent: B item → skipped with reason. |

## 5. Design options and recommendation

### (A) Pre-defined, allowed action templates

The user picks from a list shipped with the app; each template has a fixed target (bundle
identifier set), a fixed argv skeleton and typed, validated parameters. Examples:

- `browser.chromium.profile` — Chrome / Edge / Brave / Vivaldi (fixed bundle-ID list): one
  parameter `profileDirectory` matching `^(Default|Profile [1-9][0-9]{0,2})$`, built as
  `--profile-directory=<value>` followed by the website URL. Optional display name kept only for
  the UI.
- `browser.firefox.profile` — `-P` `<name>` with a strict name grammar (no `/`, no leading `-`,
  printable, ≤ 64), **never** `--profile <path>`.
- `app.openDocument` — exists already as Open With; no new template needed.

Stored as e.g. `"launchAction": {"template": "browser.chromium.profile", "profileDirectory":
"Profile 2"}` on the item. **Guarantee:** data can select only shipped behaviour; nothing in the
file is code, a program path or a raw argument. **Complexity:** M (model + decoder + editor +
per-template validator + a spike per browser). **UX:** limited but predictable; covers F2 and the
most-requested slices of F1; F3 not covered.

### (B) Free arguments for app launch, no shell

An app item (or opener) gets `arguments: [String]` passed as
`NSWorkspace.OpenConfiguration.arguments`; never a shell, never `Process`, never environment.
**Guarantee:** no shell interpretation (T5), no env (T4), no path to an executable (the app is
still a bundle ID / `.app` path). **Not** a guarantee of no code execution (T2). Requires: approval
bound to a digest (T8), user-present paths only (T10), disabled on import (T11), full argv preview.
Arguments only apply when the app is launched; for a running app they are ignored **(Apple
documents `arguments` for the launched app; behaviour with a running app unverified)** — and
today a running app is activated first (`GroupLauncher.swift:109-113`, `:170`). A "new instance"
switch (`createsNewApplicationInstance`) would change that but creates duplicate instances for
most apps; not recommended. **Complexity:** M–L (approval store, digest, source gating, editor,
spike). **UX:** powerful, but "arguments are used only when the app isn't already running" will
surprise users.

### (C) Free script / terminal command

Run a user-written command (headless via `Process` with `/bin/zsh -c`, or typed into Terminal via
AppleScript, or by writing a `.command` file). **Guarantee:** none beyond "the user approved this
text" (T1, T5, T9 not achievable). It would contradict `SECURITY.md` "Scope", `06_GUVENLIK.md`
rules 1, 2, 5, 9 and "Accessibility/Automation hiç istenmez", context-switching-spec.md L-1, and
turn any data-file write into code execution. **Complexity:** L (plus permanent security debt).
**UX:** most powerful; also the most dangerous to recommend in a "paste this recipe" world.

### (D) Mentioned alternative: run a named Shortcut

Instead of C, an action that runs one of the user's existing Shortcuts by name
(`shortcuts run <name>` CLI or the `shortcuts://run-shortcut?name=` URL **(both exist on macOS 12+;
behaviour from a non-sandboxed app unverified)**). Execution then happens in the Shortcuts app's
own permission model, and the shortcut must already be installed by the user — the analogue of
"launch an installed app". Still: a crafted file can run *any* installed shortcut by name, and
shortcuts can do anything the user allowed them. If pursued, treat like B (approval, user-present,
disabled on import). Not part of the recommendation; listed so C is not chosen for lack of
alternatives.

### Recommendation

**Start with A, consider B only after A has shipped and been reviewed; do not build C.**

- A meets the existing invariant ("a write to a data file must not become code execution")
  without new trust machinery; F2 is the most concrete user story and fits A exactly.
- B needs an approval model whose strongest form is still forgeable by a same-user writer (T8)
  and cannot exclude code-loading flags (T2). It is acceptable only as an explicit, opt-in
  "advanced" feature, user-present only.
- C violates the project's stated security boundary; its user story is better served by D or by
  "open folder in Terminal" (already shipped).

| | A | B | C |
| --- | --- | --- | --- |
| No shell | yes | yes | no |
| No code execution from data | yes | **no** (T2) | no |
| Needs approval store | no (import still disabled) | yes | yes |
| Unattended paths | allowed | refused | refused |
| Effort | M | M–L | L |

## 6. Fail-closed contract

Applies to every source (editor, `groups.json`, backup, template, agent config) and is checked at
**launch time**, again at delayed fire time — never only in the UI (`06_GUVENLIK.md`
"Yapılmaması gerekenler").

1. **Nothing opens on doubt.** If an item has an action and any check fails, the item is **not
   opened at all** — not with its default app, not without the action (same rule as L-5 for
   refused openers). The launch report names the item and the reason; nothing silent.
2. **Unknown template ID, unknown parameter key, wrong JSON type, missing required parameter** →
   action invalid → not opened ("this item's launch setting isn't supported by this version" /
   "…is incomplete").
3. **Parameter grammar** (per template) refuses, at minimum: empty, leading `-`, control
   characters and NUL, newlines, `/` and `\` where a name is expected, `..`, `~`, `$`, `` ` ``,
   `;`, `|`, `&`, `>`, `<`, `*`, `?`, quotes, `=` where not part of the skeleton, bidi override
   characters, more than the template's length limit. Refuse — never strip, escape or "fix".
4. **Absolute-path injection:** a parameter that is not declared as a path and looks like one
   (`/…`, `file:`, `~…`) is refused. A declared path follows `FileLocation`/`FileItemPolicy` and
   the on-disk check.
5. **Target mismatch:** the template's bundle-ID set does not contain the resolved app (or the
   bundle at the location doesn't have that ID, as `ItemOpenerPolicy.swift:129-132`) → not
   opened.
6. **Environment, command, script, executable, shell keys** are never read, never written, never
   preserved (as triggers today).
7. **Approval missing, disabled (imported) or digest mismatch** (B; and imported A actions) → not
   opened, "needs your approval".
8. **Unattended source for a B action** → skipped with a reason; A follows the normal source rules.
9. **App not installed** → "not found", as today; **no** fallback to another browser/app.
10. **Older version** reading new data: action ignored (§8) — this is the one accepted non-fail-
    closed case and is documented.
11. **Newer version's data** (unknown template) in this version → rule 2.
12. **Permissions:** no new entitlement, TCC purpose string, Automation or Accessibility request is
    introduced by A or B. If a future design needs one and it is denied → not opened.

## 7. Confirmation and visibility

- **Editor:** the item editor's "Opening" part (where Open With and the delay live) gets a
  **Launch action** picker: None (default) / the templates offered for that item kind and target.
  Each shows an exact preview: app name + bundle identifier + the final argv, one element per
  line, e.g. `Google Chrome (com.google.Chrome)` / `--profile-directory=Profile 2` /
  `https://github.com`.
- **Row caption:** extends `ItemLaunchCaption` (`ItemLaunchOptions.swift:97-133`): "Opens in
  Chrome · profile “Profile 2”"; an action needing review shows "Launch setting needs review".
- **B approval sheet:** full argv preview, monospaced, with invisible characters shown; the confirm
  button is enabled after 0.7 s (`GroupQuitRequests.swift:30-33`); approval is per item and per
  digest; changing any part revokes it. The text says plainly that arguments can make an app run
  code.
- **Import:** restore/merge confirmation counts actions that come in disabled (new
  `SettingsRestoreSummary` field next to `resetLaunchOptionCount`), mirroring the triggers note
  (`SettingsBackup.swift:312-321`). After import, items with disabled actions are listed in the
  group window with a "Review" button.
- **Launch report:** refusals use the existing report format ("• GitHub: wasn't opened, because
  its launch setting needs your approval.").
- **Never shown in logs or diagnostics:** parameter values or argv; diagnostics may count actions
  per template ID.

## 8. Backward compatibility

- **Where it lives:** a new optional item key (working name `launchAction`) written only when set,
  like `launchDelay`/`openWith` (`AppReference.swift:243-246`). Phase-1 options stay as they are.
- **Older versions** (≤ current) don't know the key: they open the item plainly and **drop the key
  on their next save** (fixed `CodingKeys`, `AppReference.swift:165-167`). For F2 this means a
  URL can open in the default profile after a downgrade (T6/T12); accepted and documented.
- **`formatVersion` bump: not recommended.** `groups.json` stays at `formatVersion` 1
  (`Persistence/GroupPersistence.swift:52-56`). A bump makes older versions fail the whole load
  (`GroupPersistence.swift:116-118`): they move the file aside and start with an **empty group
  list** (`Store/GroupStore.swift:749-770`). That is far worse for users than losing an action.
  Same for the backup `schemaVersion` (`SettingsBackup.swift:36-37`, `:138-140`: a newer one is
  refused) and the agent `formatVersion` (`Standalone/AgentConfiguration.swift:13`, `:50`).
- **If** losing actions on downgrade is unacceptable for B, the alternative is a separate file
  (e.g. `launch-actions.json`, keyed by group ID + item identity) that old versions never touch;
  cost: keeping it in sync with remove/move/duplicate/archive/template. Decision in §10.
- **Before release:** a real-binary round trip (0.11.x and the release before it) as required in
  `24_TETIKLEYICI_012_TASARIM_ADAYI.md` "Dosya uyumluluğu" for triggers.

## 9. Test strategy

| Threat | Unit / fixture tests (SwiftPM, `Tests/DockGroupsCoreTests`) | Manual only |
| --- | --- | --- |
| T1 | Decoder fixtures with `command`/`script`/`shell`/`executable`/`argv` keys: not kept on round trip; launcher fake never receives them (pattern: `LaunchOptionsLauncherTests.aCraftedGroupsFileCantRunCodeThroughLaunchOptions`, `:118`). | — |
| T2 | Per-template grammar tables (`@Test(arguments:)`, as `SecurityHardeningTests.swift:146`): leading `-`, `--load-extension=…`, `--remote-debugging-port`, `=`/space smuggling, long input. Workspace fake asserts the exact argv. | Spike: each browser with each accepted value. |
| T3 | Path-parameter fixtures reusing `FileItemPolicyTests`/`FileItemLauncherTests` cases (`..`, `%2F`, NUL, `~`, symlink to `.command`). | Symlink swap during a delayed launch. |
| T4 | Fake workspace asserts empty environment; fixture with `environment` key dropped. | — |
| T5 | Metacharacter table refused by grammar; exact-array assertion. | — |
| T6 | Bundle-ID set per template; unknown browser refused. | Browser running vs. not running; profile deleted; downgrade opens default profile. |
| T7 | Logger/report fakes contain no parameter values. | Console.app check during a real launch. |
| T8 | Digest changes on every field; change after approval → refused; delayed fire with changed action → not opened (extends `DelayedLaunchesTests`). | Sheet confirm delay; editing the file while the sheet is open. |
| T9 | Source-level test that the item launch path doesn't reference `Process` (similar to existing script-based checks in `ScriptTests.swift`). | Activity Monitor: launched app's parent is `launchd`. |
| T10 | Per-source tests (`URLCommandTests`, intent fakes, `TriggerCoordinatorTests`, CLI) that B items are skipped with a reason. | Focus filter and Shortcuts automation on a real Mac. |
| T11 | `SettingsBackupTests`/`GroupTemplateTests`: actions come in disabled, counted; merge and Replace All. | Restore UI text. |
| T12 | Fixture of a 0.12-style file decoded by current code (sentinel test as in `24_…` "Sentetik uyumluluk gözlemi"). | Real downgrade/upgrade with signed builds. |
| T13 | `AgentConfiguration` coding: action round trip; B skipped in agent launcher. | Standalone app rebuild after editing an action. |

## 10. Open decisions, effort and slice order

| # | Decision | Recommended default |
| --- | --- | --- |
| D1 | Which option to build first | **A only.** B later behind its own review; C not at all. |
| D2 | Which templates in the first release | Chromium-family profile (Chrome, Edge, Brave; Vivaldi/Arc only if the spike confirms the flag). Firefox second. Safari not offered. |
| D3 | Profile chosen by typed directory name or read from the browser's `Local State` / `profiles.ini` | **Typed / pick from a fixed `Default`, `Profile 1…N` list**, no reading of other apps' files (avoids new file access and possible macOS "data from other apps" prompts — unverified). Reading for display names can come later. |
| D4 | Imported actions (backup, template from backup) | **Disabled until reviewed**, item kept. |
| D5 | Disabled/invalid action: open the item plainly or not at all | **Not at all** (fail closed, consistent with L-5), with a one-click "Review". |
| D6 | B actions from links, Siri, Focus, triggers, CLI, agents | **Skipped** with a reason; only user-present paths. |
| D7 | Arguments for an already running app (B) | **Not applied; caption says so.** No `createsNewApplicationInstance`. |
| D8 | Storage for B (item key vs. separate file) | Item key (simpler); accept loss on downgrade. Revisit if B is approved. |
| D9 | Approval store and binding (B) | Separate local file, digest per item; accept forgery by a same-user writer as residual risk (no Keychain HMAC — already rejected). |
| D10 | Named-Shortcut action (D) | Out of scope until B is decided; if ever, same gates as B. |
| D11 | Standalone agents | A: supported once the agent re-validates; B: skipped. |

**Spikes before any code (S, manual, no release):** Chrome/Edge/Brave/Firefox with `arguments`
via `NSWorkspace.openApplication` and `open(_:withApplicationAt:configuration:)`, browser running
and not running; parent process of the launched app; whether launch arguments are ignored for a
running app.

**Suggested slices:**

1. **Spike + spec update** (S): record spike results; finalize templates and grammar.
2. **Core model + decoder + validator** (M): `launchAction` key, template registry, fail-closed
   rules 1–6, 11; fixtures T1–T5, T12. No UI; nothing writes the key yet.
3. **Launcher integration** (M): build argv per template, pass via `OpenConfiguration.arguments`
   (extend `ApplicationWorkspace.open(_:withApplicationAt:)` / `launchApplication(at:)` with an
   arguments parameter), delayed re-check, report texts, log privacy (T6–T8 partial, T9).
4. **Editor + caption + import gating** (M): picker, preview, disabled-on-import, restore summary,
   localization keys (T11).
5. **Agent support for A** (S–M) and the downgrade round trip (manual).
6. *(Optional, separate review)* **B** (L): approval sheet, digest store, source gating (T8, T10).

C is not scheduled.

## 11. Documents to update if this is accepted

- `context-switching-spec.md` §5.3 L-1 ("no arguments") and `ItemLaunchOptions.swift:7-9` doc
  comment: would need to say "only shipped templates; no free arguments, environment, commands or
  scripts" once A lands. Until then they are correct and **this document does not override them.**
- `SECURITY.md` "Scope": one sentence on launch templates (and, only if B ships, on approved
  arguments being able to make an app run code).
- `09_YOL_HARITASI.md` item 5: scope narrowed to "templates first; terminal commands/scripts not
  planned".
- `06_GUVENLIK.md`: add rule "launch actions are templates; imported ones come in disabled".
