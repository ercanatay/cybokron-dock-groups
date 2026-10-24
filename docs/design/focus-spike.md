# Spike: Focus filter delivery (context switching PR 5)

- **Date:** 2026-10-24. **Mac:** macOS 27.0.1 (26A434), Xcode 27.1 (27A9275), macOS 27.0 SDK.
- **Question:** can a menu bar app (`LSUIElement`) without an App Intents extension start a group when
  a Focus turns on, as `docs/design/context-switching-spec.md` §3.6 assumes (D-A1…D-A6)?
- **Method:** the SDK's `AppIntents.swiftinterface`, Apple's documentation ("Defining your app's Focus
  filter", `SetFocusFilterIntent`, WWDC22 session 10121 "Meet Focus filters"), the App Intents
  metadata of the system apps on this Mac, this repository's agent bundle layout, and a build of the
  app with the filter. The Focus itself was **not** switched on this Mac: that silences the user's
  notifications and needs the filter to be added by hand in System Settings, so the delivery checks
  below marked *manual* are left to the PR's manual test (they need macOS 14, 15 and 26 anyway).

## API (as expected)

- `protocol SetFocusFilterIntent: AppIntent, InstanceDisplayRepresentable` — macOS 13+, with
  `appContext`, `suggestedFocusFilters(for:)`, `invalidateFocusFilterAppContext()` and
  `static var current: Self { get async throws }`; errors `SetFocusFilterIntentError.notFound` and
  `.missingParameterValue` (macOS 13.3+). No entitlement or permission is involved.
- Parameters are ordinary `@Parameter`s; an `AppEntity` works as one (`GroupEntity`), so a renamed
  group keeps working. Non-optional parameters need a default.
- Apple: the system calls `perform()` with the configured parameters when the Focus turns on, and
  "when the system determines that the previously delivered values are no longer relevant" — the
  Focus turned off — with the **default** values: `nil` for optional parameters, the declared
  default for the others.
- The filter's title and description are static; the system reads them from the app's App Intents
  metadata when the app is installed. Mail on this Mac declares its Focus filter in the main app's
  `Metadata.appintents` (system protocol `com.apple.link.systemProtocol.FocusConfiguration`), with no
  extension: main-app filters exist on macOS.

- The app's build with the filter (`UNIVERSAL=1 scripts/build-app.sh release`) extracts it into
  `Contents/Resources/Metadata.appintents` as `GroupFocusFilter` with the same system protocol as
  Mail's (`com.apple.link.systemProtocol.FocusConfiguration`), parameters `group` (optional),
  `action` and `finishesWhenFocusEnds`, next to the five App Shortcuts.

## D-A1…D-A6

| # | Assumption | Result |
| --- | --- | --- |
| D-A1 | macOS launches the app to deliver `perform()` when it isn't running, without an extension | **No, per Apple.** WWDC22 10121: "If the app is running, you will receive a call to the perform method … If the app is not running, you can implement an extension that will get spun up." The app has no extension (adding one would need an App Group to reach the groups). So the filter works **while Cybokron Dock Groups is running** (it usually is: a menu bar app); Settings says so (spec §8 R1's fallback). *Manual:* confirm nothing happens when the app is quit, and that turning the Focus on and then opening the app doesn't act by surprise. |
| D-A2 | Switching Focus A → B calls `perform()` once with B's parameters, or off then on, in a stable order | **Unknown — manual.** The coordinator waits 1 s after the last call and acts on the last one, so "B" and "off, then B" both end as B. Only "B, then off" (which would contradict the active configuration) would be read as the Focus ending: record what macOS does. |
| D-A3 | `perform()` is called for a Focus turned on by schedule, by a Shortcut, or from another device | **Unknown — manual** (Apple's text covers every Focus change "the system has determined" relevant). |
| D-A4 | `current` works from the main app and reflects the active Focus right after launch | **API present** (`static var current`, async throws). Settings reads it when the pane appears and treats an error as "no Focus asks for anything". *Manual:* check its value after launch with a Focus on and off. |
| D-A5 | Known macOS 26.5 Focus filter bugs don't affect delivery | **Unknown — manual** on 26.x (this Mac runs 27.0.1). If delivery fails there, the filter stays, and the README says to use a Shortcuts automation instead. |
| D-A6 | Standalone groups' apps don't show up as a second filter | **Expected: no second filter.** An agent bundle holds a copy of the executable, its `Info.plist`, icon, string tables and `group-config.json` (`AgentBundleLayout`) — no `Metadata.appintents`, through which the system learns an app's intents. *Manual:* with a standalone group, System Settings → Focus → Add Filter lists Cybokron Dock Groups once. |

Repeated requests: a Focus filter and a Shortcuts automation that both start a group within 3 s
start it once (`ContextSession.repeatInterval`, shared by every trigger); Open All and Show Popup
requested by a Focus are deduplicated the same way in `FocusRequestCoordinator`.

## Decision

The API matches the spec; the one assumption the documentation answers (D-A1) fails in the way §8 R1
planned for, so PR 5 goes ahead with that fallback: the filter works while the app runs, and
Settings and the README say so. D-A2, D-A3, D-A4 (values), D-A5 and D-A6 stay **manual gates before
release** (DECISION 1): on macOS 14 and 15 (26 recorded) the filter must start a group when the
Focus turns on while the app runs, and never quit anything. If it doesn't, the filter ships disabled
or waits, as DECISION 1 says. An App Intents extension (with an App Group for the groups) is the way
to make it work while the app isn't running, in a later release.
