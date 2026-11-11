# Slice: launch action argument plan and dry run (slice 3, computing part)

Status: internal Core code plus a hidden developer dry run. **Still nothing executes a launch
action**: the plan is computed and, in the dry run, printed. No launcher, workspace call, process,
AppleScript, UI, localization key, link, trigger or agent builds or uses a plan, and an item with a
launch action still opens exactly as it does without one. This is the first half of slice 3 of the
[launch actions threat model](launch-actions-threat-model.md#10-open-decisions-effort-and-slice-order);
the launcher half (passing the plan to `OpenConfiguration.arguments`, rules 1 and 5 of §6, delayed
re-check, report texts) is not started. Builds on the [core slice](launch-action-core-slice.md).

Slice 1 (the browser spikes) still hasn't run. Everything below about what a browser does with the
arguments comes from vendor documentation and is **unverified on a real Mac**; the
[manual steps](#manual-verification-with-real-browsers) are the gate before the launcher half.

## Scope

- `Sources/DockGroupsCore/LaunchActions/LaunchActionArgumentPlan.swift` (all `internal`):
  - `BrowserFamily.bundleIdentifiers` and `family(forBundleIdentifier:)` — the per-template
    bundle-ID set (T6, §6 rule 5).
  - `LaunchActionArgumentRefusal` — six fixed reasons, no text from the item or file.
  - `LaunchActionArgumentPlan` — `executableBundleIdentifier`, `arguments: [String]`, `url: URL`.
    Private initializer: only `make(...)` builds one. **No `environment` field** (and no shell,
    command or working directory); a test asserts the stored fields are exactly these three.
- `Sources/DockGroupsCore/LaunchActions/LaunchActionPlanProbe.swift` (`public`): the dry run.
- `Commands/DockGroupsCLI.swift`: one gate line that hands `--launch-plan` to the dry run only when
  `CYBOKRON_LAUNCH_PROBE` is exactly `1`.

Not in this slice: `ApplicationWorkspace`, `GroupLauncher`, `DelayedLaunches`, `ItemOpenerPolicy`,
the app, agents, `formatVersion` (unchanged), localization.

## The plan

```swift
LaunchActionArgumentPlan.make(
    setting: LaunchActionSetting,        // the item's stored setting
    itemKind: AppReference.Kind,
    url: URL,                            // the website item's address
    browserBundleIdentifier: String,     // the browser that would be started
    isInstalled: (String) -> Bool        // supplied by the caller; asked last
) -> Result<LaunchActionArgumentPlan, LaunchActionArgumentRefusal>

LaunchActionArgumentPlan.make(for: AppReference, browserBundleIdentifier:, isInstalled:)
    // nil when the item has no launch action at all (it opens as before)
```

The planner computes only. It never looks for the browser itself: `isInstalled` is the caller's
answer (the launcher half will pass its existing workspace lookup; the dry run passes "yes" and
says it didn't check). The URL is **not** an argument: it stays a separate field so the launcher
half can hand it to `open(_:withApplicationAt:configuration:)` as today, with the profile
arguments in the configuration.

### Checks, in order (first failure wins)

1. The setting is `.enabled` — imported → `actionDisabled`; invalid → `actionNeedsReview`
   (invalid because of the item kind → `itemKindMismatch`).
2. The action is allowed for the item kind (browser profile: websites only) → else `itemKindMismatch`.
3. **Checked again (defence in depth):** `action.rejection` and, independently,
   `BrowserProfileName.rejection(for:)` on the name; then the argument builder's own shape check
   (`isSingleArgumentValue`: non-empty, no leading `-`, no `=`, no control/format/line-separator
   character, no whitespace other than an inner U+0020). Any failure → `actionNeedsReview`. An
   `.enabled` case built in code with a bad name (bypassing the decoder) never gets a plan.
4. The address is a website item's address: http or https, a host, no user name or password, and
   `WebsiteAddress.parse` accepts it → else `urlRejected`. `mailto:`, `file:`, `javascript:`,
   `data:`, `ftp:`, `about:`, browser-internal schemes and scheme-less strings are refused.
5. The browser is in the action family's bundle-ID set (compared ignoring case, written
   canonically) → else `unsupportedBrowser`. A Firefox action never goes to a Chromium browser.
6. `isInstalled(canonicalID)` → else `browserNotInstalled`. Asked only when 1–5 passed. No
   fallback to another browser (§6 rule 9).

### Browser → argv mapping

| Family | Bundle identifier (release channel only) | `arguments` | Source |
| --- | --- | --- | --- |
| `chrome` | `com.google.Chrome` | `["--profile-directory=<name>"]` (one element) | Chromium `chrome/common/chrome_switches.h`: `kProfileDirectory = "profile-directory"`, "Selects directory of profile to associate with the first browser launched." |
| `edge` | `com.microsoft.edgemac` | `["--profile-directory=<name>"]` | Chromium-based; same switch (assumed, verify) |
| `brave` | `com.brave.Browser` | `["--profile-directory=<name>"]` | Chromium-based; same switch (assumed, verify) |
| `firefox` | `org.mozilla.firefox` | `["-P", "<name>"]` (two elements) | Mozilla wiki "Firefox/CommandLineOptions": `-P "profile_name"` — "launch application with the profile named profile_name"; name is case sensitive; `-P` without a name opens the Profile Manager |

Sources were read on 2026-11-11 (`chromium.googlesource.com/chromium/src/+/main/chrome/common/chrome_switches.h`,
`wiki.mozilla.org/Firefox/CommandLineOptions`). Beta/Dev/Canary/Nightly builds are not in the sets:
they keep separate profile stores, and adding one is a set entry, not new code.

Notes the spike must settle:

- Chromium's switch takes a **directory** name (`Default`, `Profile 1`, …), not the display name
  shown in the profile picker. The grammar accepts both shapes; D3's recommendation (a fixed
  `Default` / `Profile N` list) would narrow it.
- `chrome_switches.h` also has `--ignore-profile-directory-if-not-exists` ("does not create the
  profile if the profile directory doesn't exist"). Without it Chrome **creates** a profile for an
  unknown directory name. Not added here (the task fixes the template to one element); worth
  adding as a second fixed element if the spike confirms it on all three Chromium browsers.
- Firefox `-P` takes the profile **name** from `profiles.ini`, never a path (`-profile <path>` is
  never produced, T6). Firefox's remote mechanism may hand the URL to an already running instance
  and ignore `-P`; `-no-remote` / `-new-instance` would change that but start a second instance,
  so they are not used (D7).

### Refusal matrix

| Input | Refusal | `isInstalled` asked |
| --- | --- | --- |
| `.needsReview(.imported(_))` (backup, template from backup) | `actionDisabled` | no |
| `.needsReview(.invalid(.unsupportedItemKind))` | `itemKindMismatch` | no |
| `.needsReview(.invalid(any other reason))` | `actionNeedsReview` | no |
| `.enabled` on an app, file or folder item | `itemKindMismatch` | no |
| `.enabled` with a name the grammar or the argument builder refuses | `actionNeedsReview` | no |
| Address not http/https, no host, with credentials, or not accepted by `WebsiteAddress` | `urlRejected` | no |
| Website item without a readable address (`make(for:)`) | `urlRejected` | no |
| Browser outside the family's set (Safari, another family, a beta channel, a path, empty) | `unsupportedBrowser` | no |
| Browser in the set but `isInstalled` says no | `browserNotInstalled` | yes |
| Everything passes | plan | yes |
| Item without a launch action (`make(for:)`) | `nil` — not an action item | no |

## Dry run (developer only)

Hidden like the [layout probe](window-layout-probe.md): not in `--help`, the README or the app
(tests check this). Without `CYBOKRON_LAUNCH_PROBE` set to exactly `1` (`0`, `true`, empty, ` 1`
or a lowercase name don't count) `--launch-plan` is an unknown argument: exit 2 and the usual help.

```sh
CLI=".build/debug/CybokronDockGroupsCLI"   # or <app>/Contents/MacOS/cybokrondockgroups
CYBOKRON_LAUNCH_PROBE=1 "$CLI" --launch-plan chrome Work https://example.com
```

```json
{
  "arguments" : [
    "--profile-directory=Work"
  ],
  "browser" : "chrome",
  "dryRun" : true,
  "executableBundleIdentifier" : "com.google.Chrome",
  "formatVersion" : 1,
  "installationChecked" : false,
  "status" : "planned",
  "url" : "https://example.com"
}
```

stderr: `Dry run: planned; nothing was opened.` `<browser>` is a family name (`chrome`, `edge`,
`brave`, `firefox`, case-sensitive); the family's preferred bundle identifier is the target. The
name and address are read as a website item would hold them (no normalization; an address must
already have its scheme).

- Exit codes: `0` planned; `2` wrong argument count; `3` refused.
- A refused run prints only `status`, `refusal` and the family, **never the profile name or
  address it was given**:
  `{"browser":"chrome","dryRun":true,"formatVersion":1,"installationChecked":false,"refusal":"actionNeedsReview","status":"refused"}`.
- It doesn't resolve the containing app, dispatch a URL, look for the browser or start anything;
  `installationChecked` is always `false`, so `browserNotInstalled` can't come out of the dry run.

## Tests

`Tests/DockGroupsCoreTests/LaunchActionArgumentPlanTests.swift`:

- Valid plans for all four browsers (bundle ID, exact argv, URL, the lookup asked once with the
  canonical ID); inner spaces and non-ASCII names stay one value; bundle IDs compared ignoring case.
- Every refusal reachable; the lookup is not asked for any refusal before it; refusal raw values fixed.
- Defence in depth: 34 injected names (leading `-`, `--load-extension=`, `--remote-debugging-port=`,
  `--user-data-dir=`, newline/NUL/CR/tab/ESC, shell characters, quotes, `=`, `:`, `..`, paths,
  `file:`, surrounding spaces, bidi, zero-width, NBSP, U+2028, private use, 65 characters) in an
  `.enabled` case, for every browser → `actionNeedsReview`. The argument builder refuses bad values
  on its own, without the grammar.
- Address policy: http/https accepted unchanged and never put in argv; `mailto:`, `file:`,
  `javascript:`, `data:`, `ftp:`, `chrome:`, `about:`, credentials, no host, no scheme refused.
- Shape: Chromium exactly one element with one `=`; Firefox exactly `-P` + name; no element is a
  shell, `-c`, `open`, `--args`, `--user-data-dir`, `-profile` or `--load-extension`; the plan has
  no environment field.
- Source scan: the plan and dry-run files mention none of `NSWorkspace`, `Process`, `open(`,
  `LaunchServices`, `OpenConfiguration`, `openApplication`, `urlForApplication`,
  `NSRunningApplication`, `ApplicationWorkspace`, `GroupLauncher`, AppleScript, shells,
  `import AppKit`, `posix_spawn`, `execv`, `system(`, `NSTask`, `executableURL`, `FileManager`,
  `LSOpen`/`LSCopy`; only those two files use the plan type. `LaunchActionExecutionScanTests`
  (core slice) now also allows the two new files and the CLI gate line, and still forbids any
  launcher, app or CLI-executable file from mentioning launch actions.
- Dry run: inert for seven non-enabling environments; planned output and keys; Firefox's two
  elements; refusals print only the reason; bad argument counts print the usage; no app resolution,
  status check or URL dispatch in any case.

## Manual verification with real browsers

Run on a test Mac account with each browser installed and **at least two profiles** in it. Use the
dry run's `arguments` verbatim; this is the slice 1 spike in a reproducible form. Record, for each
row, macOS version, browser version, and the profile the page actually opened in.

1. **Find the real names.**
   - Chrome / Edge / Brave: open `chrome://version` (`edge://version`, `brave://version`) in each
     profile; "Profile Path" ends in the **directory** name (`Default`, `Profile 1`, …). Note the
     display name shown in the profile picker separately.
   - Firefox: `about:profiles` lists each profile's **name** and root directory.
2. **Browser not running** (quit it fully, `⌘Q`, check it's not in the Dock as running):
   - Chromium: `open -n -a "Google Chrome" --args --profile-directory="Profile 1" https://example.com`
     (likewise `"Microsoft Edge"`, `"Brave Browser"`). Expect the page in that profile.
   - Repeat with the **display name** instead of the directory name: does it open that profile, a
     new empty profile, or the default? (Decides D3 and whether the grammar narrows to
     `Default` / `Profile N`.)
   - Repeat with a name that doesn't exist: does a new profile directory appear under
     `~/Library/Application Support/Google/Chrome/` (resp. `Microsoft Edge`, `BraveSoftware/Brave-Browser`)?
     Then repeat adding `--ignore-profile-directory-if-not-exists` and record the difference.
   - Firefox: `open -n -a Firefox --args -P "work" https://example.com`; then with a non-existent
     name (expect an error or the Profile Manager — record which; nothing must be created).
3. **Browser already running** in profile A, ask for profile B with the same commands without `-n`
   (`open -a … --args …`) and then through `NSWorkspace.open(_:withApplicationAt:configuration:)`
   with `configuration.arguments` set (a scratch Swift script outside the repository — never in
   the app): are the arguments ignored (page opens in A, or in the last used window) or honoured?
   Firefox: does the URL go to the running instance in A?
4. **Name case and spaces**: `profile 1` vs `Profile 1` (Chromium directories, Firefox names are
   case sensitive per the Mozilla wiki), and a name with an inner space passed as one element.
5. **Parent process / prompts**: in Activity Monitor note the launched browser's parent; confirm
   no Automation, Accessibility or "access data from other apps" prompt appeared.
6. Write the results into the threat model §10 (slice 1) and, if a row contradicts this document,
   change the mapping or grammar **before** the launcher half starts.

## Residual risk

- All browser behaviour above is from documentation; Edge and Brave are assumed to keep Chromium's
  switch. Until step 3 runs, a page may open in the wrong profile when the browser is already
  running (T6), and Chrome may create a profile for a mistyped directory name.
- The grammar still accepts display-name-like values Chromium may not map to a directory (D3).
- `isInstalled` is the caller's: a wrong answer in the launcher half only changes which refusal is
  shown, it can't change the browser or the arguments.
- The dry run is gated only by an environment variable in a developer CLI, as the layout probe is;
  it computes and prints, so enabling it by accident has no effect beyond output.
