# Design: ask for authentication before quitting apps

- **Status:** implemented (unreleased).
- **Setting:** Settings → Switching → **Ask for authentication before quitting apps**, global, **off
  by default** (`PopupPreferences.asksForAuthenticationBeforeQuitting`, saved in `preferences.json`
  as `"authenticateBeforeQuitting": true` only while it's on).
- **Code:** `DockGroupsCore/Commands/QuitAuthentication.swift` (`QuitAuthentication`,
  `ApplicationAuthenticating`, `DeviceOwnerAuthenticator`), used by `GroupQuitRequests` (Close All)
  and `ContextSwitcher` (Start and Finish); the app's `AppDelegate`, `AgentAppDelegate` and
  `LaunchReportPresenter.presentRefusal`.
- **Tests:** `Tests/DockGroupsCoreTests/QuitAuthenticationTests.swift`.
- **Builds on:** [context-switching-spec.md](context-switching-spec.md) (C-3, C-4, §2.5) and
  [group-shortcuts-and-templates-spec.md](group-shortcuts-and-templates-spec.md) (a group shortcut's
  alert, 0.7 s confirm delay).

## 1. Scope

While the setting is on, only the paths that **quit apps** need the device owner first:

| Action | Needs authentication |
| --- | --- |
| Close All (popup), normal and ⌘-click **Force Quit** | yes |
| `quit/<group>` link, also `?mode=force` | refused (can't ask, §3) |
| Start that would quit apps (“Quit and Switch”) | yes, only when the plan quits something |
| Finish that would quit apps | yes, only when the plan quits something |
| Hide All, Open All, opening an item, Show Popup, Start/Finish that only hide or show | **never** |
| Triggers and a Focus | never: they never quit (C-3, D-3) |

With the setting off, every path behaves exactly as before: nothing calls LocalAuthentication, and
Close All from the popup still runs synchronously.

## 2. Method

`LAContext.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "quit apps")` — macOS shows
“Cybokron Dock Groups is trying to quit apps.” and offers Touch ID, a paired Apple Watch, or the
account password, in the order it chooses.

Why `.deviceOwnerAuthentication`, not a biometrics-only policy: a Mac without Touch ID (or a closed
MacBook on an external keyboard without it) could never quit anything, and biometrics-only
policies have no password fallback. `.deviceOwnerAuthenticationWithWatch` alone has the same
problem. The password fallback keeps the setting usable on every Mac.

Nothing is stored: no keychain item, no secret, no “remember for N minutes”. Every request gets a
fresh `LAContext`, so one authentication never covers a later quit. Only one prompt shows at a
time; a second request while one is showing is dropped.

## 3. Fail-closed matrix

Every row quits **nothing**, and the user is told (an alert in the app; an error or summary in Siri
and Shortcuts). The log records only the result code (`cancelled`, `failed`, `unavailable`,
`notInteractive`), never how the user authenticated.

| Situation | Result | Shown |
| --- | --- | --- |
| User cancels the prompt (`userCancel`, `systemCancel`, `appCancel`, `userFallback`) | `cancelled` | “Nothing was quit: authentication was cancelled, failed or isn't available on this Mac.” |
| Authentication fails (`authenticationFailed`) | `failed` | same |
| `passcodeNotSet`, `biometryNotAvailable`, `biometryNotEnrolled`, `biometryLockout`, `notInteractive` (no window for the prompt), `invalidContext`, any other or future `LAError` | `unavailable` | same |
| `canEvaluatePolicy` says no | from its error, as above | same |
| No authenticator at all (a standalone group's app) | `unavailable` / `notInteractive` | same / below |
| Request from a link, Siri, Shortcuts, the command line or a standalone group's own app | `notInteractive`, **before** any question | “Nothing was quit: “Ask for authentication before quitting apps” is on, and links, Siri, Shortcuts, the command line and standalone groups' own apps can't ask for it. Quit the apps from Cybokron Dock Groups itself instead.” |
| Another question or prompt is showing | dropped | logged |

A Start or Finish that's refused does nothing at all: nothing is hidden, quit or opened, and the
current group doesn't change.

## 4. Which paths can ask

Authentication is asked only where the main app owns the interaction: the popup, the menu bar
menu, the group window, and a group's own keyboard shortcut (`QuitRequestSource.canAuthenticate`,
`TransitionTrigger.canAuthenticate`).

| Path | While the setting is on |
| --- | --- |
| Popup Close All / Force Quit; Start/Finish from the popup, menu bar or group window | asks, then quits on success |
| A group's keyboard shortcut Start/Finish | the existing alert first (Cancel, Hide Instead, Quit and Switch); authentication only after **Quit**; Cancel and Hide Instead never ask |
| `quit/`, `start/`, `switch/`, `finish/` links | refused without showing the link's question; an alert says why; the link cooldown restarts |
| `cybokrondockgroups` CLI | it only sends links to the running app: the same as links |
| Siri / Shortcuts Quit Group | ends with an error before Siri's confirmation; nothing quit |
| Siri / Shortcuts Start or Finish Group that would quit | not asked; the result says nothing was quit |
| Triggers (automation), Focus | unchanged: they never quit, so they hide as before |
| A standalone group's own app (popup, Dock menu Close All) | refused with an alert; only the main app asks. The setting reaches the agent through its configuration |

**Order:** where a question exists, the question comes first and authentication second, so the
user answers once each and never authenticates for something they then cancel. A link and Siri are
refused before their question, since the request could never be carried out.

## 5. What it doesn't guarantee

- **It's not protection against someone in the same user session.** Anyone using the unlocked
  account can turn the setting off, edit `preferences.json`, quit apps from the Dock, Activity
  Monitor or `kill`, or install an older version of the app. It guards against *accidental* or
  *unattended* quitting from this app — a stray click, a link a web page opened, a Shortcuts
  automation — not against a determined local user.
- Turning the setting off doesn't ask for authentication.
- A backup restored with Replace All replaces the setting, as it replaces every setting.
- A version without this setting ignores it (downgrade): it quits without asking.
- Apps that are asked to quit can still refuse or ask to save changes (graceful quit), as before.

## 6. Automation impact

With the setting on, links, the command line, Siri and Shortcuts can no longer quit apps through
this app — including Start and Finish when a group is set to quit apps. Hiding settings keep
working everywhere. Triggers and Focus filters are unaffected (they never quit). Users who rely on
automations that quit apps should leave the setting off, or set those groups to hide instead.

## 7. Manual checks (not automatable)

1. Touch ID Mac: Close All → Touch ID prompt; cancel → alert, nothing quit; success → apps quit.
2. Mac without Touch ID / lid closed: password prompt appears.
3. Apple Watch unlock enabled: the watch is offered.
4. The prompt appears in front while the app is a menu bar app (`LSUIElement`) and the popup is a
   non-activating panel.
5. Standalone group's Dock menu Close All with the setting on → alert, nothing quit.
6. `cybokrondockgroups://quit/<group>` and the CLI with the setting on → alert, nothing quit.
