# "Run what was missed" (catch-up) for application and lock triggers — design

Status: design / feasibility only. Nothing here is implemented, and nothing here approves a
release or a version bump. Written against `main` at `7030c76`.

Related: [triggers-spec.md](triggers-spec.md) §1.9 (gates), §1.10 (missed times, edges while the
app wasn't open), [app-presence-trigger-spec.md](app-presence-trigger-spec.md) (baselines,
generations), [app-presence-session-lock-trigger.md](app-presence-session-lock-trigger.md) (TS-11,
lock revision), [trigger-delay.md](trigger-delay.md) (cancellation matrix),
[app-presence-threat-model.md](app-presence-threat-model.md) (T5, T6, T7, T13),
[app-presence-watch-upgrade.md](app-presence-watch-upgrade.md) (verifier reset on wake),
[app-presence-identity-authorization.md](app-presence-identity-authorization.md) (clearance).

"Argued" means a conclusion from the code and the documents, not a test. "Not verified" means
nobody observed it on a real Mac.

## 1. Problem and scope

### 1.1 What exists today

- **Times** already catch up: an occurrence that passed while the Mac or the screens slept, the
  session was inactive or the app wasn't open runs if it is at most 30 minutes late
  (`TriggerEvaluator.catchUpWindow`); later it is recorded `missed` (triggers spec §1.10). This
  document does not change that.
- **Display / network conditions** already have a form of catch-up: their last known reading is
  kept in `trigger-state.json` (`TriggerState.Entry.condition`) across sleep and launches, and the
  first settled reading afterwards is compared with it, so "joined the office Wi-Fi since the app
  last looked" runs once (triggers spec §1.10, TS-6).
- **Application opens/closes** do not: every gap (source start, rule change, sleep/wake, session
  change, verdict change, uncertain snapshot, sequence gap) clears every baseline, and the first
  trusted snapshot afterwards is a baseline, never an edge (`AppPresenceRuleTracker`,
  app-presence spec; threat model T7, T13).
- **Screen lock/unlock** do not: `willSleep`, `sessionDidResignActive` and stopping the source
  make the reading `nil`; after the wake the undocumented session key only sets a baseline and
  "never fires anything itself" (session-lock doc §3.2).

### 1.2 When an application or lock event is missed

| Gap | App open/close | Lock/unlock | Can the app see anything during it? |
| --- | --- | --- | --- |
| System sleep (`willSleep` … `didWake`) | missed: tracker stopped, verifier reset | the lock reading is `nil`; a lock right before sleep is dropped as stale (session-lock §3.4) | no |
| Display sleep only (Mac awake) | missed: `canAct` is false, the tracker is stopped by policy | lock edges are still seen (Finish runs while displays sleep) | yes, but app observation is switched off on purpose |
| Inactive session (fast user switching) | missed: tracker stopped | reading `nil`; another session's lock is never ours | AppKit keeps running; app observation is switched off |
| Dock Groups not running (quit, crashed, before login item) | missed | missed | no |
| Before the source was registered for the rule (rule just added / turned on / group restored / approval changed) | missed by design: "turning one on never runs something that happened before" (`TriggerEvaluator` doc comment) | the same | n/a |
| Watch or observation trouble (uncertain snapshot, sequence gap, verifier `unavailable` / `codeChanged`, observations restarted after a verdict change) | missed: baselines reset, firings dropped or recorded `applicationNotConfirmed` | n/a | yes, but the reading is unknown |
| Short-lived or coalesced instances while observing (T7) | missed, invisibly | n/a | no (KVO coalesces) |

### 1.3 Where catch-up could make sense

- **App open / close after a bounded, explicit gap** (sleep, display sleep, inactive session):
  the gap has a known start and end, the app was observing before it and observes again after it.
  This is the only case this document proposes to cover (§4).
- **App open / close while Dock Groups was not running:** feasible in the same shape as conditions,
  but needs a persisted reading; deferred (§5.6, decision D4).
- **Watch / uncertainty gaps:** not covered at first (§5.5, decision D5).
- **Lock / unlock:** not proposed (§4.4): the only post-gap source is undocumented, and the design
  contract that a baseline never fires would be broken.
- **Short-lived instances (T7):** not recoverable by any option here.
- **Per-trigger delays:** unchanged; a catch-up firing is accepted, then waits its delay like any
  other, and the cancellation matrix applies (§5.4).

## 2. Definitions

- **Trusted reading** (per application rule): the instance count of an accepted, non-uncertain
  snapshot of the current generation, reduced to *running* (≥ 1) or *not running* (0). For an
  authorized rule it is trusted only once `ApplicationIdentityClearance` is `allActions` for that
  snapshot (verdict `verified`), and *not running* only from a complete snapshot (no instance under
  the identifier; the existing close rule).
- **Baseline:** the first trusted reading of a generation. Today it is compared with nothing.
- **Gap:** the interval in which the tracker was stopped because the Mac couldn't act (§1.2 rows
  1–3). It has a start (`canAct` true → false) and an end (the first trusted reading after
  `canAct` false → true).
- **Missed event (this document):** a difference between the **last trusted reading before a gap**
  and the **first trusted reading after it**, for the same rule, unchanged in every field
  (`GroupTrigger` equality, as `ApplicationPresenceStamp.rule`), in a group still active. It is a
  *net change* ("Safari is running now and wasn't when the Mac went to sleep"), not an event with a
  known time. Several open/close pairs during the gap collapse into zero or one net change.
- **Difference from a baseline:** a baseline is "first reading, nothing to compare with"; a missed
  event exists only when there **is** a trusted pre-gap reading of the same rule. Rules without one
  (new, changed, turned on, re-approved, group restored, policy option changed) behave exactly as
  today.
- **Unknown is never 0 / closed (kept):** an uncertain or uncleared reading on either side of the
  gap means no comparison and no missed event; an unknown pre-gap reading is not "not running", an
  unknown post-gap reading is not "closed". Catch-up never weakens `ApplicationSnapshotCounter`'s
  `[:]` = unknown rule, and never treats a missing key as 0.

## 3. Signal sources after a wake: what is reliable

| Information | Source | Reliable? |
| --- | --- | --- |
| Which apps run now, by bundle identifier | `NSWorkspace.runningApplications` (current KVO source, re-read at delivery) | as reliable as today's snapshot; subject to F5 (unidentified apps make it unknown in strict mode) |
| Whether the running code under an authorized identifier is the approved code | `RunningApplicationIdentityVerifier` after its reset (`pending` → `verified`) | yes, with the residuals of the threat model (T5 before listing, T6 attribution, T10) |
| Whether the selected app was running before the gap | the last trusted reading kept in memory | yes, if kept in memory only (§6.3); a value read from a file is not |
| When the gap started and ended | `TriggerCoordinator` sees `.screens(asleep:)` / `.session(active:)` with `clock()` | approximately: wall clock (`Date`), can jump with clock changes; the evaluator's 30-minute window has the same weakness |
| Whether the app quit and relaunched during the gap | nothing public | **not achievable**: same count before and after hides a restart. `NSRunningApplication.launchDate` exists only for some processes (E9 in watch-upgrade: 28 of 226) and is not documented to match the kernel start time; using it would be a heuristic |
| When during the gap the app opened/closed | nothing public | **not achievable** (unified log parsing and Endpoint Security are disproportionate / restricted; see watch-upgrade §3) |
| Whether the instance running now is the one that was running before (same incarnation) | (PID, start time) pairs were not kept across the reset | not needed for net-change semantics; not offered |
| Lock state after wake | undocumented `CGSSessionScreenIsLocked` | baseline only, by contract (session-lock §3.2) |
| Lock/unlock that happened during sleep | nothing | **not verified** whether `com.apple.screenIsLocked` arrives before sleep, after wake or both (session-lock §1.2) |

What cannot be guaranteed whatever is chosen:

- An exec in an instance before it was listed after the wake (T6, attribution only).
- A PID reused before listing (T5 before listing): reads as the new process.
- Opens and closes during the gap that cancel out (open-then-quit, quit-then-relaunch).
- Anything while Dock Groups wasn't running, unless a persisted reading is added (§5.6).
- Any lock or unlock during system sleep.

## 4. Options and recommendation

### 4.1 Option A — do nothing (status quo, documented)

- **Guarantee:** a gap never produces an action. Easy to explain: "Dock Groups only sees changes
  while the Mac is awake and it is open."
- **Complexity:** none (docs only).
- **False positives:** none added.
- **Cost to users:** "When Xcode opens, start Work" doesn't run if Xcode was launched as a login
  item before the screens woke, or reopened by macOS after a wake.

### 4.2 Option B — net-change synthesis across bounded gaps (recommended, app triggers only)

When the Mac stops being able to act, keep in memory, per eligible rule, the last trusted reading
and the rule value it was read under. After the gap, the first trusted reading of the new
generation is compared with it (instead of being only a baseline):

| before | after | result |
| --- | --- | --- |
| none / unknown | anything | baseline (today's behaviour) |
| not running | running | one **opens** firing for rules with edge `.starts` |
| running | not running | one **closes** firing for rules with edge `.ends` |
| same | same | nothing (a restart during the gap is invisible) |
| anything | unknown / uncleared | nothing yet; the kept reading waits (bounded, §5.1) |

- **Guarantee:** at most one firing per rule per gap, and only for a net change between two
  trusted readings of the same rule; nothing about events inside the gap.
- **Complexity:** M. The tracker today owns baselines per generation and drops them on every stop;
  the kept reading must live outside the generation (coordinator, keyed by rule ID and rule value),
  be consumed exactly once, and be dropped on every invalidation that today means "fresh baseline"
  (§5.5). The rest — settle, reducer, gates, delay, notice, stamp checks — is reused through
  `receive(.applicationEdge…, presence:)` with a stamp of the **new** generation.
- **False-positive risk:** low and bounded:
  - The app was opened *by Dock Groups itself* right after the wake (a When the Screens Wake
    trigger's Open All) before the first trusted post-wake snapshot was taken: the net change would
    be attributed to the gap. Mitigation: the comparison is void when any automatic action started
    since the gap ended (the echo window already marks it: `environment.echoUntil`), and the
    synthesized firing is an edge, so the 15-second echo window applies anyway.
  - The user opened the app during the gap on another path (it is still a real "opened since").
  - A1 launches the app during the gap: no different from A1 launching it while awake.
- **Consistency:** this is what conditions already do across sleep and launches (§1.1), so the
  product behaves the same for "display connected since" and "app running since".

### 4.3 Option C — replay individual events

Record or reconstruct every open/close during the gap and feed them through the evaluator in order.

- **Guarantee:** none achievable: during system sleep and while the app isn't running nothing
  observes; during display sleep / inactive session the source could keep observing, but replaying
  a queue of past edges later contradicts the delay and lock designs, where every such gap
  **cancels** pending firings (`trigger-delay.md` §2: "The screens slept … or woke → cancelled").
- **Complexity:** L (event log, ordering, deduplication, a persisted queue for the not-running case,
  a history source that doesn't exist publicly).
- **False-positive risk:** high: stale edges acted on minutes later, after the state already
  reverted (an "opened" whose app has already quit), several Starts competing; the reducer would hide
  most of them anyway (one Start wins), so the extra machinery buys little.
- **Verdict:** rejected. It also conflicts with the app-presence spec ("coalesced or missed events are
  not replayed") and with threat-model §7(c) item 5 ("nothing is replayed").

### 4.4 Option D (lock/unlock) — synthesize from the session key after wake

Compare the pre-sleep lock reading with the post-wake `CGSSessionScreenIsLocked` and synthesize a
lock or unlock.

- Breaks the TS-11 contract that the undocumented key "decides what the next notification is
  compared with and never fires anything itself" and its consequence "a wrong baseline can only turn
  the next real notification into a missed one, never into an extra run".
- Little value: after a display-sleep wake on a locked screen the user's unlock already fires
  (session-lock §3.4); a synthesized "locked during sleep" would run a Finish that hides apps nobody
  can see.
- **Verdict:** rejected; lock/unlock keep "no catch-up". Revisit only if a documented lock signal
  appears.

### 4.5 Recommendation

**Option B for application open/close triggers, only for sleep / display-sleep / inactive-session
gaps, in memory only, opt-in per trigger (decision D1); Option A (no catch-up) for lock/unlock and
for every other gap.** Reasons:

1. It is the only option whose guarantee can be stated truthfully with public APIs ("it was not
   running before the Mac slept and is running now").
2. It reuses every existing gate and the generation/revision stamp, so the security argument of the
   threat model stays intact: the firing is created from a trusted reading of the current
   generation, not from history.
3. It matches the existing condition behaviour instead of inventing a third semantics.
4. Keeping the reading in memory keeps `trigger-state.json` from becoming a way to make an
   application trigger run (§6.3).

## 5. Limits

### 5.1 Bounds

- **Per rule:** at most one catch-up firing per gap (net change). The kept reading is consumed by
  the first trusted post-gap reading or dropped; it is never compared twice.
- **Per wake:** at most **3** catch-up firings enter the settle window (decision D3); the rest are
  recorded as missed (below). The reducer (§1.8 of the triggers spec) then keeps at most one Start,
  each Finish once, each Open All once, one Show the Popup.
- **Gap length:** only gaps of at most **30 minutes** (`TriggerEvaluator.catchUpWindow`, the same
  constant as times; decision D2). Longer: no firing; the rule records
  `missed(.macAsleep / .sessionInactive)` with the gap's end as `lastOutcomeAt`, so the row says why.
- **Waiting for a trusted reading:** the kept reading waits at most the settle plus the verifier's
  first check after the reset (bounded by its 2 s Security bound and 10 s retry); proposal: drop it
  if no trusted reading arrives within **60 s** of the gap's end (decision D3). Not measured.
- **Budget:** a catch-up firing counts toward the 12-per-hour budget like any run.

### 5.2 Cooldown, once a day, pause, echo

All gates apply unchanged and in the same order (`TriggerEvaluator.gate`): a trigger that ran less
than 60 s before (e.g. right before the sleep) is skipped `cooldown`; At most once a day holds; a
paused trigger is skipped `paused` and **not** run after the pause; the synthesized firing is an
edge, so the echo window applies. What a gate stops is recorded and never run later.

### 5.3 Visibility and "never run something silently"

- A catch-up firing never uses Run Right Away: Open All, Start and Finish always show the 5-second
  notice (Ask First stays Ask First); Show the Popup is its own notice. Decision D6.
- Notice and last-run texts say it happened during the gap, e.g. "Starting “Work” — Xcode opened
  while the Mac was asleep" and "Last ran today at 9:00 (after the Mac woke): started “Work”."
  New keys, English-only first (as `trigger-delay.md` §5). Exact wording: decision D7.
- The editor shows the option with a note that only a change between before and after the gap is
  seen ("If Xcode quits and opens again while the Mac sleeps, nothing runs").
- Logs: the existing `Logger(subsystem: "com.cybokron.dockgroups", category: "Triggers")` with
  trigger IDs only, never names, paths, PIDs or bundle identifiers (app-presence spec, threat model
  §7(c) item 7).

### 5.4 Interaction with delays

The catch-up firing is accepted in the new generation, then waits its `delaySeconds` like any
other. Every row of the cancellation matrix applies; in particular a new sleep or a new generation
during the wait cancels it (`cancelledBeforeRun`). The delay doesn't start before the trusted
post-gap reading exists.

### 5.5 What drops the kept reading (fail closed)

Any of these discards the kept reading for the affected rule(s), so the next trusted reading is a
plain baseline:

- the rule changed in any field, was turned off, deleted, or can't run; its group archived or
  deleted; its authorization changed (approved, re-approved, `needsReapproval`, `invalid`);
- the session-only "identified apps only" option changed (`cancelApplicationPresenceForPolicyChange`);
- an uncertain snapshot or a sequence gap *before the gap started* (the reading isn't trusted);
- a verifier verdict other than `verified` for an authorized rule at the time of the pre-gap
  reading (`awaitingVerification`, `none`);
- Dock Groups quits (memory only);
- the tracker's generation or revision counters are exhausted;
- the gap was longer than the bound (§5.1), or no trusted post-gap reading within its wait.

Uncertainty *after* the gap doesn't drop it at once (the first post-wake snapshot may be uncertain
while apps relaunch), but the wait is bounded (§5.1).

### 5.6 Not covered (deferred)

- **The app wasn't running.** Would need the reading in `trigger-state.json` (§6.3), a gap start
  (the last time the app observed, not just the last reading) and a downgrade analysis (older
  versions read the state leniently; an unknown field is dropped on their next save — expected, not
  verified for this field). Decision D4.
- **Watch / uncertainty gaps while awake** (F5 strict mode, verifier `unavailable` and retry,
  observation restarts after a verdict change). Feasible later with the same rule (net change
  between two trusted readings), but those gaps have no explicit, bounded start and can flap,
  turning a noisy environment into repeated firings. Decision D5.

## 6. Security

### 6.1 Identity

- **Authorized rules:** a catch-up firing exists only if both the pre-gap reading and the post-gap
  reading were cleared with `allActions` (verified code). After the wake the verifier has been
  reset (`resetApplicationIdentityVerification`), so the post-gap side is a fresh check; the firing
  carries the new generation's `ApplicationPresenceStamp` and goes through the same
  `applicationPresenceCheck` at settle, before the notice, after the delay and right before the
  handler. A `pending` verdict makes it wait; `codeChanged` / `unavailable` drops it (recorded
  `applicationNotConfirmed`). No identity fact from before the gap is reused.
- **Unverified (bundle-ID-only) rules:** **no catch-up** by default (decision D8). They run only
  Show the Popup while awake; a reading from before the gap can't be tied to any code, and the
  look-alike risk (T1) is the same on both sides.
- `needsReapproval` / `invalid` rules can't run, so no catch-up.

### 6.2 Lock/unlock

No catch-up: the only post-gap source is the undocumented session key, which by contract is a
baseline only (§4.4). Same-user spoofing of the distributed notifications (session-lock §1.3) is
unchanged; catch-up adds no new way to inject a lock edge.

### 6.3 Abuse of replay and of stored readings

- No event queue exists, so there is nothing to replay or to inject into.
- The kept reading is memory only. A file-backed reading would let A1 (same user) write
  "not running" for a rule so the next real reading makes an "opened" edge. A1 is out of the
  defendable boundary (threat model §2) and can launch the app itself, but the state file would then
  carry a value that makes a trigger run.
  *Mismatch found:* `TriggerState`'s doc comment says "A crafted file can at most pause triggers or
  make occurrences count as handled: nothing in it makes a trigger run", but `Entry.condition` is
  already read from the file (`TriggerState.swift`, `decodeLeniently(Int.self, forKey: .condition)`)
  and compared with the next real reading, so a crafted condition value can turn a real display or
  network reading into an edge (argued from code, not tested). The comment should be narrowed
  ("…nothing in it makes a trigger run without a real reading that differs from it") whatever is
  decided here; D4 must account for it.
- The 3-per-wake bound, the reducer, cooldown and budget limit how many actions any sequence of
  gaps can cause; repeated sleep/wake is bounded by the cooldown (one run per minute per trigger)
  and the 12-per-hour budget.

## 7. Test strategy

| Scenario | How | CI? |
| --- | --- | --- |
| Net-change table (§4.2) per edge kind, incl. unknown on either side | Core: `AppPresenceRuleTracker` / coordinator with fake clock, synthetic snapshots, `.screens(asleep:)` / `.session(active:)` signals | yes |
| Kept reading dropped by each §5.5 cause | Core, one test per cause | yes |
| Gap longer than 30 min → `missed`, no firing; boundary at exactly 30 min | Core, fake clock | yes |
| Per-wake cap, reducer with several catch-up firings | Core | yes |
| Cooldown, once a day, pause, echo, budget on catch-up firings | Core | yes |
| Run Right Away forced to the notice; Ask First kept | Core with the fake notice presenter | yes |
| Delay after catch-up, cancelled by a second sleep / new generation | Core, fake sleeper (`TriggerDelayTests` pattern) | yes |
| Authorized rule: pre-gap `verified`, post-gap `pending` → waits; → `verified` runs; → `codeChanged` / `unavailable` drops and records | Core with a fake verifier | yes |
| Unverified rule: no catch-up | Core | yes |
| Wake-trigger Open All launching the app before the first snapshot → no catch-up | Core: echo window set before the first post-gap snapshot | yes |
| Controller: `handleWorkspaceSignal` ordering (reset verifier, keep reading, restart source) | App target seams (`TriggerControllerPresenceTests` pattern) | yes |
| Real system sleep (`pmset sleepnow`) with a fixture app launched during sleep (scheduled job / SSH) | Manual, own fixture apps only | no |
| Real display sleep (`pmset displaysleepnow`), fixture app opened/quit while displays sleep | Manual | no |
| Fast user switching | Manual, second account | no |
| Lid close, dark wake, Power Nap, apps relaunched by macOS at wake ("Reopen windows") | Manual; **not verified** whether relaunched apps appear before or after the first post-wake snapshot | no |
| Open-and-quit or quit-and-relaunch during the gap | Can't be detected: documented, a test only asserts "nothing runs" | yes (synthetic) |
| Exec/PID reuse before listing after wake | Not testable meaningfully; covered by threat model T5/T6 | no |

Manual gates to add to `10_MANUEL_TEST_KAPILARI.md` when implemented: the three real-sleep rows
above, plus "lock/unlock: nothing runs after the wake for a lock during sleep".

## 8. Open decisions

| # | Decision | Recommended default |
| --- | --- | --- |
| D1 | Catch-up on by default or a per-trigger option ("Also when it happened while the Mac slept")? | Per-trigger option, **off** by default; imports and backups keep it but the trigger arrives off as always |
| D2 | Longest gap that still catches up | 30 minutes (same as times) |
| D3 | Per-wake cap and the wait for a trusted post-gap reading | 3 firings per wake; 60 s wait |
| D4 | Cover "Dock Groups wasn't running" with a persisted reading | No, not in the first release; revisit after the manual tests of §7 and a state-file review (§6.3) |
| D5 | Cover watch / uncertainty gaps while awake | No |
| D6 | Force a notice for catch-up firings set to Run Right Away | Yes (Show the Popup excepted) |
| D7 | Wording of notice / last-run texts | "…while the Mac was asleep" / "…while another user was using the Mac" / "(after the Mac woke)", English only first |
| D8 | Catch-up for unverified (bundle-ID-only, Show Popup only) rules | No |
| D9 | Lock/unlock catch-up | No (documented as not supported) |
| D10 | Which edge kinds: opens, closes, both | Both, each only for its own trigger edge; Finish on a close stays "current group only" |

## 9. Rough plan

Effort: **S** ≤ 1 day incl. tests, **M** 2–5 days, **L** more than a week.

| Order | Slice | Effort |
| --- | --- | --- |
| 0 | Docs only: link this file from the app-presence spec (replace "replay of missed events is still to be designed") and from `trigger-delay.md` / session-lock §7 ("Next: run what was missed"); state "lock/unlock: no catch-up"; narrow the `TriggerState` doc comment (§6.3) | S |
| 1 | Product decisions D1–D10 | — |
| 2 | Core: kept reading per rule across `canAct` gaps in the coordinator, net-change comparison on the first trusted post-gap reading, all §5.5 drops, bounds of §5.1, `missed` outcome; tests of §7 (core rows) | M |
| 3 | Core: authorized-rule path with the reset verifier (`awaitingVerification` wait, drops), echo-window void rule, forced notice | M |
| 4 | Model + UI: per-trigger option (top-level field written only when on, like `delaySeconds`; older versions drop it on save — same risk as `trigger-delay.md` §3), editor row and note, notice and last-run texts, English-only keys | M |
| 5 | Manual gates with own fixture apps (real sleep, display sleep, fast user switching, relaunch at wake) | S–M |
| later | D4 (app not running, persisted reading) or D5 (awake gaps), each with its own review | L |

## 10. Documents to update if this is adopted

- `app-presence-trigger-spec.md`: "The initial trusted observation, and the first observation after
  a gap, source restart, sleep/wake … are baselines, not events" and "coalesced or missed events are
  not replayed" — keep the second sentence; the first becomes "…are baselines, except the net change
  of §4.2 of `app-presence-catch-up.md` for triggers with the option on".
- `app-presence-threat-model.md` T13 ("Changes during sleep are lost by design; no replay") and
  §7(c) item 5 ("nothing is replayed"): add "a net change between two trusted readings across a
  bounded sleep gap may run once; no event is replayed".
- Info pack `24_TETIKLEYICI_012_TASARIM_ADAYI.md` ("uyku/uyanma … sonra ilk güvenilir anlık görüntü
  sadece başlangıç durumudur; kaçırılmış olay olarak çalıştırılmaz"): the same exception, if D1 is
  accepted.
- `triggers-spec.md` §1.10: add a line for application triggers next to the condition rule.
- No change to `trigger-delay.md` §2 or the session-lock doc beyond the link in slice 0.
