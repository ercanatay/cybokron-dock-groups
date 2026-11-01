# Application presence triggers: threat model and release contract

Status: review record for the unreleased branch `codex/app-presence-code-hash` (reviewed at
`c7a9f57`). It does not change code, approve a release or claim that any protocol is race-free.
Evidence and experiments are in `app-presence-identity-security.md`,
`app-presence-macho-slices.md`, `app-presence-running-binding-candidate.md` and
`app-presence-watch-protocol-draft.md`; behavior is specified in `app-presence-trigger-spec.md`.
File references are `path:line` at the reviewed commit.

## 1. What actually runs today

The runnable feature matches **bundle identifiers only**. Nothing in the production path checks a
signature, a code hash or a process watch.

Production path (reachable from the UI of a build of this branch; no feature flag):

1. Editor: `TriggerDraft.When.offered` always offers application opens/closes
   (`Sources/DockGroupsCore/Triggers/TriggerDraft.swift:65`). The picker checks only that the bundle
   has a regular, executable main file (`Sources/CybokronDockGroups/Support/AppPicker.swift:53-60`);
   `selectApplication` stores only the bundle identifier
   (`Sources/DockGroupsCore/Triggers/TriggerDraft.swift:237-243`).
2. Storage: the event is exactly `{kind, bundleIdentifier, edge}`; any other key decodes as
   `.unsupported` (`Sources/DockGroupsCore/Model/GroupTrigger.swift:383-396`). There is no binding
   field. Every action is allowed, including Open All and Finish
   (`Sources/DockGroupsCore/Model/GroupTrigger.swift:137`).
3. Source: `ApplicationPresenceSource` observes `NSWorkspace.runningApplications` with KVO, hops to
   the main queue, re-reads the whole list at delivery time and numbers deliveries
   (`Sources/CybokronDockGroups/Triggers/TriggerSources.swift:159-215`).
4. Counting: `ApplicationSnapshotCounter.counts` returns `[:]` (unknown) for any nil/empty identifier
   unless the session-only option is on, and matches ASCII identifiers case-insensitively
   (`Sources/DockGroupsCore/Triggers/AppPresenceTracker.swift:2-25`).
5. Lifecycle: `TriggerController.resetApplicationPresenceSource` stops the source, invalidates presence
   firings and starts a new generation on rule/group/wake/session/policy changes
   (`Sources/CybokronDockGroups/Triggers/TriggerController.swift:364-375, 400-426`).
6. Coordinator: `observeApplications` feeds `AppPresenceRuleTracker`, re-checks rule equality,
   generation and revision before and inside `receive`, and pushes invalidation on uncertainty, sleep,
   session loss and stop (`Sources/DockGroupsCore/Triggers/TriggerCoordinator.swift:151-247, 354-373`).
   Execution reuses the existing pause, budget, echo, notice and no-quit gates
   (`TriggerCoordinator.swift:456-543`).

Experimental helpers, referenced only by each other and by tests (verified with `grep` over
`Sources/`): `ApplicationCodeHash`, `ApplicationCodeRequirement`, `ApplicationRunningCodeVerifier`,
`ApplicationIdentityCount`, `MachOSliceTable`, `ApplicationStaticCodeVerifier`,
`ExperimentalProcessEventWatch`. The only junction with production types is that
`ApplicationCodeRequirement` reuses `TriggerApplicationIdentifier` for input validation. None of them
is called by the source, controller or coordinator.

## 2. Attacker and asset assumptions

- **A1: Malicious process in the same user session.** It can launch processes with any
  `CFBundleIdentifier`, `exec` in place, exit and relaunch to recycle PIDs, delay its own startup, and
  write files the user can write, including the Dock Groups data directory and any selected `.app`
  bundle the user owns. A1 can already open or quit the user's apps directly, so the trigger is not a
  privilege boundary against A1. What the design can do against A1 is avoid becoming a confused
  deputy: an action configured by the user must not be attributed to code the user did not choose.
- **A2: Separately signed look-alike app.** A different publisher, an ad hoc build or a renamed copy
  that reuses the selected app's bundle identifier, possibly installed by the user.
- **A3: Benign collisions and drift.** Beta and release builds, developer builds, app updates, a
  different architecture or Rosetta, or several instances.
- **Out of scope / not defendable:** root, kernel or Security framework compromise; an attacker that
  controls the Dock Groups process (debugger, injected library) or its configuration files; physical
  access.
- **Assets:** the user's groups and their configured actions (Start, Finish, Open All, Show Popup),
  user attention (notices), privacy of what runs on the Mac. Triggers never quit apps.

## 3. Threats

"Today" is the bundle-ID production path. "Candidate" is the locally verified binding described in the
design drafts, assuming its experimental helpers were completed and integrated. **Not achievable**
means no public, proportionate API known to this review provides the guarantee.

| # | Threat | Achievable guarantee | Verification method | Residual risk | Fail-closed behavior |
|---|--------|----------------------|---------------------|---------------|----------------------|
| T1 | Malicious app (A1/A2) presents the selected bundle ID to fire a rule | Today: none, any process with the identifier counts (observed live). Candidate: a running process counts only if fresh dynamic validation plus `identifier "<id>" and cdhash H"<hash>"` succeeds against a locally authorized hash | Today: none. Candidate: `SecCodeCopyGuestWithAttributes` + `SecCodeCheckValidity` (`ApplicationRunningCodeVerifier.swift:36-61`); tested with two thin ad hoc fixtures only | A1 can still launch the genuine app itself, so an "opened" edge caused by A1 is indistinguishable from the user's. A1 can edit the trigger file. Publisher trust is never established | Different or unverifiable code under the identifier makes that rule unknown (never a count, never a close) |
| T2 | Selected bundle path replaced or modified before verification (selection to binding) | Not achievable for path-based static checks; observed concretely (`app-presence-macho-slices.md` unresolved gates) | Candidate: bind from a running instance, not from the path; static parse is advisory only | A replacement made before the user's selection is bound as if chosen; the user confirms what was displayed, not what was hashed | Static failure, mismatch or changing results leave the rule unbound |
| T3 | Bundle modified or replaced after binding | Detectable for newly launched processes (their hash differs); a process already validated keeps its in-memory identity | Fresh dynamic lookup per candidate; static recheck cannot prove the file was never swapped | On-disk changes to resources not covered by the dynamic check, and changes between check and use | New code yields unknown; the rule waits for explicit reselection |
| T4 | Taken (spoofed) bundle ID, including case variants | Today: case-insensitive ASCII match broadens matching to case variants (`AppPresenceTracker.swift:19-21`); non-ASCII look-alikes cannot match. Candidate: signing identifier compared case-sensitively | Unit tests on the counter; requirement syntax tests | An app whose signing identifier differs from its bundle ID can never be bound (availability, not safety) | Unknown, never zero |
| T5 | PID reuse between observation, Security lookup and watch registration | **Not achievable** with public PID-based APIs: Apple's Security source marks PID lookup raceable; audit tokens for arbitrary `NSWorkspace` apps are not public without Endpoint Security | None in code; `kqueue` registration of a reaped child failed with `ESRCH` in one test (`ExperimentalProcessEventWatchTests.swift:55-63`), which does not exclude reuse | A recycled PID can be verified and watched as if it were the selected instance; the window is small but adversary-steerable by A1 | Liveness and instance equality are rechecked before and after; any disagreement is unknown. No claim of instance binding |
| T6 | `exec` inside a verified process (same PID, same `NSRunningApplication`, no list change) | Detectable only for exec events after a watch is registered; **not achievable** for exec before registration | `EVFILT_PROC NOTE_EXEC` (`ExperimentalProcessEventWatch.swift:63-149`), real exec tested only on an owned `/bin/sh` child; AppKit fixture showed no KVO change and equal instance after exec | Exec between lookup and registration; a retained `SecCode` still matches after exec | Exec, exit or any malformed/unknown event latches the watch terminal; the binding is discarded and the rule becomes unknown |
| T7 | Observation delivery delay or coalescing (KVO, main queue, kqueue) | Completeness **not achievable**: short-lived instances can be missed; ordering of deliveries is enforced by sequence numbers assigned on the main queue | Tracker rejects stale/duplicate sequences and treats gaps as uncertain (`AppPresenceRuleTracker.swift:129-158`); synthetic tests only | A missed open/close; an edge acted on after the process already changed; coalesced kqueue events | Gaps and unknown snapshots reset all baselines and drop queued, pending and notice-stage presence firings (`TriggerCoordinator.swift:166-172`) |
| T8 | Process death during verification or before action | Death can be observed after the fact; not prevented | Watch `NOTE_EXIT`; liveness recheck | An opened edge whose process died within the settle/notice window still runs unless a later snapshot invalidates it | An exit during verification is unknown; a close requires an established, verified remaining-instance count of zero |
| T9 | User confirmation race (sheet shows one candidate, binding applies to another) | Achievable only as "the binding is the exact candidate displayed", invalidated on any change; not atomic | Generation plus candidate identity on the confirmation (draft lifecycle step 4); not implemented | A1 can exec or swap between display and confirm; T5/T6 apply | Changed candidate, exec, exit, watch failure or stale generation invalidates the confirmation |
| T10 | Check-to-action race (state changes after the last check, before or during the group action) | **Not achievable**: checks and `AutomationHandling` calls are not atomic. Achievable: no action starts after an invalidation that the main actor has already processed | Main-actor serialization; `currentInvalidated` checked after notices (`TriggerCoordinator.swift:499-516`); push invalidation | An action already started is not undone. Invalidation is push-only: carry-out does not re-check tracker generation or revision, so a stop path that forgets to invalidate would let queued presence firings run | Invalidated firings are skipped; the spec forbids replay after rebaseline |
| T11 | Multiple instances or the same identifier with different code | Achievable: count only when every candidate for that identifier verifies | `ApplicationIdentityCount.count` returns nil on any `.different`/`.unknown` (`ApplicationIdentityCount.swift:17-24`) | An empty input returns 0, which is a valid close only if the caller proved snapshot completeness | Any mismatch or unknown makes the rule unknown; ambiguity at selection leaves the rule unbound |
| T12 | Watch registration failure or capacity exhaustion | Achievable: failure is reported, never treated as "no event" | Registration succeeds only with zero returned events (`ExperimentalProcessEventWatch.swift:88-96`) | One `kqueue` descriptor per watch (`ExperimentalProcessEventWatch.swift:65`) with no global limit; descriptor exhaustion is untested | Registration failure, `EINTR`, `EV_ERROR` or descriptor limits are unknown for the affected rule; partial coverage is not continued |
| T13 | Sleep, wake, fast user switching, session change | Achievable: no edge across a sleep or session gap | `willSleep`/`screensDidSleep`/session notifications stop observation and drop presence firings; wake starts a new generation (`TriggerCoordinator.swift:354-366`, `TriggerController.swift:400-417`) | Changes during sleep are lost by design; no replay | First post-wake snapshot is a baseline only |
| T14 | Legitimate app update (code hash changes) | Achievable: detection; not automatic continuity | Exact `cdhash` pin | Exact pins break on every update; a looser publisher requirement would accept other code by the same signer | Rule waits for explicit reselection; never silently re-binds or widens |
| T15 | Different architecture (universal binary, Rosetta, `arm64` vs `arm64e`) | Partially achievable: per-slice hashes via explicit file offsets on one tested OS | `MachOSliceTable` (bounded parser) plus `kSecCodeAttributeUniversalFileOffset` (`ApplicationStaticCodeVerifier.swift:50-78`) | Default static lookup can return the wrong slice; an invalid architecture name returned success in one run; Rosetta-translated processes are untested; offset honoring is not verified in code | A running slice not in the authorized set is unknown, never a close |
| T16 | Identity data from import, restore, legacy rules or edited JSON | Achievable for imports and restores: they arrive disabled (`TriggerBackupTests.swift:36-48`). Not achievable against direct edits of the local trigger file by A1 | Backup tests; strict event decoder | Today an enabled, hand-edited `applicationPresence` rule in the local file runs, because no binding exists to require. A1 can also add rules or bindings | Candidate: imported, restored and legacy rules stay disabled or unbound; imported hashes or requirement text never authorize; unknown fields keep the rule `.unsupported` |

## 4. Review findings at `c7a9f57`

Production path:

- **F1 (design, high):** the bundle-ID-only trigger is user-reachable in this branch's build with all
  actions allowed (`TriggerDraft.swift:65`, `GroupTrigger.swift:137`). This is the documented
  weakness, but nothing gates it at runtime.
- **F2 (robustness, medium):** presence firings are invalidated only by push
  (`invalidateApplicationPresenceFirings`, `TriggerCoordinator.swift:218-225`). Several paths stop the
  tracker without invalidating: `refresh()` (`:236`, `:243`), the `canAct == false` branch of
  `observeApplications` (`:161-164`) and `rulesChanged` (`:268`, which drops only changed rules'
  firings). Today the controller always calls `stopApplicationObservations()` during reset, so these
  paths are covered by caller discipline, not by the coordinator. Firings carry no generation or
  revision stamp to re-check at carry-out.
- **F3 (API seam, low):** `TriggerSignal.applicationEdge` is public and `receive(_:)` accepts it
  without `presenceValidity`, bypassing the tracker, generation and revision checks
  (`TriggerCoordinator.swift:328-330`, `TriggerEvaluator.swift:159-161`). Tests use this path
  (`TriggerCoordinatorTests.swift:696-710`).
- **F4 (UI, low):** `applicationPresenceUncertain` is set from every same-generation snapshot before
  the coordinator accepts or rejects it (`TriggerController.swift:392-396`), so a stale or rejected
  delivery can change the status line. A tracker stopped inside `refresh()` while the source still
  runs produces no visible status.
- **F5 (availability, unmeasured):** strict mode makes every application rule unknown when any running
  app lacks a bundle identifier (`AppPresenceTracker.swift:4-6`). How often this happens on real Macs
  has not been measured.
- **F6 (low):** at `sequence == .max` the source stops without notifying the coordinator
  (`TriggerSources.swift:193-196`); practically unreachable.

Experimental helpers:

- **F7:** `ApplicationStaticCodeVerifier` deduplicates hashes (`:74-77`) and does not verify that the
  requested slice offset was honored; if the platform ignored the offset, fewer hashes would be
  returned as success. Only the fixture test compares `hashes.count == slices.count`
  (`ApplicationStaticCodeSliceVerifierTests.swift:25`). This contradicts the slice contract.
- **F8:** the static helper resolves the same path three times: file size from resource values
  (`:37-41`), a prefix through a new handle (`:43-45`), then the path-based Security call (`:54-59`).
  The size is not taken from the open handle. The `.app` extension is checked before symlink
  resolution (`:16`, `:19`). `Bundle(url:)` instances are cached by Foundation (not tested here), so a
  replaced bundle could report a stale executable. Default flags are used throughout; no signature
  type, signing identifier or team is extracted.
- **F9:** `ApplicationRunningCodeVerifier` resolves code by PID (`:44-49`, raceable) and calls
  `SecCodeCheckValidity` twice (`:52-55`); the first call is redundant with the second, the two are
  not atomic, and the cost of either (possibly including on-disk validation) is unmeasured. It runs
  synchronously.
- **F10:** the `identifier` requirement compares the code-signing identifier case-sensitively, while
  presence matching is case-insensitive (`ApplicationCodeRequirement.swift:12`,
  `TriggerApplicationIdentifier.swift:35`). Injection is prevented by the identifier alphabet
  (`TriggerApplicationIdentifier.swift:18-30`).
- **F11:** `ExperimentalProcessEventWatch` has no generation or instance identity of its own (the draft
  requires one on every callback), uses one descriptor per PID with no limit, exposes the internal
  `consumePollResult` seam, is not thread-safe, and has no wake-up mechanism (poll only).

## 5. What the tests prove

| Test group | Proves | Does not prove |
|------------|--------|----------------|
| `AppPresenceTrackerTests`, `AppPresenceRuleTrackerTests` | Edge arithmetic, baselines, generation/sequence rejection, gap handling, fail-closed configuration limits | Anything about real `NSWorkspace` ordering, coalescing or completeness |
| `AppPresenceEvaluatorTests`, `TriggerCoordinatorTests` (app presence) | Existing gates apply; invalidation on uncertainty, sleep, session, rule change and reentrant state callbacks | Real timing; that every future stop path invalidates; edges are injected or synthetic |
| `TriggerControllerPresenceTests`, `ApplicationPresenceSourceTests` | Controller lifecycle with synthetic snapshots through `handleApplicationSnapshot`; token and stop behavior | Real app launches or quits. The real KVO source also runs during these tests and reads the host's app list; results rely on 50-150 ms sleeps |
| `TriggerApplicationEventCodingTests`, `TriggerBackupTests`, `TriggerDraftTests` | Strict decoding, raw preservation of unsupported data, imports disabled, session option not exported | Signed-binary downgrade with older versions; persistence of any binding (none exists) |
| `ApplicationRunningCodeVerifierTests` | Two thin, ad hoc signed `/bin/sleep` copies with the same weak designated requirement are distinguished by `cdhash`; invalid PIDs are unknown | AppKit apps, Developer ID, App Store, Apple-signed or unsigned code, universal or Rosetta processes, PID reuse, exec, timing |
| `ApplicationStaticCodeVerifierTests`, `ApplicationStaticCodeSliceVerifierTests` | Valid ad hoc bundle accepted; unsigned, plist-tampered and symlink-escaped bundles rejected; on this host's universal `/bin/sleep` one slice hash matches the running process | Offset honoring as a code property, concurrent modification, every signing type, OS versions |
| `MachOSliceTableTests` | Bounds, overlap, alignment, duplicate and malformed-header rejection, including mutated inputs | That the slices hold valid Mach-O or that Security uses them |
| `ExperimentalProcessEventWatchTests` | Real `NOTE_EXIT` and `NOTE_EXEC` for owned children; registration on a reaped child fails; interpretation of synthetic `kevent` results | That the kernel ever produces the synthetic combinations; LaunchServices apps; PID reuse; races with registration. `cannotWatchAnAlreadyReapedChild` can in principle flake if the PID is reused immediately |

`scripts/test.sh` passed at `c7a9f57` on one arm64 Mac (1783 core tests, 9 app tests).

## 6. Documentation and code mismatches

- `app-presence-trigger-spec.md:12-13` says the tracker "does not detect reordered callbacks within the
  same generation". It rejects equal or lower sequence numbers and treats gaps as uncertain
  (`AppPresenceRuleTracker.swift:133-158`). The limitation is narrower: sequence numbers reflect
  main-queue delivery order, not when macOS changed the list.
- `app-presence-macho-slices.md:24-26` requires verifying that the requested offset was honored; the
  static helper does not (F7).
- `app-presence-watch-protocol-draft.md:46-49` requires every callback to carry a generation and
  instance/watch identity and limits on watched processes; the experimental watch has neither (F11).
  That is acceptable for an unintegrated primitive but must not be read as conformance.
- `app-presence-identity-security.md:47-49` requires distinguishing unsigned, invalid, ad hoc, platform
  and developer-signed apps; no helper extracts the signature type or team (F8).
- `app-presence-trigger-spec.md:18-20` requires fixture-app tests of completeness and background
  apps; none exist in the test suite.
- `ApplicationStaticCodeVerifier.swift:4-7` says "No caching"; the helper itself does not cache, but
  `Bundle(url:)` may (F8).
- README, CHANGELOG and SECURITY state the bundle-ID limitation accurately.

## 7. Decision

### (a) Default ON is acceptable only if all of the following hold

1. Every rule has a binding established locally from an explicitly selected, running, uniquely
   verifiable instance, confirmed by the user, and stored outside any import path.
2. Every counted instance passes a fresh dynamic validity and `identifier` plus exact `cdhash` check
   against that binding, and has a successfully registered exec/exit watch.
3. A close is emitted only from a complete, fully verified snapshot whose count is zero.
4. Presence firings carry generation and revision stamps checked at carry-out, in addition to push
   invalidation.
5. The fixture matrix in the evidence docs (signing types, update, replacement, multiple instances,
   universal and Rosetta, sleep/wake, downgrade) passes on every supported macOS version with the
   packaged app.

Even then, the property is "no action attributed to unverified code that the app had already
observed", not race freedom, not publisher trust and not protection from A1.

### (b) Default OFF or unknown is required when

- Only bundle-ID matching is available: the current state. Do not ship it enabled by default, and do
  not describe it as identifying an app.
- The binding is missing, imported, restored, legacy or unverifiable; the app was updated; the running
  slice or architecture is not in the authorized set; a watch cannot be registered; the strict
  snapshot is incomplete; or verification exceeds its time bound.

### (c) Minimum safe contract for a release containing this trigger

1. No identity fact (bundle ID, path, PID, imported hash or requirement text) alone authorizes a rule.
2. Unknown is never converted to zero: no close without a verified, complete count.
3. Imported, restored and legacy application rules arrive disabled and unbound; re-selection is local.
4. Different code under the selected identifier makes the rule wait; it never re-binds or widens.
5. Exec, exit, watch failure, uncertainty, rule or session change invalidates pending and notice-stage
   presence firings; already-started actions are not undone and nothing is replayed.
6. Verification runs off the main thread with bounded work, cancellation and a timeout; timeout is
   unknown.
7. No paths, PIDs, names or signing data of other apps are logged or persisted.
8. If the product decides to keep a bundle-ID-only mode, it is off by default, labelled as unverified
   at the point of choice, and subject to the open question on allowed actions below.

If items 1-7 cannot be met, the application trigger stays out of the release. The bundle-ID-only
experimental path must not be approved silently because its downstream gates exist: those gates
limit consequences but do not establish identity.

## 8. Open questions (product decisions)

1. **Ship a bundle-ID-only mode at all?** The binding gates (T5, T6, T10) may never fully close with
   public APIs. Recommended default: no; if kept, opt-in, labelled unverified, never enabled by default.
2. **Which actions may an application trigger run?** Open All launches every app in a group and Finish
   hides the current group. Recommended default: all actions only with a verified binding; Show Popup
   only for any unverified mode.
3. **Which signing types are eligible?** Unsigned code cannot be bound; ad hoc code changes hash on
   every build. Recommended default: unsigned ineligible; ad hoc only with an exact hash and a clear
   update warning; Developer ID, App Store and Apple-signed eligible.
4. **How are updates handled?** Exact hashes break on every update; accepting the same identifier and
   team would accept other code by that signer. Recommended default: exact hashes with a
   "waiting for reselection" state; a team-based option needs its own threat model.
5. **Which architectures are authorized at selection?** Recommended default: only the verified running
   slice; another architecture or Rosetta waits for reselection.
6. **Is the residual check-to-action window acceptable, and how is it explained?** It is small on the
   main actor but cannot be closed without stronger OS support. Recommended default: keep the notice
   run mode as the default for application triggers and document the limitation in the trigger sheet.
7. **Keep the session-only identified-apps option?** It weakens closes for every application rule.
   Recommended default: keep strict as the default and decide after measuring how often unidentified
   apps occur on real Macs (F5).
