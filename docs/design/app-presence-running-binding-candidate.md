# Application trigger: running-code binding candidate

Status: a conservative design to evaluate, not implemented or approved. It addresses the observed
bundle-identifier spoofing and selected-path replacement gaps. It does not claim a race-free
identity protocol or change the released app. See `app-presence-identity-security.md` and
`app-presence-macho-slices.md` for evidence and unresolved constraints.

## Proposed user flow

1. The user chooses an application bundle. If a matching app is not already running, explain that
   the user must open it themselves and retry. Never launch an app just to establish identity.
2. If exactly one stable, verifiable running identity can be associated with the selection, show
   the selected app and a plain-language explanation that its current code is being bound. An
   invalid, unsigned, unavailable, ambiguous or changing identity leaves the rule unbound and
   cannot run. Multiple instances with differing code for the same bundle identifier are
   ambiguous; do not guess which one the user intended.
3. Require an explicit confirmation after the binding is established. A valid code signature is
   not a promise that an app is benign or that its publisher is trustworthy. An ad hoc signed app
   may be bound only if its exact code can be verified; the user must understand that an update can
   require reselection. A code hash is an identity pin, not a reputation score.
4. A legitimate update or a different architecture may change the code hash. Do not silently
   replace or expand a binding. Keep the rule waiting and offer explicit reselection. Establishing
   a new binding must invalidate pending actions and start a new baseline without replay.
5. Imported or legacy rules have no locally authorized binding. Keep them disabled or waiting;
   never treat an imported hash, requirement expression, path, signer field or enabled flag as
   proof of local consent. Re-selection must establish a new binding locally. Decide storage,
   migration and downgrade behavior before implementation.

## Candidate verification sequence

- Treat `NSWorkspace` observations as incomplete until checked. A missing or invalid identifier,
  process lookup error, different code under the target identifier, or an unverifiable process is
  unknown for that rule, never zero. Existing identified-app-only mode, if retained, can skip
  unrelated unidentified apps only; it must not skip an unverifiable candidate for the target.
- Hold the `NSRunningApplication` instance and use Apple's instance-equality guidance rather than
  comparing PIDs alone. Capture and recheck its liveness and current rule/source generation before
  and after the Security calls. Its launch date may be unavailable and must not be required or
  treated as a universal unique token. These checks are supplementary and not atomic.
- Obtain a dynamic `SecCode` for the candidate and validate it. Generate any Security requirement
  from bounded, validated values, not arbitrary imported requirement text. Ensure the candidate
  code's verified identifier and exact code hash satisfy the binding; a designated requirement
  supplied by an app may be too weak. Recheck current rule, group, pause, observation generation,
  and cancellation before publishing a result or executing an action.
- In local tests, a dynamic requirement rejected the replacement fixture's hash after the selected
  path was swapped. The original hash's result varied across two runs. This is promising fail-closed
  behavior, not proof that a PID lookup or user selection is race-free. Determine whether public OS
  APIs expose a sufficiently strong process-lifetime token for this use; if not, do not claim
  cryptographic binding to the selected process. Avoid undocumented or private APIs.
- Do not automatically authorize every static slice of the selected path. A path can be replaced
  between parsing and Security checks. At most, a verified running slice is an experimental
  candidate; obtaining and authorizing other slices requires its own evidence and user semantics.
  An absent, replaced or different slice remains unknown, not a close.

## Release gates

A production design must resolve process/PID reuse and selection-to-confirmation races, bounded
background execution and cancellation, signed-identifier verification, local binding persistence,
update and universal-binary UX, privacy, backup/import/downgrade, disabled-rule migration, and all
existing trigger gates. Tests must include conflicting processes sharing an identifier, ad hoc and
invalid signatures, selected-path replacement, process exit/restart during verification, and
actual packaged-app UI. Supported macOS versions and user-visible Accessibility/TCC behavior need
separate verification. No requirement, hash or identity helper in the experimental branch should
be interpreted as completing these gates.

## Audit-token investigation (2026-11-01)

Apple's published Security source explicitly marks its PID-only convenience lookup as raceable
and implements an audit-token lookup through `kSecGuestAttributeAudit`. This is evidence of a
possible stronger input to Security, not a public recipe for acquiring a trustworthy audit token
for an arbitrary application chosen through `NSWorkspace`. Apple's `NSRunningApplication`
interface documents a PID and instance comparison, but does not document an audit-token property.
Do not manufacture an audit token from a PID, depend on private APIs, or infer that a token is
bound to the user's selection merely because a Security lookup accepts it.

Endpoint Security events expose an audit token, but creating a client requires an entitlement
requested from Apple and user approval for Full Disk Access; Apple's client sample also handles a
not-privileged failure. This is not a drop-in replacement for existing application observation.
Do not add Endpoint Security, a privileged helper, or additional permissions as part of this
experiment. Even if obtained, an event token would need a separately specified association with
the selected app, initial running state, event loss, confirmation, and process exit handling.

The current release gate therefore remains open: identify a supported, proportionate way to bind
the locally confirmed app selection to an actual process instance, or keep this trigger unavailable
when that association cannot be established. Failed or unavailable checks must remain unknown and
must never be translated into an application-close event.

## Primary references

- [NSRunningApplication process-identity guidance](https://developer.apple.com/documentation/appkit/nsrunningapplication/processidentifier)
- [NSRunningApplication launch-date limitation](https://developer.apple.com/documentation/appkit/nsrunningapplication/launchdate)
- [Dynamic signed-code validation](https://developer.apple.com/documentation/security/seccodecheckvalidity%28_%3A_%3A_%3A%29)
- [Guest-code attributes](https://developer.apple.com/documentation/security/guest-attribute-dictionary-keys)
- [Apple Security source: PID and audit-token lookups](https://github.com/apple-oss-distributions/Security/blob/main/OSX/libsecurity_codesigning/lib/SecCode.cpp)
- [NSRunningApplication interface](https://developer.apple.com/documentation/appkit/nsrunningapplication)
- [Endpoint Security process audit token](https://developer.apple.com/documentation/endpointsecurity/es_process_t/audit_token)
- [Endpoint Security client requirements](https://developer.apple.com/documentation/endpointsecurity/es_new_client%28_%3A_%3A%29)
- [Endpoint Security entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.endpoint-security.client)
