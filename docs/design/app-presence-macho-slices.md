# Application identity: bounded Mach-O slice discovery candidate

Status: experimental, not integrated, and not sufficient to authenticate a process. The identity
threat model and its release gates are in `app-presence-identity-security.md`.

A local test using one signed universal fixture found that
`kSecCodeAttributeUniversalFileOffset` selected each of its three recorded slices; two invalid
offsets failed. A thin fixture accepted offset zero and rejected two invalid offsets. These are
observations on one macOS version, not a guarantee for arbitrary files or future OS versions.
The SDK's `mach-o/fat.h` documents big-endian fat headers and 32- and 64-bit slice records.

## Candidate parsing contract

- Inspect only a bounded prefix from a user-selected app's main executable. Support at most 16
  slices and at most 520 header bytes. Reject missing, truncated, unsupported, inconsistent or
  oversized metadata. Fail closed rather than guess whether a slice exists.
- For fat headers, parse big-endian 32- and 64-bit records. Validate table length against both the
  prefix and the independently obtained file length. Reject empty slices, arithmetic overflow,
  slices intersecting the header or each other, out-of-file slices, invalid alignment, duplicate
  architecture/subarchitecture pairs, and a nonzero reserved field in a 64-bit record.
- Treat a recognized thin Mach-O as one candidate at offset zero only after checking its minimum
  header length; reject unknown formats. Parsing is not signature validation or authorization.
- If later used, create and validate a Security framework code object for **each** exact slice
  offset, bound the number of checks, deduplicate hashes, and fail the entire selected identity
  closed if any required slice cannot be confirmed. Verify the platform actually honored the
  requested offset; do not assume that creating a code object means the requested slice was used.
- Compare running signed code against the authorized set of exact hashes; a missing, mismatched or
  unverifiable process must not yield a false close. Imported identity data cannot authorize a
  rule. No app launch, trigger action or user-data collection is part of this parser.

## Unresolved gates

The Security APIs take a path, not the already-open file descriptor used for parsing. In a local
fixture experiment, after the original executable header was read through an open file handle, the
selected bundle path was replaced with a different signed fixture. The subsequent path-based
Security check returned the replacement's code hash; the original fixture remained separately
preserved. This is a concrete selection-to-check race, not merely a hypothetical one. Rechecking
path, file metadata or hashes cannot by itself prove that the file was never replaced or modified
between operations. Symbolic links, network volumes, app updates, architecture aliases, OS
compatibility, process/PID lifetime, asynchronous cancellation, unknown signatures, and malformed
or adversarial files require separate evidence and a fail-closed design. This parser must not be
wired into production monitoring solely because its unit tests pass.
