# Launch actions: the private-window template (`browserPrivate`)

Status: done. A new option A template from the allowlist of
[launch-action-free-arguments-review.md](launch-action-free-arguments-review.md#draft-allowlist-for-ii)
(§(ii)): a website item opens in a new **private window** of Chrome, Edge, Brave or Firefox. Same
pipeline as the browser profile (decoder, plan, runner, approval, review, editor); no free
argument, no new permission, entitlement, `formatVersion` or approval-file format.

## Template

```json
{ "status": "enabled", "template": "browserPrivate", "browser": "chrome" }
```

- `LaunchAction.browserPrivate(browser: BrowserFamily)`: the browser is its only parameter. No
  profile, no address of its own (the item's website address is used, as for a profile).
- Read as strictly as `browserProfile`: `browser` is required and must be `chrome`, `edge`, `brave`
  or `firefox`. A **`profile` key is refused** (`unknownKey`), whatever it holds: the template has
  none, and a private window combined with a profile isn't specified (review, §(ii)). Any other key,
  forbidden keys (`args`, `environment`, …), statuses and import review behave as for
  `browserProfile` ([core slice](launch-action-core-slice.md),
  [review persistence](launch-action-review-persistence.md)).
- Websites only. `browserProfile` is unchanged.

## argv

Built by the planner (`LaunchActionArgumentPlan.privateWindowArguments`) from a fixed table and the
item's checked address (`isAcceptable`: http/https, a host, no user name or password):

| Browser | Bundle ID | `arguments` | Status |
| --- | --- | --- | --- |
| Chrome | `com.google.Chrome` | `["--incognito", "<url>"]` | **verified** (this Mac, 2026-11-13) |
| Brave | `com.brave.Browser` | `["--incognito", "<url>"]` | **unverified** (not installed here; Chromium switch) |
| Edge | `com.microsoft.edgemac` | `["--inprivate", "<url>"]` | **unverified** (not installed here; Microsoft's documented switch) |
| Firefox | `org.mozilla.firefox` | `["-private-window", "<url>"]` | **verified** (this Mac, 2026-11-13) |

The address is **one argument after the option**, and nothing is handed over as an open event
(`LaunchActionArgumentPlan.urlsToOpen` is empty, so the runner calls
`open([], withApplicationAt:configuration:)`). The plan still keeps the address in its `url` field.
The address can't be read as an option: it starts with `http`, and `privateWindowArguments` refuses
one that starts with `-` or holds whitespace or a control character.

### Why the address is in argv (verified)

The review's draft said "URL separate as today". On this Mac (macOS 27.2, Firefox 159.0.1, Google
Chrome 157.0.8103.78) that **leaks**: started with only the option, both browsers open an empty private
window and the address, delivered by LaunchServices as an open event, in a **normal** window.

| Case | Call | Observed |
| --- | --- | --- |
| Firefox, not running, address as an event | `open([url], withApplicationAt:)`, `arguments = ["-private-window"]` | argv `firefox -private-window`, parent PID 1; windows "Example Domain" (normal) and "Mozilla Firefox — Private Browsing" (empty) |
| Firefox, not running, address in argv | `open([], withApplicationAt:)`, `arguments = ["-private-window", "https://example.com/"]` | argv as given; one window "Example Domain — Private Browsing" |
| Chrome, not running (isolated `--user-data-dir`, the user's Chrome kept running), address as an event | `open([url], …)`, `--incognito` | windows "Example Domain" and "New Incognito Tab"; `History` has `https://example.com/` |
| Chrome, same, address in argv | `open([], …)`, `--incognito https://example.com/` | one window "Example Domain"; `History` empty (incognito) |

Window titles were read with `CGWindowListCopyWindowInfo` (shown in English; the test Mac's are
Turkish: “Gizli Gezinti”, “Yeni Gizli Sekme”);
Chrome's `History` was read from the isolated data directory after 25 s. The test Chrome instances
used `createsNewApplicationInstance = true` only because the user's Chrome was running; the runner
never sets it. Every test browser was quit afterwards.

## Runner: only while the browser is closed

Unchanged rules ([runner slice](launch-action-runner-slice.md)): the browser must be installed at an
app bundle with the plan's bundle ID, **no instance may run**, `environment = [:]`,
`createsNewApplicationInstance = false`, only from the user's own click (`userAction`,
`standaloneAgent`), and only with this Mac's approval.

Why "closed" matters more here: a running browser ignores the arguments and the address would open
in **its current, normal window**: history, cookies and session of the profile in use (verified for
running Chrome and Firefox in the runner slice: arguments dropped, address handed over). So a
running browser is refused, nothing is sent to it, and the row says "Chrome is running: the item
opens only after you quit it."

## Approval digest

Same file and rules ([approvals](launch-action-approvals.md#digest)); the canonical text has no
`profile` line:

```text
cybokron-dock-groups/launch-action-approval/1
item=27:https://github.com/cybokron
kind=7:website
url=27:https://github.com/cybokron
template=14:browserPrivate
browser=6:chrome
opener=0:
```

The template line keeps it apart from every browser-profile text, so an approval of a profile for
the same website doesn't cover a private window (`mismatch`), and the other way round. Existing
browser-profile approvals are unchanged.

## Group window

- Details editor, browser profile part: once a browser is chosen, **"Open in a private window"**
  (`item.launch.private.toggle`) under the browser menu. On: the profile field and its hint are
  hidden, a short hint is shown (`item.launch.private.hint`), the profile name isn't checked or
  saved. Off again: the profile field is back, with its name rule.
- Row: "Chrome · private window" (`item.launch.private.row`), plus the running note.
- Confirmation: title "Open “GitHub” in a private Chrome window?"
  (`item.launch.private.confirm.title`); message (not localized) the full address, then
  `Google Chrome (com.google.Chrome)`. Turn On sets exactly the action the alert showed
  (`LaunchActionSummary.action`).
- An imported or invalid private-window action reuses the browser profile's review texts.

Localization: 4 keys, `en.lproj` only, `LocalizationTests.awaitingTranslation =
["item.launch.private."]`, listed in [l10n-keys.md](../l10n-keys.md) (English only for now).

## Tests

`Tests/DockGroupsCoreTests/LaunchActionPrivateWindowTests.swift` (fakes only):

- **Decoder:** each browser read and written as `template` + `browser` only; imported stays off; a
  `profile` key of any type or value → `unknownKey`; missing/unknown browser, wrong type, unknown
  key, forbidden key, misspelled template refused; websites only; `browserProfile` without profile
  still `missingProfile`.
- **Plan:** each browser's exact argv `[option, url]`, `urlsToOpen` empty; a browser profile still
  hands the address over; shape (two elements, fixed option, address not an option); `file:`,
  `javascript:`, `mailto:`, user:password, `ftp:`, `chrome:` refused; other bundle IDs, not
  installed, other item kinds, imported refused.
- **Runner / launcher:** closed → started with the argv, no URL event, empty environment; running
  (any case) → refused, nothing opened; no approval, no approval store, or a profile's approval →
  not opened; every unattended source → not opened.
- **Digest:** exact canonical text; browser, address, opener and a profile action change it.
- **Editor / row / confirmation:** private window saved only after confirmation, approved; the
  profile name ignored; a confirmation counts only for the action shown; an item's private window
  shown and turned back into a profile; imported → Turn On; row captions; summary title and
  details; what the editor saves is what the launcher starts.

Existing launch-action tests are unchanged and pass.

## Residual risk

- **Edge `--inprivate` and Brave `--incognito` are unverified** (neither is installed on the test
  Mac). If a build ignores the switch, the page opens in a normal window: a privacy leak, not code
  execution. Check on a Mac with them before relying on it.
- **Policies:** a managed browser that disables private browsing (Chrome
  `IncognitoModeAvailability`, Firefox `DisablePrivateBrowsing`) may open a normal window instead
  (unverified).
- **Running-app race:** if the browser starts in the milliseconds between the running check and the
  start, the arguments are dropped; then nothing is opened (no URL event is sent), unlike a profile
  plan, which would hand the address to that browser.
- **Vendor changes:** switch names and their handling with a positional address can change per
  release; re-check per major version, as for the profile switches.
- The hidden `--launch-plan` dry run still plans browser profiles only.
