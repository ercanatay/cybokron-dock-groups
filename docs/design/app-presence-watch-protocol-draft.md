# Application-presence watch protocol: security draft

Status: research draft, not implemented or approved for release. This document specifies a
candidate fail-closed protocol for discussion and testing; it does not establish a race-free
binding or change the currently runnable bundle-ID-only experimental feature. See
`app-presence-running-binding-candidate.md` for empirical results and source links.

## Intended security property and boundary

An automatic group action must not be attributed to a different app merely because it presents
the same bundle identifier. A locally confirmed rule binds a verified running code identity to the
selected app. Invalid, missing, ambiguous, stale, or unverifiable information produces **unknown**,
never a synthetic close. The group action must still satisfy the existing pause, group, budget,
echo, and user-notice gates.

This is not a promise that a signed app is benign, protection against an attacker controlling the
user's session or the Dock Groups process, or a guarantee that no short-lived event is missed.
The precise attacker boundary and acceptable residual check-to-action race remain release decisions.

## Candidate lifecycle

1. **Unbound.** A selected bundle path and identifier are hints, not consent to a process identity.
   Legacy, imported, and restored rules remain disabled or waiting until independently rebound on
   this Mac. Never run an app solely to create a binding.
2. **Establishing.** Find the candidate running instance and register a bounded process watch before
   accepting it. A failed watch registration, app exit, identity ambiguity, invalid signature, or
   unavailable observation immediately returns to unknown. Do not derive an audit token from a PID.
3. **Verifying.** Validate fresh dynamic signed code and a bounded identifier plus exact running
   code hash; associate the result with the held app instance and this watch generation. Recheck
   liveness, the same active rule and generation, and pending process events. A watch registered
   after exec cannot tell us about the earlier exec, and none of these checks is atomic.
4. **Awaiting confirmation.** Show the selected app and explain the bound code and update/reselection
   behavior. On exec, exit, watch failure, changed selection, app ambiguity, changed rule, or
   stale generation, discard this candidate and invalidate the confirmation. A completed sheet
   cannot authorize a newer candidate than the one displayed.
5. **Bound and observing.** Store only locally authorized, bounded identity fields according to a
   separately reviewed persistence format. Start with a fresh baseline; do not replay earlier events.
   A new candidate instance needs its own watch and verification against the authorized identity.
   Different or unverifiable code under the same identifier produces unknown, not a trusted count.
6. **Invalidated.** Accepted uncertainty, exec, exit, watcher failure, rule change, session change,
   or superseding generation invalidates affected pending and notice-stage app firings. Do not undo
   an action that has already started. An ordinary observed exit can contribute to a close event
   only after the remaining-instance state is established with equivalent confidence; watcher
   failure or a missing instance alone is not proof of a close.

Every callback carries an immutable generation and instance/watch identity; stale callbacks cannot
invalidate or authorize a later watch. No event callback alone establishes trust. Limit watched
processes and pending work, close descriptors on all paths, and handle observer resource exhaustion
as unknown rather than continuing with partial coverage.

## Open decisions and evidence needed

- A PID-based watch and a separate Security lookup do not identify an instance atomically. Specify
  how registration, instance comparison, signature validation and event draining relate, including
  PID reuse and exec before registration. Provide a defensible residual threat boundary; do not call
  the result race-free without evidence.
- A delayed exec event may arrive after the last check and before a group action. State what guarantee
  is feasible for local adversaries, how a pending notice is invalidated, and what happens once an
  action has already begun. Avoid inventing a guarantee that asynchronous callbacks cannot provide.
- Decide which code identity fields are pinned, where local consent is persisted, how new versions
  and architecture slices require reauthorization, and how backups, imports, downgrade and corrupted
  or attacker-modified state behave. A code hash does not authenticate the publisher.
- Check that all candidate instances are covered, including multiple identical IDs, rapid exits,
  overlapping launches, coalesced notifications, missing bundle identifiers, resource exhaustion,
  and the app's identified-only session option. Unknown must not become zero on a last-instance close.
- Test real signed fixtures and negative cases on each supported macOS architecture/version and with
  the actual distributed app. Verify resource cleanup, generation races, user-facing wording and
  localizations, accessibility and permissions. No extra system entitlement or Full Disk Access is
  part of this draft.

Until these decisions and tests are complete, keep the implementation experimental and exclude the
application-presence feature from an intermediate release.
