# Application Presence Triggers Implementation Plan

**Goal:** Add opt-in app-open and app-close rules with first-instance/last-instance semantics.

**Architecture:** Observe only while needed, translate reliable observations to per-rule edges,
and pass them through the existing trigger coordinator. The pure edge tracker keeps ephemeral
baselines and fails closed on observation gaps or stale generations.

**Tech Stack:** Swift 6, AppKit, Swift Testing, SwiftPM and Xcode.

**Spec:** `docs/design/app-presence-trigger-spec.md` and `docs/design/triggers-spec.md`.

## Global Constraints

- Preserve existing trigger behavior, no-quit automation, import sanitization and data compatibility.
- Never replay missed app events; never log app identities or process information.
- No production release until isolated live-source, UI and downgrade gates are complete.

## Review Focus

- Unknown or discontinuous readings must invalidate the previous baseline.
- 0→1 and 1→0 are edges; 1→2 and 2→1 are not.
- Stale callbacks and rule changes cannot manufacture an event.
- Suppression consumes an observed edge and cannot replay it later.
- Old versions must not execute the new event; source-only tests cannot prove binary compatibility.

## Tasks

- [x] Implement and test an isolated pure presence transition tracker: baseline, counts, unknown,
      reset and obsolete generations. No runtime source, persistence or UI in this step.
- [ ] Exercise the proposed source using isolated normal and LSUIElement fixture apps, including
      lifecycle and missed-event limits, without collecting user application metadata.
- [ ] Add validated event serialization and disabled import compatibility tests; document downgrade limits.
- [ ] Integrate source lifecycle, rule rebaseline and existing coordinator gates with targeted tests.
- [ ] Add application picker, localization and accessible descriptions; test only isolated fixture data.
- [ ] Run full SwiftPM and Xcode checks, review safety and complete real manual/downgrade gates.
