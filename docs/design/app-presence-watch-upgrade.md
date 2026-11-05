# Application presence: watch upgrade feasibility

Status: design and feasibility record; items 3 and 5 have since been implemented (see
"Implementation status (2026-11-05)"). The record itself approves nothing. It evaluates the
residual risks listed as "still open" in `app-presence-threat-model.md` §3.2/§3.3 (T5, T6, T10, no
wake-up, sleep/session) and in `app-presence-identity-authorization.md` ("Remaining risks"), and
proposes what to do about each one. Nothing below claims that any protocol is race-free.

Baseline: `main` at `561d03d` (0.12.0 shipped application triggers with the approval and the
running-code verifier). `ExperimentalApplicationPresenceBinder` is **not on `main`**; it exists only
on the unmerged branch `codex/app-presence-watch-binding` (`008268b`) and is referenced as such.
File references are `path:line` at `561d03d` unless marked *(binder branch)*.

Effort: **S** ≤ 1 day including tests, **M** 2–5 days, **L** more than a week or a new subsystem.
Release class: **0.12.x** = no persisted-format change, no new user-visible text (no translation
pass), internal behaviour only; **0.13** = needs new text, a protocol change across fakes, or a
product decision; **won't do** = needs a restricted entitlement or is disproportionate.

## 0. Decision summary

| # | Problem | Recommendation | Class | Effort |
|---|---------|----------------|-------|--------|
| 1 | No event wake-up | Add a `DispatchSourceRead` on each watch's existing kqueue descriptor (main queue) that only asks the verifier to re-poll and report a changed verdict. Do **not** switch to `DispatchSourceProcess` | 0.13 | M |
| 1b | Process-wide descriptor bound | Optional later step: one shared kqueue per verifier (one descriptor, `udata` = watch ID) | 0.13 / defer | M |
| 2 | Exec before registration | Re-classify in the docs (the fresh check after registration already sees post-exec code; argued, see §2) and add the missing fixture test that proves it | 0.12.x | S |
| 2b | Detect an exec between listing and registration | Optional: compare `audit_token_to_pidversion` or `ri_uuid` before and after; only turns a would-be `codeChanged` into `unavailable` | defer | M |
| 3 | PID reuse | Bracket every Security check with a (PID, kernel start time) read and store the pair per instance; re-check it on every poll | 0.12.x | S |
| 3b | Stale `NSWorkspace` entry whose PID was already reused before listing | **Not achievable** with public APIs; `launchDate` heuristic deferred | defer | M |
| 4 | Check-to-action race (T10) | Keep the existing final poll with no suspension before the handler; no fresh Security call and no TTL at action time; document the residual window. Zero is **not achievable** | 0.12.x (docs) | S |
| 4b | Long actions (Open All) | Optional cancellation between steps once wake-up exists; product decision | 0.13 / defer | M |
| 5 | Sleep / session change | Generations are sufficient for tracker and coordinator. Add: reset the verifier's entries (close watches, re-check) when the Mac can act again | 0.12.x | S |
| — | Endpoint Security (closes T5/T6 properly, could make T10 synchronous) | Restricted entitlement, system extension, user approval | won't do | L |

Highest benefit per cost: **(3) the start-time bracket** and **(5) the verifier reset on
wake/session**, both S, both 0.12.x-compatible, both removing a reliance on an assumption that is
currently untested in code. Doc correction (2) is cheaper still but changes no behaviour.

## Implementation status (2026-11-05)

| # | Item | Status |
|---|------|--------|
| 3 | (PID, kernel start time) bracket | **Implemented** in `RunningApplicationIdentityVerifier` (`ProcessIncarnation`): read at listing, after registration, right before and after the Security call (same thread), when the check finishes, and at every later question. Changed → `unavailable(processChanged)`, unreadable → `unavailable(processUnreadable)` (new abstract code 9); a check whose bracket failed is never `verified` or `codeChanged`. Tests: injected reader per position, real children (reaped child unreadable, start time kept across exec, real reader keeps an unchanged child verified). Not applied to `TriggerApplicationApprover` |
| 5 | Verifier reset on sleep/session | **Implemented**: `ApplicationIdentityVerifying.reset()` (default no-op for fakes), `TriggerCoordinator.resetApplicationIdentityVerification()`, called by `TriggerController.handleWorkspaceSignal` on both `canAct` transitions (before observations restart on the way back). Option 1 of §4.5: entries are forgotten, so the next question re-lists and re-checks (`pending`); no `unavailable` + 10 s retry. Tests: verifier, coordinator and controller seams; real sleep and fast user switching not tested |
| 2 | Exec-before-registration fixture test and doc rewording | Open |
| 4 | T10 doc wording | Open (unchanged; the bracket only adds a read to the final check) |
| 1, 1b, 2b, 3b, 4b | Wake-up, shared kqueue, pidversion, stale entry, action cancellation | Open / deferred as recommended |
| §7 | `proc_pidinfo` inside the signed, hardened app on every supported macOS | Not done (manual); a failure there reads as `processUnreadable` for every authorized rule |

## 1. Evidence gathered for this document

Local probes on one Mac: macOS 27.2 (26B123), arm64, small **unsigned, non-sandboxed, not
hardened** command-line programs run as the logged-in user. Not run inside the signed, hardened
Dock Groups app; every item marked "probe" needs to be repeated there (§7).

| ID | Observation (probe) |
|----|---------------------|
| E1 | `proc_pidinfo(pid, PROC_PIDTBSDINFO)` returns `pbi_start_tvsec/usec` for another same-user process (Finder) and fails for `launchd` (root) and for a reaped child. |
| E2 | `pbi_start_tvsec/usec` and `rusage_info_v4.ri_proc_start_abstime` (`proc_pid_rusage`) are **unchanged by `exec`**: they identify a fork incarnation, not an image. |
| E3 | `rusage_info_v4.ri_uuid` (the main executable's Mach-O `LC_UUID`) **changed** when a child exec'd from one binary into another. It would not change on an exec into the same binary, and a crafted binary can copy any UUID. |
| E4 | `struct proc_bsdinfo` in the public SDK (`sys/proc_info.h`) has **no `p_pidversion`**. The process ID version is public only through an audit token (`audit_token_to_pidversion`, `bsm/libbsm.h`, link `-lbsm`). `PROC_PIDUNIQIDENTIFIERINFO` is not in the public headers. |
| E5 | `task_name_for_pid` + `task_info(TASK_AUDIT_TOKEN)` returned an audit token for same-user processes (Finder, Dock) and a child; its pidversion **incremented by one on `exec`** (806619 → 806620). Behaviour under the hardened runtime and on other macOS versions: not verified. |
| E6 | kqueue `EVFILT_PROC` with `NOTE_EXEC \| NOTE_EXIT` on a same-user **non-child** process (parent `launchd`) delivered exec and then exit. The existing tests use owned children only. |
| E7 | A kqueue descriptor wrapped in `DispatchSource.makeReadSource` on the main queue became readable within milliseconds of each exec/exit; `kevent` with a zero timeout then returned the event. Nothing fired while idle. |
| E8 | `DispatchSource.makeProcessSource` on a non-existent PID ran its registration handler and then fired with `data == 0x80000000` (`NOTE_EXIT`): libdispatch reports a failed registration (`ESRCH`) as an **exit**, asynchronously. |
| E9 | For the 28 of 226 running applications with a `launchDate`, `launchDate − kernel start time` ranged from −0.36 s to 0.00 s (LaunchServices records the date before the process starts). One sample, no load. |
| E10 | `CLOCK_MONOTONIC_RAW` counts while asleep, `CLOCK_UPTIME_RAW` (= `mach_absolute_time`) does not (`man clock_gettime`). `ri_proc_start_abstime` is in `mach_absolute_time` units. |

Probe sources are not committed; they are short C/Swift programs and can be recreated from the
description. "Argued" below means a conclusion from these facts and the code, not a test.

## 2. Current mechanism (what the proposals build on)

- Listing: `RunningApplicationIdentityVerifier.runningInstances(of:)` reads
  `NSWorkspace.shared.runningApplications` on the main actor and returns PIDs
  (`RunningApplicationIdentityVerifier.swift:514-526`).
- New instance set: watch first (`ExperimentalProcessEventWatch(pid:)`, one close-on-exec kqueue
  per PID, registration succeeds only with zero returned events,
  `ExperimentalProcessEventWatch.swift:65-102`), poll once, then a fresh `SecCode` by PID +
  validity + `identifier`/`cdhash` requirement off the main actor with a 2 s bound
  (`RunningApplicationIdentityVerifier.swift:386-431`, `ApplicationRunningCodeVerifier.swift:36-61`,
  `BoundedSecurityCall` `:100-129`), then poll again in `finish` (`:433-463`).
- Answering: `verdict(for:)` (`:287-348`) re-lists and polls every watch **each time it is asked**.
  In `.verified`, an instance may leave with `.idle`/`.exit`; anything else is `processChanged`
  (`:319-346`). Failures schedule a retry after 10 s (`:466-502`). Limits: 16 instances per app,
  64 watches per verifier (`:223-226`).
- Who asks: `ApplicationIdentityClearance.of` calls `verdict(for:)`
  (`ApplicationIdentityAuthorization.swift:246-260`); it runs in `refresh()`
  (`TriggerCoordinator.swift:418-450`), in `observeApplications`' `currentRule`
  (`:196-252`), in `applicationPresenceCheck` (`:362-375`) at settle, before/after a notice and
  right before the handler (`:772-788`, no suspension point between the last check and
  `await run(...)`).
- Push path: the verifier calls its change handler only when a **check finishes** with another
  verdict (`:460-462`); the coordinator then saves `codeChanged`, drops firings, dismisses a
  notice and reconfigures (`TriggerCoordinator.swift:290-312`). A watch event between questions
  produces no push.
- Sleep/session: `willSleep`/`screensDidSleep`/session-resign map to `.screens(asleep:)` /
  `.session(active:)` (`Sources/CybokronDockGroups/Triggers/TriggerSources.swift:101-106`);
  on a `canAct` transition `TriggerController.handleWorkspaceSignal` stops the source and the
  tracker, and on the way back calls `resetApplicationPresenceSource()` with a new generation
  (`TriggerController.swift:401-412, 455-472`). **The verifier is not told**: its entries,
  verdicts and kqueue watches survive sleep and session changes, and `retainOnly` runs only from
  `refresh()`.
- Binder *(binder branch)*: same order (watch, poll, check, poll) but synchronous on the caller,
  with a freshness window measured on `CLOCK_MONOTONIC_RAW`, so every candidate is stale after a
  sleep longer than 5 s (`ExperimentalApplicationPresenceBinder.swift:63-66, 450-452`). The main
  verifier has no freshness window. The two disagree on whether a verified state may outlive a
  sleep; see §5.

## 3. Apple API options considered

| API | What it gives | Limits relevant here |
|-----|---------------|----------------------|
| kqueue `EVFILT_PROC` (`NOTE_EXEC`, `NOTE_EXIT`) | Exec/exit of a PID after registration, same-user non-child included (E6); events accumulate under `EV_CLEAR` until read | PID based registration; no replay of earlier events; one descriptor per kqueue (currently one kqueue per watch) |
| `DispatchSourceRead` on a kqueue fd | Wake-up when the kqueue has pending events (E7); no timers, no cost while idle | The fd must stay open until the source's cancel handler ran; the handler must not race `close()` |
| `DispatchSourceProcess` (`makeProcessSource`) | Exec/exit callbacks without own kqueue | Registration is asynchronous and a failed registration is delivered as an exit (E8): the verifier can't prove "watch active before the Security call", and `watchUnavailable` becomes indistinguishable from `exit`. Rejected |
| `proc_pidinfo(PROC_PIDTBSDINFO)` | Kernel start time (µs) of the fork incarnation for same-user PIDs (E1, E2) | **No `p_pidversion`** in the public struct (E4); unchanged by exec; PID based, each call separate |
| `proc_pid_rusage(RUSAGE_INFO_V4)` | `ri_proc_start_abstime`, `ri_uuid` (E2, E3) | `ri_uuid` is attacker-chosen metadata; same binary → same UUID |
| Audit token from `task_name_for_pid` + `TASK_AUDIT_TOKEN` | `audit_token_to_pidversion`, which changes on exec (E5); usable with `kSecGuestAttributeAudit` | Deriving it from a PID is itself raceable; the watch draft says "Do not derive an audit token from a PID" (`app-presence-watch-protocol-draft.md`, lifecycle step 2); hardened-runtime behaviour not verified |
| `NSWorkspace.runningApplications` KVO | What the source counts today (`TriggerSources.swift:177-201`) | Coalesced, main-queue delivery; no exec; no instance identity beyond `NSRunningApplication` |
| `NSRunningApplication` (`isTerminated` KVO, `launchDate`, `executableURL`, `executableArchitecture`) | Per-instance exit, LaunchServices launch date (only 28 of 226 processes had one, E9) | No exec notification; no public audit token; `launchDate` and kernel start time are not documented to correspond |
| Endpoint Security (`ES_EVENT_TYPE_NOTIFY_EXEC/EXIT`, `AUTH_EXEC`) | Audit tokens for every exec, before registration problems arise; `AUTH` could hold an exec | Requires `com.apple.developer.endpoint-security.client` (restricted), a system extension, user approval and Full Disk Access-like consent. Disproportionate for this app; **won't do** |

## 4. The five problems

### 4.1 No event wake-up

**Problem.** Watches are polled only when the coordinator asks. An exec or exit of a verified
instance is noticed at the next question (snapshot, settle, notice end, carry-out). Status lines,
notice dismissal and the 10 s retry start late; a dead process keeps its descriptor until then.

**Current state.** Poll only: `ExperimentalProcessEventWatch.poll()` (`:110-117`) called from
`verdict(for:)` (`RunningApplicationIdentityVerifier.swift:319-346`) and `finish` (`:437`). The
change handler fires only from `finish` (`:460-462`) and `retry` (`:498`).

**Options.**

1. *Read source per watch (recommended).* When a watch is created, attach a
   `DispatchSource.makeReadSource(fileDescriptor:queue: .main)` to its kqueue descriptor. The
   handler does not read the kqueue itself; it calls a main-actor `watchSignalled()` on the
   verifier, which re-runs the same poll logic as `verdict(for:)` for the affected binding and,
   if the verdict changed, calls the existing change handler (→
   `applicationIdentityVerdictsChanged()`). Requirements: cancel the source before closing the
   descriptor and close it **in the cancel handler** (libdispatch requires the fd to outlive the
   source); a token check so a source of a replaced watch can't affect a newer one; coalescing
   (the source stays readable until the event is consumed by `poll()`, which latches the watch).
2. *Shared kqueue per verifier.* One descriptor, `udata`/`ident` → watch ID, one read source,
   drain loop. Gives a real descriptor bound (the open "no global descriptor limit" item) but
   changes `ExperimentalProcessEventWatch` from "one fd, one PID, events must carry its PID" to a
   demultiplexer with `EV_DELETE` on close and stale-event filtering. More code to get wrong; only
   worth it together with a descriptor-limit requirement.
3. *`DispatchSourceProcess`.* Rejected (E8): asynchronous registration, `ESRCH` reported as exit,
   so "watch registered before the Security call" can't be established.
4. *`NSRunningApplication.isTerminated` KVO.* Exit only, no exec; adds nothing over kqueue.

**Guarantee.** Closes nothing security-relevant. Carry-out already polls right before the handler
(`TriggerCoordinator.swift:772-788`), so a wake-up cannot stop an action the final poll would not
have stopped. It changes *when* the app reacts: a notice of an invalidated firing disappears at
once, the status line updates, the retry interval starts from the event, and descriptors of dead
processes close promptly. An exit of a verified instance stays `verified` (unchanged semantics).

**Power.** An idle read source has no timer and no wake-ups (E7). Events are bounded by the number
of watched processes (≤ 64); each event costs one `kevent` call and one verdict computation on the
main actor. No measurable cost expected; not measured.

**Sleep/wake.** kqueue registrations are kernel objects tied to the descriptor and are expected to
survive sleep, with events accumulated under `EV_CLEAR`; **not verified across a real sleep** (§5,
manual test). No re-registration is needed if that holds; §4.5 proposes re-checking after wake
regardless.

**Permissions.** None beyond what kqueue already uses (same user). No entitlement.

**Testability.** Real owned child that execs/exits, wait for the handler with a bounded
expectation; descriptor count before/after (`proc_pidinfo(getpid(), PROC_PIDLISTFDS)`) to prove
close-after-cancel; synthetic double for re-entrancy (handler fires after `retainOnly` removed the
binding).

**Recommendation.** Do option 1 in **0.13** (M): it touches watch ownership and the verifier's
lifecycle, and its benefit is timeliness, not safety. Option 2 deferred until a process-wide
descriptor limit is a requirement.

### 4.2 Exec before the watch is registered

**Problem.** Between listing the PIDs and registering the watch, the process may `exec`; the
watch never reports that exec (no replay).

**Current state.** Order list → watch → poll → check → poll
(`RunningApplicationIdentityVerifier.swift:386-431`); documented as open in
`app-presence-threat-model.md` §3.2 "T6 / exec before registration" and
`app-presence-identity-authorization.md` "PID reuse and exec before the watch".

**Analysis (argued).** The Security check runs *after* registration on a freshly obtained
`SecCode` (`ApplicationRunningCodeVerifier.swift:44-55`), so it validates the image running after
any earlier exec, and every exec after registration is reported by the watch. Therefore:

- authorized code exec'd into something else before registration → the check sees the other code
  → `codeChanged` (availability: the rule waits for re-approval; equal to a look-alike, already
  accepted in the authorization doc);
- something else exec'd into the authorized binary before registration → the check passes; that
  is "the authorized code is running", which is the same as A1 launching the genuine app (T1
  residual, outside the defendable boundary).

So the miss affects attribution (the `NSRunningApplication` entry may describe the pre-exec
program) but not the property "every listed instance runs the authorized code now". This rests
on one untested premise: that a **fresh** `SecCodeCopyGuestWithAttributes` by PID after an exec
describes the new image (the threat model only established that a *retained* `SecCode` still
matches after exec, T6). That premise needs a fixture test before the docs are changed.

**Options.**

- *Start time (`pbi_start_*`).* Does not help: unchanged by exec (E2).
- *`p_pidversion` via `proc_pidinfo`.* Does not exist publicly (E4).
- *pidversion via audit token (E5)* or *`ri_uuid` (E3)*, read at listing and again after the
  check: detects an exec between listing and the end of the check. `ri_uuid` misses exec into
  the same binary (harmless for identity) and is attacker-chosen (only usable to *downgrade* to
  unknown). The audit-token route conflicts with the draft's rule against deriving tokens from
  PIDs and is unverified under the hardened runtime.

**Guarantee.** The doc correction closes nothing new; it states precisely what is already true.
The optional pidversion/UUID comparison only changes a `codeChanged` caused by an exec in that
window into `unavailable` (retry instead of re-approval). An exec before the listing itself stays
invisible to every public API (**not achievable**; ES would be needed).

**Cost / permissions / testability.** Test: S, uses the existing ad hoc fixtures
(`ApplicationRunningCodeVerifierTests.swift:62-81`): spawn fixture A paused, exec into fixture B,
then `compare` against B's hash must match and against A's must be `different`. pidversion read:
M (Mach port handling, hardened-runtime verification on the packaged app).

**Recommendation.** 0.12.x (S): add the fixture test; if it passes, update the threat model T6 row
and §3.2/§3.3 "exec before registration" to "affects attribution only". Defer 2b.

### 4.3 PID reuse

**Problem.** Listing, registration and the Security lookup each name the process by PID. A PID
recycled in between makes the verifier watch and check a different process as if it were the
listed instance.

**Current state.** No incarnation identity is stored; `Entry` holds PIDs and watches only
(`RunningApplicationIdentityVerifier.swift:245-253`). After registration, reuse requires an exit,
which the watch reports (`:319-346`), so the open window is from listing to registration
(threat model §3.2 "T5").

**Note on `p_pidversion`.** The task premise was `proc_pidinfo(PROC_PIDTBSDINFO)` with
`p_pidversion`; the public struct has no such field (E4). The available incarnation key is
`(pid, pbi_start_tvsec, pbi_start_tvusec)`; the pidversion is available only via an audit token.

**Options and guarantee.**

1. *Start-time bracket (recommended).* Read `(pid, start)` when listing (T0), right after
   registration (T1) and after the Security call returns (T2); require all three equal and store
   the pair in `Entry`. Re-read it on every poll in `verdict(for:)`. Because a PID can only be
   reused after its incarnation exited, and a later incarnation always has a later start time,
   equal readings at T0 and T2 mean **the same fork incarnation existed throughout [T0, T2]**
   (argued; microsecond resolution is far finer than process creation). This closes reuse between
   listing and the end of the check without relying on the watch, and is a cheap second line
   behind the watch afterwards. A failed read is `unavailable(.processChanged)`, never a match.
2. *Triple (PID, start time, cdhash).* Start time names the incarnation, cdhash the code; neither
   names the **image** (exec keeps the start time, E2). With the watch registered before the check
   (§4.2) the triple is sufficient for "the process watched from T1 is the one checked and its code
   matched". It is **not** sufficient to tie that incarnation to the `NSRunningApplication` entry:
   if the listed app had already died and its PID was reused *before* T0, all three readings agree
   on the new process.
3. *Stale `NSWorkspace` entry (reuse before T0).* No public API returns an audit token or start
   time for an `NSRunningApplication`. Heuristics: `launchDate` must precede the kernel start by at
   most a tolerance (E9: ≤ 0.36 s, one unloaded sample, only LaunchServices launches) or
   `proc_pidpath` must equal `executableURL` (spoofable, so only usable to downgrade to unknown).
   Both may misfire under load; **not achievable** as a guarantee. Consequence today: a recycled PID
   whose new owner is other code is reported as `codeChanged`, i.e. a false "needs re-approval".
   PIDs wrap only after the whole PID range was used, so this is rare benignly but steerable by A1
   (which can already force re-approval with a look-alike).
4. *Audit token pinned at T1, then `kSecGuestAttributeAudit`.* Pins the Security check to the exact
   image (pidversion). Adds little over the watch + bracket, conflicts with the draft rule, and is
   unverified under the hardened runtime. Defer.

**Cost.** Option 1: S. One syscall per read, µs; an internal reader protocol for injection; a new
internal reason is not needed (`processChanged` fits). No persisted-format or UI change.

**Permissions.** Same-user `proc_pidinfo` works without entitlements in the probe (E1); must be
confirmed in the signed, hardened app.

**Testability.** Injected reader returning changed start times at T0/T1/T2/poll → unit tests for
each position. Real: owned child, read, kill and reap, read again must fail. Forcing a real PID
reuse requires cycling through the PID range (tens of thousands of forks): stress/manual only, not
in CI.

**Recommendation.** Option 1 in **0.12.x** (S). Options 3–4 deferred.

### 4.4 Check-to-action race (T10)

**Problem.** The last verdict check and the group action are not atomic; an exec or exit after the
final check, or during the action, is not caught, and an action already started is not undone.

**Current state.** The final check is `applicationPresenceCheck` at
`TriggerCoordinator.swift:772-787` → `ApplicationIdentityClearance.of` → `verdict(for:)`, which
polls every watch synchronously on the main actor; `await run(...)` follows with no suspension
point in between (`:788`). The handler's work (start, finish, open all, popup) then runs and may
suspend.

**Window.** From the final `kevent` poll to the moment the action takes effect: microseconds to
the first effect, plus the whole duration of a long action (Open All launches items one after
another). An event the kernel has not yet queued when the final poll runs is also in the window;
exactly where in the exec path the knote is posted relative to the new image running was **not
verified**.

**Measures and how much they narrow it.**

| Measure | Narrows T10? | Cost | Verdict |
|---------|--------------|------|---------|
| Final poll with no suspension before the handler | Already in place; the window starts at that poll | — | keep |
| Fresh Security check at action time | No: it is asynchronous (≤ 2 s), so a poll must follow it anyway and the window still starts at the last poll; it would only add detection of code that became invalid without exec | Adds latency to every action; more uncancellable Security calls | don't |
| Short TTL / periodic re-verification | No: the window is between the last poll and the action, not between verifications | CPU and Security calls per instance per TTL | don't (but see §4.5 for a re-check after wake) |
| Start-time re-read at the final check (§4.3) | Only as defence in depth if a watch failed silently; µs | S (comes with §4.3) | yes, via §4.3 |
| Wake-up (§4.1) | No for the start of an action; enables the next row | M | 0.13 |
| Cancelling a long action between steps when an invalidation arrives | Shrinks "the whole action" to "the current step" | Needs a cancellation channel through `AutomationHandling`; a half-opened group is a product question | defer, product decision |

**Zero is not achievable.** No public API performs "act only if this process is still the
verified image" atomically, kernel events are queued asynchronously relative to the main actor,
and the action's effect (opening a group) is not tied to the observed process at all. Only
Endpoint Security `AUTH` events could hold the observed process's exec while acting, which needs
the restricted entitlement and a system extension (**won't do**). The achievable property stays:
no action starts after an invalidation the main actor has already processed (threat model T10).

**Recommendation.** No code change for T10 itself; 0.12.x (S, docs): state the window as "from the
final poll before the handler to the action's effect, including the action's own duration".

### 4.5 Sleep and session change

**Problem.** Is the generation model enough across sleep, wake and fast user switching?

**Current state.** Tracker and coordinator: yes. A `canAct` transition stops the source and the
tracker and drops presence firings; returning starts a new generation whose first snapshot is a
baseline (`TriggerController.swift:401-412, 455-472`; `TriggerCoordinator.swift:175-182`; threat
model T13). The verifier is outside this model: its entries and `verified` verdicts survive sleep
and session changes because nothing resets them (§2).

**Is that unsafe?** Argued: probably not, *if* kqueue registrations survive sleep and accumulate
events (an exec or exit during sleep or dark wake would then be read at the first post-wake poll,
and PID reuse requires an exit, which the watch would report). That assumption is **not tested**.
A Security check in flight across a sleep times out (the bound uses `Task.sleep`, a continuous
clock) and becomes `unavailable` → retry: fail-closed.

**Options.**

1. *Reset the verifier when the Mac can act again (recommended).* On the `canAct` false → true
   transition (the same place `resetApplicationPresenceSource()` is called), drop all verifier
   entries: cancel checks, close watches, so every authorized binding is re-listed, re-watched and
   re-checked. Effect: authorized rules answer `pending` for one check after wake; since the first
   post-wake snapshot is a baseline anyway, no edge is lost that the current design would act on,
   and a firing whose check is still running waits one extra settle (existing behaviour,
   `app-presence-identity-authorization.md` Gates 5). Removes reliance on the kqueue-across-sleep
   assumption and refreshes code validity once per wake. Needs a `reset()` on
   `ApplicationIdentityVerifying` (fakes updated).
2. *TTL on the monotonic clock as in the binder.* Equivalent effect, but also expires verdicts
   while awake for no security gain (§4.4). Not recommended for the main verifier.
3. *Nothing, plus a manual test.* Acceptable if the manual sleep test passes, but leaves an
   undocumented dependency.

**Guarantee.** Option 1: no verified state outlives a sleep or session gap, matching the draft's
"session change … invalidates" (lifecycle step 6). It does not recover events during sleep (lost
by design, T13).

**Cost / permissions / testability.** S, no permissions. Unit: `handleWorkspaceSignal(.screens(…))`
/ `.session(…)` seam with the real verifier and fake watches → watches closed, next verdict
`pending`. Real sleep/dark wake and fast user switching: manual only.

**Recommendation.** Option 1 in **0.12.x** (S). Separately, run the manual kqueue-across-sleep test
once to document the platform behaviour.

## 5. Contradictions with existing documents

- `app-presence-threat-model.md` T6 row and §3.2/§3.3 "T6 / exec before registration", and
  `app-presence-identity-authorization.md` "PID reuse and exec before the watch": after the §4.2
  fixture test passes, re-word to "exec before registration affects attribution only; the fresh
  check after registration sees the post-exec code". Until then they stay as they are.
- Same documents, "T5 / PID reuse": after §4.3 lands, narrow to "reuse before the PIDs are listed
  (stale `NSWorkspace` entry) is not detected; it can make the rule wait for re-approval".
- `app-presence-watch-protocol-draft.md` lifecycle step 2 ("Do not derive an audit token from a
  PID") stands; options 2b and 4.3-4 would need that rule revisited first. This document does not
  recommend them.
- Binder branch: `ExperimentalApplicationPresenceBinder` uses a 5 s freshness window on
  `CLOCK_MONOTONIC_RAW` (stale after every sleep) and a synchronous Security call; the main
  verifier has neither. Before the binder branch is merged, decide which model is the reference;
  its draft section ("Experimental implementation status") and its threat-model edit (helpers
  "None of them is called by the source, controller or coordinator") predate the verifier now on
  `main` and must be rebased onto `main`'s wording.
- "No wake-up" (threat model §3.2/§3.3, authorization doc) remains accurate until §4.1 lands; it
  should then say that wake-up affects timeliness only, not the T10 window.

## 6. What stays structurally open

These are **not achievable** with public, proportionate APIs, whatever is implemented above:

- T10: the window from the final poll to the action's effect, including the action's duration.
- T5 before listing: an `NSRunningApplication` whose PID was reused before the verifier read the
  list; no public per-instance audit token or start time exists.
- An exec before the listing: invisible (attribution only, per §4.2, once the test confirms it).
- Uncancellable Security calls: a time-out stops waiting only (unchanged; not addressed here).
- Short-lived instances and coalesced `NSWorkspace` deliveries (T7).
- A1 launching the genuine app or editing `triggers.json` (outside the boundary, §2 of the threat
  model).

## 7. Test strategy

| Scenario | Tool | CI? |
|----------|------|-----|
| Fresh `SecCode` after exec describes the new image (§4.2) | Subprocess: ad hoc fixture A exec's into fixture B (existing `makeSignedBundle` helper); `compare` against both hashes | yes |
| Start-time bracket at T0/T1/T2/poll (§4.3) | Injection: fake incarnation reader returning changed or missing start times | yes |
| Start time unreadable after reap (§4.3) | Subprocess: owned child, kill + `waitpid`, read fails | yes |
| Real PID reuse | Stress: cycle the PID range with short-lived children until a target PID recurs | no (manual, slow, may flake) |
| Wake-up handler fires on exec/exit of a non-child (§4.1) | Subprocess via `sh -c 'sleep …; exec …'` reparented to `launchd`, bounded expectation | yes, with generous timeout |
| Read source cancelled before fd close; no fd leak (§4.1) | Real: count own descriptors with `PROC_PIDLISTFDS` before/after `retainOnly([])` | yes |
| Stale read-source callback after a watch was replaced (§4.1) | Injection: fake watch + manual trigger of the handler | yes |
| Verifier reset on `canAct` transition (§4.5) | Injection through `TriggerController.handleWorkspaceSignal` with fake watches | yes |
| kqueue registration and pending events survive real sleep / dark wake | Manual: watch a process, `pmset sleepnow`, exec/exit it via SSH or a scheduled job, wake, poll | no |
| Fast user switching | Manual: second account | no |
| T10 residual (action runs if the change lands after the final poll) | Injection: fake verifier that changes verdict inside the handler; documents, does not close | yes |
| `DispatchSourceProcess` reports `ESRCH` as exit (E8) | One-off probe, kept in this document | no |
| All `proc_pidinfo` / `proc_pid_rusage` / kqueue / (optional) `task_name_for_pid` reads inside the signed, hardened, notarized app on every supported macOS and both architectures | Manual with the packaged app | no |
| Descriptor exhaustion | Subprocess with lowered `RLIMIT_NOFILE`; must read as `watchUnavailable` | possible, deferred |
