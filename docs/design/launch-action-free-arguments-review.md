# Review: free launch arguments (E phase 2, option B)

- **Status:** independent security and feasibility review. Design only; no code changes. No
  release decision.
- **Baseline:** `main` at `1f9365d`. File references are relative to `Sources/` unless they start
  with `docs/`, `Tests/` or a root file.
- **Reviews:** option B of the [launch actions threat model](launch-actions-threat-model.md) §5
  ("free arguments for app launch, no shell") against T1, T2, T5, T9, §6 and D1–D11, and the shipped
  option A slices: [core](launch-action-core-slice.md), [argv](launch-action-argv-slice.md),
  [runner](launch-action-runner-slice.md), [approvals](launch-action-approvals.md),
  [UI](launch-action-ui-slice.md).
- **Marking:** **(verified)** = read in vendor source or documentation, or observed on this Mac,
  with the source named. **(unverified)** = plausible, not checked for this document. Nothing in
  this review launched a third-party app with an attack flag.

Evidence gathered for this review (2026-11-13, macOS 27.2):

| Source | What was checked |
| --- | --- |
| Chromium `main` (`chromium.googlesource.com`) | `base/command_line.cc`, `content/public/common/content_switches.cc`, `extensions/common/switches.cc`, `chrome/browser/extensions/extension_service.cc`, `chrome/browser/devtools/remote_debugging_server.cc` |
| Chrome blog, "Changes to remote debugging switches to improve security" (2025-03-17) | `--remote-debugging-port/-pipe` vs the default data directory from Chrome 136 |
| Electron docs (`docs/api/command-line-switches.md`, "Electron Fuses") and `build/fuses/fuses.json5` | documented switches; the `nodeCliInspect` fuse and its default |
| Fuse wires of installed apps, read from the binary (sentinel `dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX`, no app started) | VS Code 1.142.0, Cursor, Claude, Notion, Figma, 1Password |
| VS Code 1.142.0 `Resources/app/out/mainImpl.js` | option names the main process parses |
| Apple docs: `NSWorkspace.OpenConfiguration.arguments`, `.environment`, `.createsNewApplicationInstance`, `UserDefaults.argumentDomain` | what LaunchServices passes; what the argument domain is |
| A 6-line Swift program run in a temp folder (not in the repository) | how Foundation parses `-Key value` into the argument domain |

## 1. Question

Can option B — a user-defined argv for an app (or opener) item, passed as
`NSWorkspace.OpenConfiguration.arguments`, one argv element per entry, no shell, no `Process`,
`environment = [:]` — be offered safely enough? If yes, with which subset?

Short answer: **free argv, no.** The only subset that keeps the project's rule ("a write to a data
file must not become code execution", `SECURITY.md` "Scope", `06_GUVENLIK.md` threat model) is a
closed list of `(app, flag, value grammar)` entries — and that is option A with more templates, not
B. Details in §6.

Two clarifications of the premise:

- **"Empty environment" is not an empty environment.** Apple documents `environment` as "the set
  of environment variables to *set* in a new app instance" with an empty default
  **(verified, Apple docs)**. `environment = [:]` (`LaunchActionRunner.swift:75`) adds nothing; the
  app still gets the environment LaunchServices/launchd gives every app **(contents unverified)**.
  It closes env *injection* (T4), not env *dependence*.
- **Arguments reach only a new instance.** Apple: "When launching a new instance of an app, use this
  property…"; `createsNewApplicationInstance = false` "opens the already running app when present"
  **(verified, Apple docs)**. Observed for Chrome and Firefox: arguments to a running app are dropped
  ([runner slice](launch-action-runner-slice.md#real-machine-check)). Any B would inherit the
  runner's "already running → not opened" rule, or silently not apply.

## 2. Threat analysis

Attacker model as in the threat model §3. The vectors that matter for B are **S2/S3** (a backup or
template from someone else), **S10** ("paste this into Arguments" — a blog recipe, a support chat,
an AI answer) and **S1** (another program writes `groups.json`). A same-user writer of both
`groups.json` and the approval file (S1 at full strength) could already install a LaunchAgent; B
gives it nothing new. B's real cost is that **one click by the user** — on an action they approved
once, perhaps without understanding it — becomes "run code inside / take over a trusted app".

Each row: app, argument, what the attacker gets, evidence.

| # | App | Argument(s) | What it gains | Evidence |
| --- | --- | --- | --- | --- |
| E1 | Electron apps **with the `nodeCliInspect` fuse on**: on this Mac VS Code 1.142.0 and Cursor | `--inspect=9229` or `--inspect-brk=9229` | The Node.js inspector of the **main process** on `127.0.0.1:9229`. Any local process (including one with no file access at all, e.g. a sandboxed or low-privilege helper) can attach over the Chrome DevTools Protocol and evaluate JavaScript with Node APIs (`require('child_process')`) as that app, with that app's TCC grants (Full Disk Access, if a user gave it to their editor). | Electron docs: `--inspect[=[host:]port]` "Activate inspector on host:port. Default is 127.0.0.1:9229"; fuse `nodeCliInspect` "toggles whether the --inspect, --inspect-brk, etc. flags are respected", **default enabled** (`fuses.json5`: `"node_cli_inspect": "1"`) **(verified)**. Fuse wire read from the binaries: VS Code and Cursor `node_cli_inspect = 1`; Claude, Notion, Figma, 1Password `= 0` **(verified, read-only)**. Main-process code execution through the inspector is how the inspector is meant to work; the app-specific TCC inheritance is **(unverified)**. |
| E2 | Electron apps, **regardless of that fuse** (Claude, Notion, Figma, Slack, Discord…) | `--remote-debugging-port=<port>` | DevTools protocol for the app's **renderers**: run script in the logged-in web content, read its cookies/storage and tokens. Without Node in the renderer (context isolation) it is not OS code execution, but it is account takeover of that app's session. | Electron docs list `--remote-debugging-port=port` "Enables remote debugging over HTTP" **(verified)**; there is no fuse for it in `fuses.json5` **(verified)**. Whether a given app strips or ignores it at runtime **(unverified per app)**. |
| E3 | Chromium browsers and Electron apps | `--proxy-server=host:port` + `--ignore-certificate-errors` (+ `--host-resolver-rules=MAP * 1.2.3.4`) | Every request of that app goes to the attacker, TLS errors ignored: full man-in-the-middle of a logged-in session. **No code is loaded at all** — this is why "no code-loading flag" is the wrong test. | Electron documents all three switches **(verified, `command-line-switches.md` §§ `--proxy-server`, `--ignore-certificate-errors`, `--host-resolver-rules`)**; Chromium has `kHostResolverRules` in `services/network/public/cpp/network_switches.cc` **(verified)**. Whether Google Chrome honours `--ignore-certificate-errors` today (it shows an "unsupported flag" bar, historically) **(unverified)**. |
| E4 | VS Code (and forks) | `--extensionDevelopmentPath=<dir>`, `--disable-workspace-trust`, `--extensions-dir=<dir>`, `--install-extension <id>` | Loads an extension (Node code) from a folder; turns off the Workspace Trust prompt that guards tasks/debug configs of an opened folder; points the editor at another extension store; installs a marketplace extension. With a folder planted in `~/Downloads` or a cloned repo, one click runs the attacker's code. | All four option names are in VS Code 1.142.0's `mainImpl.js` (`"disable-workspace-trust":{type:"boolean"}`) **(verified: parsed by the main process)**. That they take effect when passed by LaunchServices rather than the `code` CLI, and whether `--install-extension` prompts **(unverified)**. |
| E5 | Chromium-based browsers **other than Google Chrome** (Edge, Brave, Vivaldi, Arc, Chromium) | `--load-extension=<dir>` | A full extension with host permissions on every site: reads and changes all pages, cookies via the extensions API. | Upstream `ExtensionService::LoadExtensionsFromCommandLineFlag`: under `GOOGLE_CHROME_BRANDING` it logs "--load-extension is not allowed in Google Chrome, ignoring." and returns; otherwise it is honoured unless Enhanced Safe Browsing is on **(verified, Chromium `main`)**. So it is **blocked in Google Chrome, open by default in non-Google builds**; what Edge/Brave ship **(unverified)**. The threat model T2 lists `--load-extension` without this nuance. |
| E6 | Chromium browsers | `--remote-debugging-port=<port>` (with or without `--user-data-dir=<dir>`) | DevTools over HTTP for the whole browser: any local process reads every cookie and drives every tab (the infostealer technique Chrome's blog describes). | Chrome blog (2025-03-17) and `remote_debugging_server.cc`: from Chrome 136 the switch is refused for the **default** data directory — but the check is `constexpr true` only under `GOOGLE_CHROME_BRANDING`; for other brandings it is a testing-only global, i.e. **off** **(verified, Chromium `main`)**. Edge/Brave may add their own check **(unverified)**. In Google Chrome, combined with `--user-data-dir=<other dir>` it still opens a debuggable browser (on a fresh/other profile) **(verified, blog)**. |
| E7 | Chromium browsers | `--user-data-dir=<dir>`, optionally `--disable-web-security`, `--allow-file-access-from-files`, and a positional `file:///…/page.html` | Runs the browser on an attacker-chosen profile (planted preferences, extensions, homepage). `--disable-web-security` "has no effect unless --user-data-dir … is also present" — which a free argv can supply — and removes the same-origin policy. `--allow-file-access-from-files` lets a local `file://` page read other `file://` URLs; with a page in `~/Downloads` that page can read local files and send them out. | `content_switches.cc` comments for `kDisableWebSecurity` and `kAllowFileAccessFromFiles` **(verified)**. Exfiltration end-to-end and positional-URL handling when launched through LaunchServices **(unverified)**; the runner slice observed that the URL is delivered as an event, not argv, for Firefox. |
| E8 | **Every Cocoa app** (any `NSUserDefaults` reader) | `-SomeKey value` pairs, e.g. `-NSDocumentRevisionsDebugMode YES`, `-ApplePersistenceIgnoreState YES`, `-AppleLanguages (de)` | Overrides **any** user default of that app for that run: argument domain values "override most other domains, including your app-specific settings". Values are parsed as property lists, so arrays/dictionaries are possible. Impact is app-specific: harmless for the three named keys, but any app that keeps an endpoint, feature switch, "skip confirmation", log path or update setting in defaults can be retargeted. | Apple docs `UserDefaults.argumentDomain` **(verified)**. Observed with a test binary: `-Foo hello -Bar '(a, b)' -NSDocumentRevisionsDebugMode YES -ApplePersistenceIgnoreState YES` ⇒ all four in the argument domain, `Bar` as an array **(verified)**. Note: Apple's page shows the syntax `-default key=value`; on this Mac that sets a key literally named `default` — the working form is `-Key value` **(verified, doc is inaccurate)**. What `NSDocumentRevisionsDebugMode` / `ApplePersistenceIgnoreState` *do* in a given app **(unverified)**; examples of security-relevant app keys (e.g. `WebKitDeveloperExtras` enabling a Web Inspector in apps embedding WebKit) **(unverified)**. |
| E9 | Any app taking paths (VS Code, Xcode, editors, Chromium `--user-data-dir`, Firefox `-profile`) | `../`, symlinks, `~/…`, relative paths | No shell means *we* never expand `~` or globs, but the **target app** resolves the path itself: relative paths are resolved against the launched app's working directory (for LaunchServices launches typically `/` **(unverified)**), `~` may be expanded by the app **(unverified per app)**, and a symlink is followed when the app opens it, after any check we could make (threat model T3 — "not achievable" to exclude). `FileLocation`/`FileItemPolicy` checks only apply to fields *we* know are paths; a free argv element is opaque. | Threat model T3; `FileLocation.swift`; Mozilla wiki "Firefox/CommandLineOptions" `-profile <path>` (cited in the argv slice) **(verified)**. |
| E10 | Generic parsing tricks | single-dash aliases, last-wins, `--` terminator, `@file` | Chromium treats **both** `--` and `-` as switch prefixes on POSIX (`kSwitchPrefixes = {"--", "-"}`), so a denylist of `--load-extension` misses `-load-extension`; a later duplicate overrides an earlier one (`InsertOrAssign(switches_, …)`), so a fixed safe element can be overridden by a user element after it; `--` ends switch parsing, turning later elements into positional URLs/files **(all verified, `base/command_line.cc`)**. Response files (`@args.txt`, e.g. the JDK `java` launcher) pull arguments from a file the app reads at launch **(class exists; whether any common `.app` bundle honours `@file` via LaunchServices: unverified)**. Tools that expect an environment variable (`$HOME`, a token) receive the literal string, since nothing expands it — confusing, not dangerous. |

**Strongest three** (all need only one click on an approved action; none needs a shell):

1. **E1 — `--inspect` on VS Code/Cursor:** main-process Node code execution for any local process,
   inheriting the editor's permissions. Fuse state verified on this Mac.
2. **E3 — proxy + ignore certificate errors:** full MITM of a logged-in Chromium/Electron app with
   no code-loading flag at all, which defeats any "code flags" denylist.
3. **E4/E5 — load code from a planted folder:** VS Code `--extensionDevelopmentPath` +
   `--disable-workspace-trust`, or `--load-extension` in non-Google Chromium browsers.

## 3. Why option A is different

- **A is a closed set.** Stored data is a template ID plus typed parameters
  (`LaunchAction.browserProfile(browser:profileName:)`, `Model/LaunchAction.swift:23-25`); keys are
  exactly `template`, `browser`, `profile`, and `args`, `argv`, `arguments`, `environment`, … are
  refused by name ([core slice](launch-action-core-slice.md#on-disk-form)). The planner builds the
  argv itself (`["--profile-directory=<name>"]` or `["-P", "<name>"]`), re-checks the grammar and
  `isSingleArgumentValue` (no leading `-`, no `=`, no control/format characters), and the target
  must be in a fixed bundle-ID set ([argv slice](launch-action-argv-slice.md#checks-in-order-first-failure-wins)).
  Data can select only shipped behaviour.
- **B is the target app's entire flag surface**, which is (a) unbounded — Chromium alone has
  hundreds of switches spread over `content`, `chrome`, `extensions`, `network` — (b) different per
  app and per version, (c) partly not even flags (E8: every Cocoa app reads `-Key value`), and (d)
  outside this project's control: Google can close `--load-extension` (E5) while Brave keeps it open.
- **"No shell" closes one class.** It removes metacharacter interpretation (T5) and `Process`
  parentage (T9). It does nothing against T2: in E1–E8 every dangerous element is a single, clean
  argv element with no metacharacter. A **denylist** cannot be complete: E10 shows aliasing and
  last-wins in the most common parser, E3 shows harm with no code flag, E8 shows harm with no flag
  syntax at all.

The threat model already says this (T2 "B: not achievable in general"; §5 table "No code execution
from data: B no"). This review confirms it with sources and finds no mitigation that changes it.

## 4. Does the approval record (D9) rescue B?

**No.**

- **Approval answers "did the user mean this exact argv", not "is this argv safe".** The digest
  (`LaunchActionApprovalDigest`, [approvals](launch-action-approvals.md#digest)) would bind to the
  argv, so tampering after approval is caught. But E1–E8 are dangerous *as approved*: a user who
  pastes `--inspect=9229` from a "speed up VS Code" post approves it, and it stays dangerous on every
  later click. The approval sheet's text ("arguments can make an app run code", threat model §7)
  is a warning, not a control.
- **A same-user writer forges it.** The approvals doc states it: anyone who can write
  `groups.json` "can also write `launch-action-approvals.json`, computing the digest from this
  document" ([accepted risk](launch-action-approvals.md#accepted-risk)); Keychain HMAC was rejected
  (`06_GUVENLIK.md` "Yapılmaması gerekenler"). For A that is acceptable because the forged thing is
  still a browser profile name. For B the forged thing is `--inspect`.
- **What D9 still does well** — stops actions arriving by copy (backup, sync, another Mac) — is
  necessary for B but covers only S2/S3/S8, not S10, the realistic B vector.

D9 plus D4 (imported → disabled), D6 (user-present sources only) and the running-app refusal would
all be required for any B, and together they still leave the user as the only check.

## 5. Options

| | (i) No B | (ii) Allowlisted flags | (iii) Free "Arguments" field, full preview, confirm **every** launch |
| --- | --- | --- | --- |
| What it is | Keep A; no `arguments` field ever. | New A templates: each `(bundle-ID set, fixed flag, typed value grammar)` shipped in the app; the planner builds the argv, user values never start with `-`, never contain `=` except where the skeleton puts it. | `arguments: [String]` on an app item; at each launch a sheet shows app + bundle ID + every element (invisible characters shown), confirm after a delay; no "don't ask again". |
| Guarantee vs. the project rule | Holds. | Holds **per entry**, if each entry is reviewed: data still selects only shipped behaviour. | **Does not hold** (T2). Only "the user saw it this time". |
| Same-user writer | — | Gets only shipped flags. | Gets any flag; the per-launch sheet is the only barrier (social engineering at click time). |
| S10 paste recipes | No field to paste into. | Nothing free-form to paste. | Primary attack path (E1–E8). |
| Complexity | none | S–M per entry: grammar, bundle-ID set, spike per app/version, tests. Reuses the whole A pipeline (decoder, planner, runner, digest, review). | M–L: new free-form model and digest field, per-launch sheet in app **and** agents, breaks Open All (one sheet per item), localization, security review; permanent maintenance of "what does this argv do" support questions. |
| UX | F1 flags not covered; Open With and folder-in-Terminal remain. | Small, predictable; each entry is a named setting ("Open in a private window"), not a flag. | Powerful but a modal per launch makes Open All/Start unusable; users will learn to click through — the warning loses value exactly where it matters. |
| Running-app case | n/a | Same rule as today: refused (runner). | Same; adds "your arguments weren't used" confusion for every app, not just browsers. |

Note on (ii): with the runner's running-app refusal, flags whose only effect is window choice
(`--new-window`) add almost nothing, because a freshly started browser opens a new window anyway.
The useful entries are the ones that select *state* (profile, private mode).

## 6. Recommendation

**Do not build free argv (B as described in the threat model §5). Treat (ii) as "more A
templates", decided one entry at a time; do not build (iii).**

Reasons: B fails the stated security boundary by construction (§3), D9 cannot repair that (§4),
and (iii)'s only extra control — a per-launch prompt — trades away the product's core action (open
the whole group with one click) for a barrier that habituates.

**Never** (in any option, any template, any value):

- `--inspect*`, `--remote-debugging-port`, `--remote-debugging-pipe`, `--js-flags`, `--load-extension`,
  `--disable-extensions-except`, `--user-data-dir`, `--extensions-dir`, `--extensionDevelopmentPath`,
  `--disable-workspace-trust`, `--install-extension`, `--disable-web-security`,
  `--allow-file-access-from-files`, `--ignore-certificate-errors`, `--proxy-server`,
  `--proxy-pac-url`, `--host-resolver-rules`, `--host-rules`, `--no-sandbox`, `--enable-logging`,
  `--log-file`, `--log-net-log`, Firefox `-profile <path>`, `-new-instance`/`-no-remote`,
  `-jsconsole`/`-devtools`. Listed to make reviews concrete — the protection is the allowlist, not
  this list (E10).
- Any user-supplied element that is a flag, starts with `-`, or contains `=`; any `-Key value` pair
  (E8); any `--` terminator; any `@…` element; any positional element.
- Any argv for an app that is already running (keep the runner's refusal; no
  `createsNewApplicationInstance`).
- Any `environment`, shell, `Process`, AppleScript, `.command` file (T4, T5, T9 — unchanged).
- Any argv action from an unattended source (D6) or enabled from an import (D4).

### Draft allowlist for (ii)

Each row would be its own template and its own spike; none is approved by this review.

| Template (working name) | Apps (bundle-ID set) | argv built by the app | User value | Value | Risk | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| `browserProfile` (**shipped**) | Chrome, Edge, Brave / Firefox | `--profile-directory=<v>` / `-P`, `<v>` | profile name, existing grammar | high (F2) | low | As today. |
| `browserProfile` + `--ignore-profile-directory-if-not-exists` | Chrome, Edge, Brave | adds this fixed element **before** the profile element | none | medium (stops a typo creating a profile, verified in the runner slice) | low | Switch exists in `chrome_switches.h` per the argv slice; behaviour on Edge/Brave **(unverified)**. Order matters only for duplicates (E10); neither element is user-controlled. |
| `browserPrivate` | Chrome, Brave: `--incognito`; Edge: `--inprivate`; Firefox: `-private-window` | one fixed element, URL separate as today | none | medium | low | Switch names per vendor **(unverified for this document)**; must not combine with a profile in the same action unless a spike shows the result. |
| `appLanguage` (optional, low value) | any app (it's Foundation) | `-AppleLanguages`, `(<tag>)` | BCP 47 tag, grammar `^[a-z]{2,3}(-[A-Z][a-z]{3})?(-[A-Z]{2})?$` | low (System Settings already has per-app language) | low | The only safe `-Key value` use: key fixed, value from a closed grammar. Recommend **not** shipping unless asked. |

Explicitly **not** on the list despite user demand: VS Code `--new-window`/`--reuse-window`/folder
arguments (Open With already opens a folder; VS Code's own single-instance handling with
LaunchServices **(unverified)**), Xcode workspace arguments (Open With covers it), any Electron
app flag.

### Documents to update

This review does not change behaviour, so nothing is due now. If accepted:

- **`launch-actions-threat-model.md`** (the one to update): D1 "B later behind its own review" →
  "B reviewed and not planned; new A templates only" with a link here; §10 slice 6 → "not
  scheduled"; T2 — add that `--load-extension` and the remote-debugging data-dir check are enforced
  only in Google Chrome branded builds (E5, E6), and add E3 (MITM with no code flag) and E8 (verified
  `-Key value`); §5(C) cites `06_GUVENLIK.md` as "Accessibility/Automation hiç istenmez", but
  `06_GUVENLIK.md` was corrected on 2026-11-12: Accessibility is optional, Automation is never
  requested — reword to "Automation hiç istenmez" (T9 already cites Automation only).
- `SECURITY.md` "Scope": unchanged (it already describes templates only and says B would need a
  sentence only if it ships).
- `06_GUVENLIK.md` (outside this repository): optionally add "serbest argüman yok; yalnız şablon".

## 7. Test plan

### If (ii) — per new template

Automated (SwiftPM, fakes only, same patterns as `LaunchActionTests`, `LaunchActionArgumentPlanTests`,
`LaunchActionRunnerTests`, `LaunchActionApprovalTests`):

1. **Decoder:** the template's exact keys round-trip; unknown key, wrong type, missing key, unknown
   template → `needsReview(.invalid)`; `args`/`argv`/`arguments`/`environment`/… still refused by
   name in every template (regression for the forbidden-key list).
2. **Grammar table** (`@Test(arguments:)`): every row of §2 as a value — `--inspect=9229`,
   `-inspect`, `--remote-debugging-port=1`, `-load-extension=/tmp/x`, `--proxy-server=…`,
   `-NSFoo YES`, `--`, `@args`, `=`, leading/trailing space, NUL/CR/LF/tab, bidi, zero-width, NBSP,
   U+2028, paths (`/`, `~`, `../`, `file:`), over-length → refused, never trimmed.
3. **Exact argv:** the plan equals a literal array per bundle ID; user value appears in exactly one
   element; no element other than the template's fixed ones starts with `-`; fixed elements come
   from a constant table (source scan, as the argv slice's shape tests).
4. **Bundle-ID set:** an action for app X never plans for app Y (case variants, beta channels,
   Safari, a path).
5. **Digest:** the new fields are in the canonical text; changing any one changes the digest;
   approved runs, mismatch/missing doesn't.
6. **Sources:** all 7 unattended sources + `unspecified` → not opened; `userAction` and
   `standaloneAgent` → runner; items without actions unchanged from all 8 sources.
7. **Running app:** refused, nothing passed, other items open.
8. **Import/template/agent:** restore, merge, template from backup → `review/imported`; agent
   configuration without approval → not opened.
9. **Source scans:** still only `LaunchActionRunner.swift` sets `arguments`/`environment`; no
   `Process`/shell/AppleScript; no file contains a free-form argument field.
10. **Log privacy:** reports/logs contain fixed codes only.

Manual (per template, per app, per release channel): not running vs. running; value that doesn't
exist; parent PID is `launchd`; no new TCC/Automation prompt; downgrade round trip (old version
drops the key, opens plainly — documented T12 case).

### If (iii) were chosen anyway — manual gates before any release

1. Written security sign-off that accepts T2 explicitly, and `SECURITY.md` "Scope" updated to say
   arguments can make an app run code.
2. Red-team pass with E1–E8 against the shipped build: confirm the sheet shows every element,
   including invisible characters and look-alikes, and that nothing launches without a fresh
   confirmation (including delayed items and Open All of many items).
3. Confirm button delay (0.7 s, `Commands/GroupQuitRequests.swift:30`) and focus: Return/Space can't
   confirm before it; a click-through test with a sheet raised during typing.
4. Agents: the same per-launch sheet in every standalone group app, or B skipped there.
5. Usability check of Open All with several B items (one sheet each) — if it is not acceptable, (iii)
   fails on its own terms.
6. Downgrade: an older version must not run the argv (it would ignore the key — verify on real
   binaries).

## 8. Residual risks and what stays open

- **Even (ii) depends on vendor behaviour.** A shipped, harmless switch can change meaning in a
  browser update; each entry needs a re-check per major version (as the argv slice's manual steps).
- **Edge/Brave/Vivaldi differ from Google Chrome** (E5, E6): upstream security gates are tied to
  Google branding. Any template that targets them inherits whatever their builds do **(unverified)**.
- **A same-user writer** still chooses *which* shipped template and value, and when the user is
  asked to click — the accepted model of option A ([runner slice](launch-action-runner-slice.md#residual-risk)).
- **Running-app race** (milliseconds between the running check and the start): unchanged from the
  runner slice; arguments are then dropped, not misused.
- **Not checked here:** what each Cocoa default in E8 does; whether VS Code honours E4 flags via
  LaunchServices; whether `--install-extension` prompts; Google Chrome's current handling of
  `--ignore-certificate-errors`; LaunchServices working directory and `~` handling by target apps;
  `@file` support in common `.app` bundles; Slack/Discord fuse states (not installed here).
- **Electron fuse state is per app and per version.** On this Mac 4 of 6 Electron apps disable
  `nodeCliInspect`; that is the apps' choice and can change with an update.

## Open questions

1. Is there a concrete user story for F1 that Open With, folder-in-Terminal and browser templates
   don't cover? If not, (ii) needs no new entries now.
2. Should `--ignore-profile-directory-if-not-exists` be added to the existing Chromium template
   (spike on Edge and Brave first)?
3. Is a private-window template wanted, and may it combine with a profile?
4. Should the threat model's D1/T2 updates (§6 "Documents to update") be made in the same PR as
   this review, or separately?
