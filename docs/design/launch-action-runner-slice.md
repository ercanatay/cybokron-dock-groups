# Slice: launch action runner and launcher integration (slice 3, launcher part)

Status: internal Core code wired into the launcher. **An enabled, valid launch action is now
executed**: a website item with a browser-profile action is opened by starting its browser with the
plan's arguments. There is still no UI to set an action, no localization key, no `formatVersion`
change, no new entitlement or permission, and no agent support. This is the second half of slice 3
of the [launch actions threat model](launch-actions-threat-model.md#10-open-decisions-effort-and-slice-order);
it builds on the [core slice](launch-action-core-slice.md) and the
[argument plan](launch-action-argv-slice.md).

## The rule: a running browser is refused

**If the target browser is already running, nothing is opened.** No arguments are passed, the URL
is not sent to the running browser as a new tab, and no other browser is tried. If the browser is
not running, it is started with the plan's arguments and asked to open the item's address.

Why: macOS only hands launch arguments to an app it starts. A running browser receives the address
through LaunchServices without the arguments, so the page would open in whatever profile that
browser shows — possibly the wrong one (T6: a work page in a personal profile or the reverse).
That can't be detected or undone afterwards, so the only fail-closed choice is not to open. This
is D7 ("not applied") taken one step further: instead of opening without the arguments, the item
isn't opened at all (D5). There is no `createsNewApplicationInstance` (a second browser instance
for the same profile store is not what users want, and Chromium's process singleton would hand it
to the running one anyway — unverified for this exact call).

Verified on this Mac (macOS 26, 2026-11-11; see [Real-machine check](#real-machine-check)): with
Chrome and Firefox running, both `open -a … --args …` and the runner's exact
`NSWorkspace.open(_:withApplicationAt:configuration:)` call with `arguments` set returned the
**already running process** and started no new one: the arguments never reached the browser.

## Scope

- `Sources/DockGroupsCore/LaunchActions/LaunchActionRunner.swift` (all `internal`):
  - `LaunchActionWorkspace` — what the runner needs of the system: is a bundle ID running (ignoring
    case), where is it installed, which bundle ID does the bundle at a location have, start an app
    with a configuration. `SystemApplicationWorkspace` conforms in this file, so this is the
    **only** source file that passes `arguments` or `environment` to
    `NSWorkspace.open(_:withApplicationAt:configuration:)`.
  - `LaunchActionRunner.run(_ plan:) -> LaunchActionRunOutcome` — `.launched` or
    `.refused(.browserAlreadyRunning | .browserNotInstalled | .launchFailed)`.
  - `LaunchActionRunner.configuration(for:)` — `arguments = plan.arguments`, `environment = [:]`
    (T4), `activates = true`, `createsNewApplicationInstance = false`.
  - `LaunchActionItemRefusal` — why an item with an action wasn't opened:
    `unattendedSource(source)`, `noRunner`, `plan(reason)`, `run(reason)`; a fixed `code` for the log.
- `Sources/DockGroupsCore/LaunchActions/LaunchSource.swift` (`public`): who asked to open items.
- `GroupLauncher`: `open(_:inGroup:restoringWindows:source:)`, `openAll(_:source:)` and
  `openRightAway(_:inGroup:context:source:)` take a `LaunchSource` (default `.unspecified`, which
  counts as unattended). `LaunchReport.Entry` gains an internal `launchActionRefusal`.
- `DelayedLaunches`: a delayed item opens only if its launch action setting is unchanged too.
- `ContextSwitcher.start` passes `LaunchSource(trigger)`; the app and the standalone agent pass
  their source at every call site.

## The runner

Checked in this order; the first failure wins and starts/opens nothing:

1. The plan's browser is installed (`applicationLocation`), the location is a `file:` URL of an
   app bundle (`FileLocation.isAppBundlePath`), and the bundle there reports the plan's bundle
   identifier (ignoring case) → else `browserNotInstalled` (§6 rule 5: target mismatch).
2. No instance of that bundle identifier runs (asked last, right before starting, to keep the race
   window short) → else `browserAlreadyRunning`.
3. `startApplication(at:opening:[plan.url], configuration:)` → an error is `launchFailed`.

The runner accepts only a `LaunchActionArgumentPlan`, which only `LaunchActionArgumentPlan.make`
can build, so a refused or missing plan can't reach it.

| Browser | Installed | Running | Start fails | Result | System asked to start |
| --- | --- | --- | --- | --- | --- |
| in plan | yes | no | no | `.launched` | yes, with plan arguments, empty environment |
| in plan | yes | yes (any case of the ID) | — | `.refused(.browserAlreadyRunning)` | no |
| in plan | no | — | — | `.refused(.browserNotInstalled)` | no |
| location not an app bundle, or bundle reports another ID | — | — | — | `.refused(.browserNotInstalled)` | no |
| in plan | yes | no | yes | `.refused(.launchFailed)` | yes (once) |

## Launcher integration (D5)

Any item whose `launchActionSetting` is not `nil` — enabled or needing review, of any kind — goes
**only** through `GroupLauncher.openWithLaunchAction`; it never reaches the plain website, file,
folder or app paths. In `openRightAway` such items open after the others, one at a time.

1. The source must be user-present (`LaunchSource.isUserPresent`) → else `unattendedSource`.
2. The workspace must conform to `LaunchActionWorkspace` → else `noRunner` (a test fake or any
   other workspace can never start a browser with arguments by accident).
3. The browser is the item's Open With app if it has one, otherwise the action family's preferred
   bundle ID; `LaunchActionArgumentPlan.make(for:…)` with the runner workspace's installation
   lookup → a refusal is `plan(reason)`: `actionDisabled` (imported), `actionNeedsReview`
   (invalid, or a bad name in an enabled case), `itemKindMismatch` (app/file/folder),
   `urlRejected`, `unsupportedBrowser` (an Open With app outside the family, Safari),
   `browserNotInstalled`.
4. `LaunchActionRunner.run` → a refusal is `run(reason)`.

Report: a refusal for a missing browser is `.notFound` (the existing "not found" text); every other
refusal is `.failed(reason:)` with the existing `core.launch.notOpened` text ("The app wasn't
opened."). **No new user-visible text and no localization key**; the precise reason is the internal
`launchActionRefusal`. Items **without** a launch action are untouched: same code paths, same
order, same report, from every source (regression tests below).

Logging: one line per item with an action, `Not opened, launch action <code>: a <kind> item` or
`Opened a <kind> item with its launch action`. The code is fixed (`source.link`,
`plan.actionDisabled`, `run.browserAlreadyRunning`, …). The profile name, the arguments, the
address and even the host are not logged; the generic problem log skips these items.

## Unattended paths (D6)

`LaunchSource` is the one place that decides; only `.userAction` is user-present.

| Path | Source | Item with a launch action |
| --- | --- | --- |
| Popup click, Most Used, Open All from the popup / group window / sidebar / menu bar, Start from the app's UI | `userAction` | opened through the runner |
| Group keyboard shortcut (Open All, Start) | `keyboardShortcut` | **not opened** (can be pressed by accident and doesn't show what it does) |
| `cybokrondockgroups://launch/…` and `start/…` links, and the command-line tool (it only opens links) | `link` | not opened |
| Siri / Shortcuts (Open Group, Start Group) | `intent` | not opened |
| Focus filter | `focus` | not opened |
| Triggers (Open All, Start) | `trigger` | not opened |
| Standalone group app (popup, Dock menu) | `standaloneAgent` | not opened (agents also drop actions on write and read, D11) |
| Any caller that doesn't say | `unspecified` | not opened |

"Not opened" means the item isn't opened at all — not plainly, not in the default browser — and is
reported with the fixed reason; the group's other items open as before. Start maps
`TransitionTrigger` to a source (`LaunchSource.init(_:)`), so the same rule covers Start from every
path. A delayed item keeps the source of the Open All that scheduled it, and is skipped at fire time
when its action changed while it waited (T8 partial).

## Threat model mapping

| Threat | What this slice does |
| --- | --- |
| T4 environment | `configuration.environment = [:]`; no other file sets an environment on an `OpenConfiguration` (scan test). |
| T5 shell | No shell, no `Process`; the argv array goes to LaunchServices unchanged. |
| T6 wrong profile | A running browser is refused, so arguments are never silently dropped. Not achievable: proving the profile exists (see residual risk). |
| T7 log privacy | Fixed codes only; no name, argument, address or host. |
| T8 TOCTOU | Delayed items re-checked: identity, kind, launch options **and** launch action unchanged. The running check is the last step before starting. |
| T9 parent process | LaunchServices starts the browser (`NSWorkspace`), not a child; verified parent PID 1 (`launchd`) on this Mac. |
| T10 unattended | `LaunchSource`; only the user's click runs an action (D6). |
| §6 rule 1 / D5 | Any doubt → item not opened at all. |
| §6 rule 5 | Plan: browser in the family's set; runner: the bundle at the location has that ID. |
| §6 rule 9 | Missing browser → not found, no fallback. |
| §6 rule 12 | No entitlement, TCC string, Automation or Accessibility request; no browser files are read. |

## Tests

`Tests/DockGroupsCoreTests/LaunchActionRunnerTests.swift` (fake workspaces only; nothing real is
started):

- Runner: a browser that isn't running is started with the exact arguments (Chrome one element,
  Firefox `-P` + name), the item URL, an empty environment, `activates`, no new instance; a running
  browser (three cases of the ID) is refused and nothing is opened; not installed, not an app
  bundle, another bundle ID, a non-file location → `browserNotInstalled`; a start error →
  `launchFailed`; the configuration's fields; fixed refusal codes.
- Launcher: click and Open All from the app start the browser only through the runner (never the
  default browser or Open With); a running browser → not opened at all; missing browser → not
  found, no fallback; start failure; imported, invalid, forged-enabled (`--remote-debugging-port`),
  injected name, app and folder items with an action, Open With Firefox or Safari for a Chrome
  action → not opened, each with its reason; every unattended source (7) → not opened while the
  group's other items open; only `.userAction` is user-present and the `TransitionTrigger` mapping;
  a workspace that can't run actions opens nothing; the report and code contain no profile name,
  host or path; **items without an action produce the same report and the same workspace calls from
  all 8 sources as before**.
- Start and delays: `ContextSwitcher.start` for each of the 6 triggers — only `.userAction` starts the
  browser; a delayed item keeps its source (user → started, link → refused); a delayed item whose
  action changed while waiting isn't opened.
- Source scans (`LaunchActionExecutionScanTests`, `LaunchActionArgumentPlanTests`): only the
  allowed files mention launch actions (the launcher and delayed launches now among them; still no
  app or CLI-executable file); outside the runner no line with a launch action mentions a workspace
  or process call; **no file but the runner sets `arguments`, `environment` or
  `createsNewApplicationInstance` on an `OpenConfiguration`**; the runner's only environment line is
  `configuration.environment = [:]`, it has exactly one `workspace.open(` call and no `Process`,
  shell, AppleScript, `openApplication`, `FileManager` or Application Support path; only the plan
  files, the runner and `GroupLauncher` use `LaunchActionArgumentPlan`.
- `TriggerAppSourceTests` now expects the trigger bridge's `openAll(group, source: .trigger)`.

## Real-machine check

macOS 26 on the development Mac, 2026-11-11. The user's Chrome profile store and Firefox profiles
are not readable (TCC, "Operation not permitted"), so no profile was verified by reading files.

| Case | Command | Observed |
| --- | --- | --- |
| Chrome not running (an isolated `--user-data-dir` under the temp folder, because the user's Chrome was running and must not be quit) | `open -n -a "Google Chrome" --args --user-data-dir=<tmp> --profile-directory=Default https://example.com` | new process, parent PID 1, argv contains `--profile-directory=Default`; `Default` created in the data dir. Quit with `pkill -f -- "--user-data-dir=<tmp>"`, the user's Chrome untouched. |
| Chrome, unknown directory name (same isolated dir) | `--profile-directory="Nonexistent Name"` | Chrome **creates** a profile directory `Nonexistent Name`. |
| Chrome running | `open -a "Google Chrome" --args --profile-directory=Default <url>` and the runner's `NSWorkspace.open(…configuration:)` with `arguments` | no new process; NSWorkspace returned the running PID; the arguments were dropped (the URL was handed to the running browser). |
| Firefox not running | runner's `NSWorkspace.open(…)` with `["-P", "default-release"]`, `environment = [:]` | new process, parent PID 1, argv `firefox -P default-release`; the open files show the `….default-release` profile in use. (The URL is delivered by LaunchServices as an event, not in argv.) |
| Firefox running | same call with `["-P", "other-profile"]`, then `open -a Firefox --args -P another <url>` | same PID returned, no new process, argv unchanged: arguments ignored. Quit with `pkill -f -- "firefox -P default-release"` (Firefox wasn't running before). |

So for both browsers the "running" case really drops the arguments, which is what the refusal
protects against.

## Residual risk

- **Profile names can't be checked.** The app can't (and mustn't, D3 / TCC) read `Local State` or
  `profiles.ini`. A mistyped Chromium directory name makes Chrome create a new empty profile
  (verified); a mistyped Firefox name shows Firefox's own error or Profile Manager (unverified).
  The future editor should tell the user where to read the real name (`chrome://version` "Profile
  Path", `about:profiles`).
- **Race:** the browser can start between the running check and the start (e.g. at login). Then
  LaunchServices hands the URL to it without the arguments — the T6 case — in a window of a few
  milliseconds. Not achievable to exclude without a second instance.
- **Firefox while running:** the check above only shows that the arguments were dropped (same PID,
  no new process); which window or profile then shows the URL was not inspected. It doesn't matter
  for the app (it refuses before sending anything) but matters for anyone reproducing the spike.
- Edge and Brave were not installed on this Mac: their behaviour is assumed to match Chrome's.
- Firefox `-P` with an unknown name and Chrome's `--ignore-profile-directory-if-not-exists` were not
  explored further; the template is unchanged.
- A same-user writer of `groups.json` can still choose a profile name and when to open it (by
  asking the user to click). That is the accepted model of option A.

## Next

Slice 4 is done: [launch-action-ui-slice.md](launch-action-ui-slice.md) (editor, caption, review,
confirmation, localization; the restore summary line is still to do). Then slice 5 (agents;
downgrade round trip).
