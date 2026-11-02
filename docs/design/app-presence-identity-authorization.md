# Application presence triggers: local identity authorization

Status: implemented in `DockGroupsCore` on the unreleased branch `codex/app-presence-code-hash`; the
running-code verifier is connected in the app (`codex/app-presence-identity-verifier`). There is
still no flow that creates an `authorized` record, and localization beyond English is pending. This
document describes the model, the persisted format, the fail-closed gates, the verifier, migration
and privacy, and what remains open. It implements decisions K1-K3 below against the release
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

The verifier logs an abstract failure code only. The coordinator's existing log lines name trigger and group identifiers and actions
only. The record stores the selected app's signing identifier, `cdhash`, signature kind and a time in
the local `triggers.json`, which is the binding itself; it is never exported in backups and never
appears in diagnostics (which report trigger counts and kinds only).

## Remaining risks and open work

- **No binding can be created yet.** There is no verified-selection flow, so `authorized` records
  exist only in tests or in a hand-edited local file. The release contract §7(a) items 1, 3 and 5
  are still open; item 2 is implemented for the instances the verifier lists (see the threat model).
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
- **Re-approval flow.** `needsReapproval` is now saved automatically, but there is still no way to
  approve the new code; the rule stays off until it is removed and added again.
- **The verifier lists instances separately from the snapshot.** Within one main-actor turn the
  verifier and the presence source read the same `NSWorkspace.runningApplications`, but the
  coordinator's counts carry no instance identity, so completeness (T11) rests on both using the
  same match. A process without a bundle identifier is neither counted nor checked (strict mode
  makes such a snapshot unknown anyway).
- **UI texts.** "Doesn't run: this version can't check the running app's code yet." is still the
  line for an authorized rule that isn't confirmed; it is now inaccurate (this version checks) and
  belongs to the UI/localization slice, as do the translations of
  `core.trigger.skip.applicationNotConfirmed`.
- **Equality.** The F2 stamp compares whole rules, so even an equal re-approval of the same binding
  cancels pending firings. This is intended (fail closed), not a defect.
