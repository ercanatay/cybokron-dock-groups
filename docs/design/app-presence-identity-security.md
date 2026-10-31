# Application presence: process identity threat model

Status: investigation and candidate design; not implemented or approved for release. The current
private application-presence branch matches `NSRunningApplication.bundleIdentifier` only. A
valid-looking bundle identifier is not an authenticated publisher or executable.

## Observed boundary

An independently built, ad hoc signed fixture with the same bundle identifier as the selected
fixture was counted as the selected app in a live local observation. This can cause a configured
rule to fire when another process supplies that identifier. It cannot select a new action: the
existing group, action, no-quit policy, pause, notice, cooldown, and budget gates still apply.
Imported triggers remain disabled. Those protections reduce consequences but do not authenticate
the observed process. Short-lived events can also be missed independently of identity.

In a separate, local two-process experiment, a designated requirement obtained from the selected
ad hoc fixture was checked against each running fixture using `SecCodeCopyGuestWithAttributes` and
`SecCodeCheckValidity`: the selected fixture matched and the different one did not. This was one
Mac, two task-owned ad hoc bundles, and one requirement. It does not establish publisher trust,
release compatibility, PID-reuse safety, or behavior for every signing type and app update.
Extracting a designated requirement alone does **not** validate a signature.

A second fixture used an explicitly weak designated requirement containing only the bundle
identifier. Both different ad hoc signed processes satisfied that same requirement in a dynamic
check. In this setup, blindly pinning an app-provided designated requirement does not prevent
impersonation. A further local experiment first validated the selected static fixture, obtained
its `kSecCodeInfoUnique` code-directory hash, and built a `cdhash` requirement. The selected
running fixture passed and the other one failed, even though their weak designated requirements
and bundle identifiers matched. This shows a possible narrower binding for these fixtures; it
is not a proof of publisher identity, collision resistance, architecture coverage, or race safety.
A separate static check accepted a valid ad hoc fixture and rejected copies whose signature was
removed or whose sealed bundle metadata was changed. The invalid fixtures were not launched;
this does not establish behavior for every signature, platform or process state.

A local universal-binary fixture exposed an additional blocker: the hash returned by the default
static-code lookup differed from the hash of the same executable while it was running. Explicit
architecture attributes for `arm64` and `arm64e` matched that process in this particular run;
other requested architectures did not. This is one OS and one fixture, not a portable algorithm
for enumerating slices or choosing the correct one. In another run with this fixture, a deliberately
invalid architecture name returned success and the default slice rather than failing; API success
alone therefore did not prove that the requested architecture existed. A single default static
hash is not sufficient as the identity of a universal application. Until validated architecture handling is
designed, this mismatch must remain unknown and must not be treated as evidence of a close.

## Candidate: locally verified binding

1. On an explicit application selection, examine the selected bundle's signature and derive a
   bounded identity binding using platform-supported code-signing APIs. Display what the binding
   means and handle unsigned, invalid, ad hoc, platform, and developer-signed apps separately.
   A valid signature alone is not a trusted publisher, and an app-supplied designated requirement
   alone must not be assumed sufficiently restrictive. Do not execute the selected bundle.
2. For each matching running process, validate the running code against that binding before using
   it in a presence count. A different identity with the same bundle identifier must not trigger
   the rule and makes that app's observation unknown: it might be a legitimate update, so do not
   infer a close from the mismatch. An unavailable, timed-out, ambiguous, or otherwise
   unverifiable reading is also unknown, never evidence that the selected app closed. Do not
   record other apps' paths, PIDs, names, or signing data in logs.
3. Handle process exit, PID reuse, app replacement, cancellation, timeouts, and callbacks racing
   with rule edits. Do not assume a PID, path, a prior on-disk check, or a signature string makes
   the read and action atomic. Apple's SDK warns that static validation is secure only without
   concurrent modification, and that unclean paths containing embedded `//` or `/../` can
   misconstrue a bundle; the experimental static helper does not yet establish either guarantee.
   A completed verification must still pass current-rule, source
   generation, active-group, pause and pending-action checks.
4. Do not trust identity bindings or arbitrary requirements supplied in backups or edited JSON.
   Imported rules stay off; they need a locally established binding before they can run. Older
   rules lacking a binding should remain safely disabled or waiting until explicitly reselected.
   Reject oversized or malformed identity data, preserve unknown fields according to the downgrade
   policy, and test migration and restore before changing the file format.
5. Plan an explicit update/reselection path. Pinning an exact code-directory hash may reject
   legitimate updates or a different architecture of the same app, while using a looser
   publisher/identifier requirement may accept other code by that publisher. Explain the tradeoff and fail closed when the selected binding cannot be verified.
   A user-selected exception, if ever considered, needs a separate threat model and clear warning.

## Evidence needed before implementation or release

- Repeat on supported macOS versions with Apple-signed, Developer ID, App Store, ad hoc and
  unsigned fixtures; verify actual static and dynamic signature checks separately.
- Test different executables with the same identifier, invalid and modified signatures, a
  different signer, a legitimate update, replacement while running, process exit/PID reuse,
  permission/error/timeout cases, and multiple instances with mixed outcomes.
- Measure cost without blocking the main thread and demonstrate cancellation and bounded work.
  Do not assume a signature query is fast or available for every process.
- Test new-rule selection, edits, backup/import, downgrade, archived groups, sleep/wake,
  session-only monitoring changes, and pending notices through the actual app. Verify no replay
  on rebaseline and no action after a rule or binding is revoked.
- Decide and document how trust anchors and publisher changes are presented to users; an OS-valid
  signature is not, by itself, a guarantee that the program is benign.

The current branch remains unreleased. A requirement check is a candidate mitigation, not a claim
that all spoofing or time-of-check/time-of-use races can be eliminated.

## Apple references

- [Guest attributes, including PID and audit-token keys](https://developer.apple.com/documentation/security/guest-attribute-dictionary-keys)
- [Obtaining a code object for a guest process](https://developer.apple.com/documentation/security/seccodecopyguestwithattributes%28_%3A_%3A_%3A_%3A%29)
- [Validating running signed code against a requirement](https://developer.apple.com/documentation/security/seccodecheckvalidity%28_%3A_%3A_%3A%29)
- [Designated requirements and the fact that retrieving one does not validate a signature](https://developer.apple.com/documentation/security/seccodecopydesignatedrequirement%28_%3A_%3A_%3A%29)
- [Signing-information dictionary keys](https://developer.apple.com/documentation/security/signing-information-dictionary-keys)
