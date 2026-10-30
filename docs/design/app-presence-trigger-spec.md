# Application presence triggers — design

Status: design in progress; not shipped. This extends the deferred app-open/app-quit
decision in `triggers-spec.md` and does not change the semantics of existing triggers.

For a selected application bundle identifier, an open event is a transition from zero
running instances to at least one; a close event is a transition from one or more to
zero. Intermediate instance count changes do not fire. A window closing is not process
termination. The initial trusted observation, and the first observation after a gap,
source restart, sleep/wake or a changed/enabled rule, are baselines, not events.

The isolated tracker accepts observations in the order its caller supplies them; it
does not detect reordered callbacks within the same generation. Clearing a baseline
alone does not revoke that generation. Integration must serialize observations and
reject callbacks while stopped, and must issue a fresh generation on each restart.
Generation exhaustion permanently disables that tracker rather than reusing a token.

The candidate source is `NSWorkspace.runningApplications` observation, gated by the
presence of eligible rules. Its completeness and background-app behavior must be tested
with isolated fixture apps; coalesced or missed events are not replayed. Unknown or
inconsistent observations invalidate the baseline. Old source generations must not
change current state. No application names, paths or PIDs are recorded in diagnostics.

Events must enter the existing trigger coordinator and retain its pause, echo,
cooldown, daily and hourly budgets, confirmation, and automatic no-quit policies.
Suppressed events are consumed. Pending actions must be revalidated against current
rules and active groups. The existing unknown-reading behavior of other conditions must
not accidentally preserve an app baseline through a gap. No new action is inferred
from an untrusted bundle identifier. Imports remain disabled by default.

New event data must remain safely unsupported by older versions. Source-level tests
alone do not establish signed-binary downgrade or backup compatibility; those require
isolated copies of both versions. The feature is not ready for release until source
fixtures, UI, localization, downgrade, safety and real end-to-end gates pass.

Lock/unlock triggers, configurable delays, and replay of missed events are separate
work. No release or version bump is implied by this design.
