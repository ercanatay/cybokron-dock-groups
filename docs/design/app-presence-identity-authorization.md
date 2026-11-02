# Application presence triggers: local identity authorization

Status: implemented in `DockGroupsCore` on the unreleased branch `codex/app-presence-code-hash`; the
running-code verifier is connected in the app (`codex/app-presence-identity-verifier`), and the
editor's approval creates `authorized` records (`codex/app-presence-identity-approval`).
Localization beyond English is pending, and several older UI texts still say this version can't
check an app's code (a separate change). This document describes the model, the persisted format,
the fail-closed gates, the verifier, the approval, migration and privacy, and what remains open. It implements decisions K1-K3 below against the release
contract in `app-presence-threat-model.md` §7.

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
  user-chosen running instance; its only caller is `TriggerStore.setApplicationIdentityAuthorization`
  (see Approval). `requiringReapproval()` moves `authorized` to
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

`TriggerSkipReason.applicationNotVerified` and `.applicationNotConfirmed` are new values in
`trigger-state.json`. Older versions fail to read that one outcome and keep the entry without it
(existing lenient behavior).

## Gates (fail closed)

The gates are added to the existing check chain; they do not replace any F2/F3 check.

1. **Runnable** (`GroupTrigger.isRunnable`): `needsReapproval` and `invalid` rules are not runnable,
   so `canRun` is false everywhere it is already checked (tracker configuration, evaluator, carry-out,
   rebaseline). Their row shows the existing "Can't run: fix or remove it." problem text.
2. **Evaluator** (`TriggerEvaluator.identityGate`, before cooldown/echo/pause): an `unverified` rule
   fires only Show Popup; any other action is recorded as `.skipped(.applicationNotVerified)` and
   produces no firing. `authorized` passes here and is checked by the coordinator.
3. **Coordinator** (`ApplicationIdentityClearance.of(rule, verifier:)`): `authorized` + `verified`
   clears every action, `unverified` clears Show Popup, `authorized` + `pending` is observed but
   clears nothing (`awaitingVerification`), everything else (including `authorized` with
   `codeChanged` or `unavailable`) clears nothing. It is applied:
   - in `refresh()`: rules that clear nothing are not configured in the presence tracker, so they are
     never observed (with no other eligible rule, observation stops and pending presence firings are
     pushed out). When a verdict changes the tracked rules while a generation runs, the tracker
     stops and the app is asked to restart observations under a new generation
     (`onApplicationObservationsNeedRestart`);
   - in `observeApplications`' `currentRule(for:)`, which also runs inside `receive` right before
     firings are enqueued;
   - in `isApplicationPresenceFiringCurrent`, i.e. at settle, before a notice, after a notice and
     immediately before the handler is called (the F2 stamp checks), where the clearance must permit
     the firing's action.
4. **Push hook** (`applicationIdentityVerdictsChanged()`, called by the verifier when a check
   finishes with another verdict): saves rules whose verdict is `codeChanged` as `needsReapproval`
   (`onApplicationIdentityCodeChanged` → `TriggerStore.requireApplicationReapproval(for:)`), drops
   presence firings that are no longer cleared, dismisses an awaiting notice of one, then
   reconfigures the tracker (`refresh()`) and asks for a restart when the tracker can't go on with
   the new rule set. Carry-out re-checks regardless.
5. **Visible record.** A firing of an `authorized` rule that passes every other check but whose
   verdict is `pending` or `unavailable` is skipped with `TriggerSkipReason.applicationNotConfirmed`
   ("the app's running code couldn't be confirmed, so nothing ran") at the settle, before the notice,
   after a verdict push during the notice, and right before the handler. A firing whose check is
   still running at the settle waits exactly one more settle (2 s; the check's own bound is 2 s) and
   is then recorded. `codeChanged` is not recorded this way: the rule is saved as needing
   re-approval and its status line says so (after a notice it keeps the existing `anotherTrigger`).
   The trigger lists show the last-run line for an authorized rule whose code is confirmed or being
   checked, or whose last outcome is this skip; otherwise the existing "verification unavailable"
   line.

Because the stamp compares the whole rule, any change of the record (for example a stored transition
to `needsReapproval`) also invalidates pending, queued and notice-stage firings through the existing
F2 path. `receive(.applicationEdge)` stays ignored (F3).

## Verifier

`ApplicationIdentityVerifying` (main actor, `verdict(for: binding) -> verified | pending |
codeChanged | unavailable`, plus a side-effect-free `displayedVerdict(for:)`, a change handler and
`retainOnly(_:)`) is injected through the internal `TriggerCoordinator.applicationIdentityVerifier`.
The coordinator's default is still `UnavailableApplicationIdentityVerifier` (fail closed); the app
switches to `RunningApplicationIdentityVerifier` in `TriggerController.init` through
`verifyRunningApplicationIdentities()`. Tests inject `FakeApplicationIdentityVerifier` or the real
verifier with fake instances, watches and Security answers.

`RunningApplicationIdentityVerifier` (`Sources/DockGroupsCore/Triggers/RunningApplicationIdentityVerifier.swift`),
per binding it is asked about:

1. Lists the PIDs of the running applications counted under the identifier (the same ASCII,
   case-insensitive match as `ApplicationSnapshotCounter`). No instance, and no unconfirmed instance
   having left: `verified` without a check.
2. For a new instance set: registers an `ExperimentalProcessEventWatch` (kqueue exec/exit) on every
   PID **first**, polls each once (anything pending is `unavailable`), then checks every PID with
   `ApplicationRunningCodeCheck` and answers `pending` meanwhile. The check calls
   `ApplicationRunningCodeVerifier.compare` (fresh `SecCode` by PID, validity, then `identifier` +
   exact `cdhash`) on a detached task, bounded by a 2 s timeout and cancellable through
   `withTaskCancellationHandler`. **The synchronous Security call itself can't be interrupted:** a
   timeout or cancellation only stops waiting, the call runs to its end and its answer is ignored.
   Timeout and cancellation are `unavailable`, never `verified`.
3. When the checks finish (back on the main actor, only for the latest token): any different code
   is `codeChanged`; otherwise a watch that reported anything, or any failure, is `unavailable`;
   only all instances matching with idle watches is `verified`. It then calls the change handler if
   the verdict changed.
4. While the set is unchanged it answers from that result, polling the watches on every question:
   exec, an error or a coalesced exec+exit is `unavailable`. A verified instance may leave (exit),
   but an instance that leaves before its check finished makes the binding `unavailable` (it was
   never confirmed). An `unavailable` binding is checked again every 10 s while it keeps answering
   `unavailable`; only a successful retry changes it (and then the coordinator restarts
   observations under a new generation). `codeChanged` is never retried.
5. Limits: 16 instances per application, 64 open watches per verifier; more is `unavailable`.
   Bindings no runnable rule uses any more are forgotten (`retainOnly`), closing their watches and
   cancelling their checks.

It logs only an abstract failure code (`ApplicationCodeCheckFailure.diagnosticCode`) and "different
code"; never a hash, path, app name or PID.

### Fail-closed matrix

| Saved record | Verifier result | Observed | Actions | Recorded |
|--------------|-----------------|----------|---------|----------|
| none / legacy / imported | — | turned off | none | — |
| `unverified` | not asked | yes | Show Popup only | others `applicationNotVerified` |
| `authorized` | `verified` | yes | every allowed action | ran |
| `authorized` | `pending` (check running) | yes | none until `verified` | `applicationNotConfirmed` if still pending after one extra settle |
| `authorized` | `unavailable` (error, timeout, cancel, exec, unconfirmed exit, limits, no list) | no | none | `applicationNotConfirmed` for a firing already waiting |
| `authorized` | `codeChanged` | no | none | saved as `needsReapproval`; pending and notice-stage work cancelled |
| `authorized` | verifier never checked it / default verifier | no | none | — (status line: verification unavailable) |
| `needsReapproval`, `invalid` | not asked | no | none | — |

## Approval

`TriggerApplicationApprover` (`Sources/DockGroupsCore/Triggers/ApplicationIdentityApproval.swift`)
is the only producer of `authorized` records. The editor offers **Approve This App** for a saved,
`unverified` application trigger and **Approve the New Version** for one that `needsReapproval`,
as long as the app chosen in the editor is still the trigger's app (a new trigger, or one whose app
was changed, says "save the trigger first"). The click is the user's explicit approval; nothing else
starts an approval. `TriggerController.approveApplication(ofTrigger:)` runs it in a task the editor
cancels with Cancel or when it closes.

Steps, all on the main actor except the reading:

1. The stored trigger must be an application trigger that is `unverified` or `needsReapproval`
   (`GroupTrigger.canApproveApplication`); otherwise `notApprovable`.
2. The instances under the identifier are listed (`RunningApplicationIdentityVerifier.runningInstances`,
   the verifier's own match). None: `notRunning`, nothing is read or saved. The list can't be read:
   `checkFailed`. More than 16: `tooManyInstances`.
3. An exec/exit watch is registered on every instance **first** and polled once (anything pending:
   `appChanged`; registration failure: `checkFailed`).
4. Every instance is read off the main actor by `ApplicationRunningIdentityReader` (fresh `SecCode`
   by PID, validity, signing information of its code: identifier, `cdhash`, signature kind from the
   ad hoc flag and the Apple / App Store / Developer ID anchor requirements), and the reading is
   then confirmed with `ApplicationRunningCodeVerifier.compare`, the requirement the verifier itself
   uses. Each reading is bounded (2 s) and cancellable through `BoundedSecurityCall`, the same
   bounded call the verifier's check now uses; the synchronous Security call itself can't be
   interrupted.
5. Back on the main actor, in this order: cancelled → `cancelled`; any time-out → `timedOut`; a
   watch that reported anything, or a different instance list → `appChanged`; a confirmation that
   disagreed with the reading → `appChanged`; a signing identifier that isn't exactly the trigger's
   bundle identifier (case-sensitive) → `identifierMismatch`; unsigned or a signature without a
   `SignatureKind` (e.g. a development signature) → `unsupportedSignature`; any Security failure →
   `checkFailed`; instances with different code or signature kind → `differentVersionsRunning`.
6. Only one exact identity for every instance, with the stored trigger still equal to the one the
   approval started from (`triggerChanged` otherwise), becomes a binding (`authorizedAt` = now),
   wrapped in `VerifiedApplicationApproval`, whose initializer is `fileprivate` to the approver's
   file.
7. `TriggerStore.setApplicationIdentityAuthorization(_:forTrigger:replacing:)` (internal) takes only
   that value. It changes nothing unless the stored trigger is still exactly the expected one and
   the binding names its bundle identifier; `unverified` becomes `authorize(binding)`,
   `needsReapproval` becomes `reapproved(with:)` (same identifier only); `authorized`, `invalid` and
   other events are refused. It writes the file **before** showing the change; a failed write (or
   suspended saving) changes nothing (`notSaved`). It never touches `isEnabled`.

Imports, restores and merges don't call it and still reset every record to `unverified`
(`droppingImportedIdentity`, unchanged); `add`/`update` only carry the record they are given, and
the editor builds it from the trigger as stored at the moment of saving, so an approval (or a
re-approval saved by the verifier) made while the editor is open is kept.

| Situation at approval | Outcome | Saved |
|-----------------------|---------|-------|
| App not running | `notRunning` ("open the app, then approve it") | nothing |
| One or more instances, all the same exact code, Apple / App Store / Developer ID / ad hoc | `approved` | `authorized(binding)`; switch unchanged |
| Same, trigger `needsReapproval` | `approved` | `authorized(new binding)`; old hash no longer accepted; switch unchanged |
| Exec, exit, a new or a missing instance between the watch and the end of the reading | `appChanged` | nothing |
| Reading and confirmation disagree | `appChanged` | nothing |
| Signing identifier ≠ bundle identifier (exact) | `identifierMismatch` | nothing |
| Unsigned / development signature | `unsupportedSignature` | nothing |
| Different code among the instances | `differentVersionsRunning` | nothing |
| Time-out (2 s) / Cancel / editor closed | `timedOut` / `cancelled` | nothing |
| Security error, watch can't be registered, list unreadable | `checkFailed` | nothing |
| Trigger edited, removed or re-saved meanwhile | `triggerChanged` | nothing |
| File can't be written | `notSaved` | nothing |

After approval the trigger is `authorized`: the editor offers every action, and the coordinator's
gates (above) still require the verifier's `verified` verdict before anything runs. Verification
alone authorizes nothing (the verifier never writes), and approval alone runs nothing (the
verifier still has to confirm the running code). Nothing in the approval is logged.

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
- Public API: `TriggerSkipReason.applicationNotVerified`, `TriggerApplicationApprover`,
  `TriggerApplicationApprovalOutcome` / `Failure` and `GroupTrigger.canApproveApplication` are new. `GroupTrigger`'s public
  initializer and coding keys are unchanged apart from the optional key.

## Privacy

The verifier logs an abstract failure code only; the approval logs nothing, and its outcomes name
no path, PID, app name or hash. The coordinator's existing log lines name trigger and group identifiers and actions
only. The record stores the selected app's signing identifier, `cdhash`, signature kind and a time in
the local `triggers.json`, which is the binding itself; it is never exported in backups and never
appears in diagnostics (which report trigger counts and kinds only).

## Remaining risks and open work

- **Approval is PID based too.** The reading and its confirmation look the process up by PID, after
  the watch is registered: a PID recycled or an exec before registration is read as if it were the
  listed instance (T5, T6). The user approves "the code of this app running now", not a specific
  window or the bundle shown in the picker; the editor shows the bundle identifier only, not the
  version that was read (T9 partly).
- **Release contract.** §7(a) item 1 is now implemented for the approval itself (local, explicit,
  running, verified, unique code, outside every import path); items 3 and 5 are still open; item 2
  is implemented for the instances the verifier lists (see the threat model).
- **Architectures.** The binding records the `cdhash` of the running instance's code only; the
  same app running under another architecture (or Rosetta) has another `cdhash` and makes the rule
  wait for re-approval (T15, availability).
- **PID reuse and exec before the watch.** Registration and the Security lookup are both PID based:
  a PID recycled before the watch was registered, or an exec before registration, is checked and
  watched as if it were the listed instance (T5, T6 partly).
- **Check to action.** The last verdict check and the handler call are not atomic: an exec right
  after the final check, or while an action runs, isn't caught (T10).
- **The Security call can't be cancelled.** A timed-out or cancelled check leaves its detached call
  running until Security returns; repeated time-outs can pile up such calls (one per instance per
  retry, at most every 10 s).
- **No wake-up.** Watches are polled when the coordinator asks; nothing wakes it on an event. An
  `unavailable` rule recovers only through its retry; a rule whose only source of questions is its
  own observation is asked again on the retry's change notification.
- **Descriptor limit.** The 64-watch limit is per verifier; there is no process-wide descriptor limit
  and descriptor exhaustion is untested (it would be `watchUnavailable`).
- **Different signing identifier, same bundle identifier.** Any listed instance whose code doesn't
  satisfy the authorized `identifier` + `cdhash` (including a look-alike, a case variant of the
  bundle identifier, or a legitimate update) is `codeChanged` and makes the rule wait for
  re-approval. A look-alike can therefore switch the rule off (availability, not a widening).
- **Local file edits (A1).** Anyone who can write `triggers.json` can mark a rule `unverified` and
  enabled (Show Popup only) or write an `authorized` record. The latter does nothing with the
  production verifier; once a real verifier exists, a crafted record naming the genuine app's
  `cdhash` would be accepted. This is outside the defendable scope (§2).
- **Re-approval keeps the switch.** A trigger that was on when it needed re-approval runs again
  after the user approves the new version; one that was off stays off. Approval never changes the
  switch.
- **The verifier lists instances separately from the snapshot.** Within one main-actor turn the
  verifier and the presence source read the same `NSWorkspace.runningApplications`, but the
  coordinator's counts carry no instance identity, so completeness (T11) rests on both using the
  same match. A process without a bundle identifier is neither counted nor checked (strict mode
  makes such a snapshot unknown anyway).
- **UI texts.** "Doesn't run: this version can't check the running app's code yet." is still the
  line for an authorized rule that isn't confirmed, and `triggers.identity.detail.verificationUnavailable`,
  `howToReapprove`, `editor.onlyShowPopup` and `sectionNote` still say apps can't be checked; they
  are now inaccurate and belong to the UI/localization slice, as do the translations of
  `core.trigger.skip.applicationNotConfirmed` and `triggers.identity.approve.*`. The editor shows
  `howToReapprove` only where no approval is offered, and its own approved note for an authorized
  trigger.
- **Equality.** The F2 stamp compares whole rules, so even an equal re-approval of the same binding
  cancels pending firings. This is intended (fail closed), not a defect.
