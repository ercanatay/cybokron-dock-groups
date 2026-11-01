# Application presence triggers: local identity authorization

Status: implemented in `DockGroupsCore` on the unreleased branch `codex/app-presence-code-hash`. No
UI, no localization and no running-code verifier are connected yet. This document describes the
model, the persisted format, the fail-closed gates, migration and privacy, and what remains open. It
implements decisions K1-K3 below against the release contract in `app-presence-threat-model.md` §7.

## Decisions this implements

- **K1.** The bundle-identifier-only ("weak") mode stays, is **off by default**, is recorded as
  `unverified`, and may only run **Show Popup**.
- **K2.** When the code of an authorized app changes (an update), the rule **waits** and needs the
  user's approval again. Trust is never widened automatically.
- **K3.** Identity can only come from a running instance the user explicitly chose and that was
  verified on this Mac. Nothing from an import, a restore, a legacy rule or a backup (path, hash,
  signature, requirement or `enabled`) counts as trust.

## Model

`Sources/DockGroupsCore/Triggers/ApplicationIdentityAuthorization.swift` (all types `internal`):

- `ApplicationIdentityBinding`: signing identifier (validated by `TriggerApplicationIdentifier`,
  compared case-sensitively with the rule's bundle identifier), exact code hash (`cdhash`, 20 bytes,
  `ApplicationCodeHash`), signature kind (`apple`, `appStore`, `developerID`, `adHoc`; unsigned code
  has no case and cannot be represented), and the authorization time in whole seconds. No path, PID
  or app name.
- `ApplicationIdentityAuthorization`:

  | Status | Meaning | What may run |
  |--------|---------|--------------|
  | `authorized(binding)` | The user chose and confirmed a verified running instance | Every action the event allows, **only while the verifier answers `verified`** |
  | `needsReapproval(binding)` | The authorized code changed | Nothing; the rule is not observed |
  | `unverified` | Bundle identifier only | Show Popup only; other actions are skipped and recorded |
  | `invalid(raw)` | A record that can't be read | Nothing; the record is kept and written back unchanged |

- Transitions: `authorize(_:)` is the only way to `authorized` and must be fed from a verified,
  user-chosen running instance (no caller exists yet). `requiringReapproval()` moves `authorized` to
  `needsReapproval` and leaves every other state alone. `reapproved(with:)` returns `authorized` only
  for a binding with the same identifier (another app is a new choice, not a re-approval).
- `GroupTrigger.applicationIdentity` (internal, optional) holds the record for application-presence
  rules and is `nil` for every other event. `GroupTrigger.applicationIdentityStatus` is the effective
  status: no record is `unverified`, and an `authorized` or `needsReapproval` record whose identifier
  differs from the event's bundle identifier is `invalid`.
- Changing a rule's application in memory (the event's bundle identifier) resets the record to
  `unverified`; changing it to another kind of event removes it.

## Persisted format

The record is an optional key of the trigger object in `triggers.json` (the event object itself is
unchanged, so its strict decoder still turns unknown event keys into `.unsupported`):

```json
"applicationIdentity": {"status": "unverified"}

"applicationIdentity": {
  "status": "authorized",            // or "needsReapproval"
  "identifier": "com.example.App",
  "cdhash": "0123456789abcdef0123456789abcdef01234567",
  "signature": "developerID",       // apple | appStore | developerID | adHoc
  "authorizedAt": 1793000000        // integer seconds since 1970
}
```

Decoding is strict. Any of the following makes the record `invalid` (kept as read, never runs): not
an object; missing or unknown `status` (including a literal `"invalid"`); extra or missing keys;
empty, short, long or non-hex `cdhash` (upper-case hex is accepted and normalized); unknown or empty
`signature`; `authorizedAt` that is not an integer or is out of range; an identifier that
`TriggerApplicationIdentifier` refuses or that is not exactly the event's bundle identifier.

A missing key or `null` is a rule saved before records existed: it is loaded as `unverified` **and
turned off** (see Migration). Every application-presence rule saved by this version carries a record,
so a user-enabled `unverified` rule stays enabled across launches.

`TriggerSkipReason.applicationNotVerified` is a new value in `trigger-state.json`. Older versions
fail to read that one outcome and keep the entry without it (existing lenient behavior).

## Gates (fail closed)

The gates are added to the existing check chain; they do not replace any F2/F3 check.

1. **Runnable** (`GroupTrigger.isRunnable`): `needsReapproval` and `invalid` rules are not runnable,
   so `canRun` is false everywhere it is already checked (tracker configuration, evaluator, carry-out,
   rebaseline). Their row shows the existing "Can't run: fix or remove it." problem text.
2. **Evaluator** (`TriggerEvaluator.identityGate`, before cooldown/echo/pause): an `unverified` rule
   fires only Show Popup; any other action is recorded as `.skipped(.applicationNotVerified)` and
   produces no firing. `authorized` passes here and is checked by the coordinator.
3. **Coordinator** (`ApplicationIdentityClearance.of(rule, verifier:)`): `authorized` + `verified`
   clears every action, `unverified` clears Show Popup, everything else (including `authorized` with
   `codeChanged` or `unavailable`) clears nothing. It is applied:
   - in `refresh()`: rules that clear nothing are not configured in the presence tracker, so they are
     never observed (with no other eligible rule, observation stops and pending presence firings are
     pushed out);
   - in `observeApplications`' `currentRule(for:)`, which also runs inside `receive` right before
     firings are enqueued;
   - in `isApplicationPresenceFiringCurrent`, i.e. at settle, before a notice, after a notice and
     immediately before the handler is called (the F2 stamp checks), where the clearance must permit
     the firing's action.
4. **Push hook** (`applicationIdentityVerdictsChanged()`): drops presence firings that are no longer
   cleared and dismisses an awaiting notice of one (recorded as skipped). For the future verifier;
   carry-out re-checks regardless.

Because the stamp compares the whole rule, any change of the record (for example a stored transition
to `needsReapproval`) also invalidates pending, queued and notice-stage firings through the existing
F2 path. `receive(.applicationEdge)` stays ignored (F3).

## Verifier

`ApplicationIdentityVerifying` (main actor, `verdict(for: binding) -> verified | codeChanged |
unavailable`) is injected through the internal `TriggerCoordinator.applicationIdentityVerifier`.
The production default, `UnavailableApplicationIdentityVerifier`, always answers `unavailable`, so
**authorized rules never act in a build of this branch** and only enabled `unverified` Show Popup rules
can run. Tests inject `FakeApplicationIdentityVerifier`. The experimental helpers
(`ApplicationRunningCodeVerifier`, `ApplicationStaticCodeVerifier`, `ExperimentalProcessEventWatch`)
are not connected. A real implementation must answer from results it already has (verification runs
off the main actor with bounds, cancellation and a timeout) and must not log hashes, paths or other
apps' identities.

## Migration and backward compatibility

- Rules without a record (earlier builds of this branch) load as `unverified` and **disabled**. Nothing
  re-enables itself; turning one on is a click on this Mac and then runs Show Popup only.
- New application rules from `TriggerDraft` are `unverified` and disabled. Editing an existing rule
  keeps its record only when the application is unchanged; choosing another application makes it
  `unverified` and disabled.
- Imports, restores and merges (`SettingsBackup.importedTriggers`, `restore`, `merge`, all through
  `turnedOff`) reset every record to `unverified` and turn the rule off. Exports write `unverified`
  only, so no code hash or signing data leaves the Mac in a backup.
- An earlier build of this branch ignores the key, would run the rule with bundle-ID matching and all
  actions, and drops the key when it saves; on the next launch of this version the rule loads as
  legacy, i.e. disabled. Released versions don't know application-presence events at all.
- Public API: only `TriggerSkipReason.applicationNotVerified` is new. `GroupTrigger`'s public
  initializer and coding keys are unchanged apart from the optional key.

## Privacy

No new logging. The coordinator's existing log lines name trigger and group identifiers and actions
only. The record stores the selected app's signing identifier, `cdhash`, signature kind and a time in
the local `triggers.json`, which is the binding itself; it is never exported in backups and never
appears in diagnostics (which report trigger counts and kinds only).

## Remaining risks and open work

- **No binding can be created yet.** There is no verified-selection flow, so `authorized` records
  exist only in tests or in a hand-edited local file. The release contract §7(a) items 1-3 and 5 are
  still open; T5 (PID reuse), T6 (exec before watch registration) and T10 are unchanged.
- **Local file edits (A1).** Anyone who can write `triggers.json` can mark a rule `unverified` and
  enabled (Show Popup only) or write an `authorized` record. The latter does nothing with the
  production verifier; once a real verifier exists, a crafted record naming the genuine app's
  `cdhash` would be accepted. This is outside the defendable scope (§2).
- **`needsReapproval` is not persisted automatically.** A `codeChanged` verdict blocks the rule only
  while the verifier reports it; nothing calls `requiringReapproval()` yet. The controller must
  persist that transition and offer re-approval when the verifier is integrated.
- **Verdict changes and the tracker.** When a verdict change alters which rules are tracked,
  `refresh()` reconfigures and stops the tracker until the controller starts a new generation. The
  controller does not know about verdicts yet, so presence stays stopped (fail closed) until the
  next rule, wake or session reset.
- **The verifier sees a binding, not instances.** Whether every running instance under the identifier
  was checked (T11) is the implementation's responsibility; the coordinator's counts carry no
  instance identity.
- **UI.** The skip reason reuses the existing "Can't run: fix or remove it." sentence; the editor still
  offers every action for unverified rules (they are skipped at runtime), shows no "unverified" label,
  and an authorized rule blocked by an unavailable verifier shows no explanation. These belong to the
  UI and localization step.
- **Equality.** The F2 stamp compares whole rules, so even an equal re-approval of the same binding
  cancels pending firings. This is intended (fail closed), not a defect.
