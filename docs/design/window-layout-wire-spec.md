# Draft: layout document wire format

Status: proposed, not implemented or released. Read with [storage and import safety](window-layout-storage-spec.md) and the [window layouts design](window-layouts-and-cli-spec.md). This proposal does not authorize moving windows or close the AX, identity, Space, permission, or manual test gates.

## Version 1 envelope

A separate local UTF-8 JSON document holds one record per group UUID. A group has one or more app records; each record stores a bundle identifier, relative frame and the capture display's visible-frame dimensions in points. Example values are illustrative:

```json
{
  "formatVersion": 1,
  "groups": [
    {
      "id": "12345678-1234-1234-1234-123456789abc",
      "windows": [
        {
          "bundleIdentifier": "com.example.App",
          "display": { "width": 1920, "height": 1080 },
          "frame": { "x": -0.1, "y": 0.1, "width": 0.8, "height": 0.6 }
        }
      ]
    }
  ]
}
```

The example is data, not an implementation or a live file. UUIDs identify groups, not windows; dimensions are matching hints, not physical display identities. Coordinates and dimensions are finite numbers; normalized frame coordinates refer to the capture display's visible frame. The file contains no titles, document paths, URLs, screenshots, process IDs or AX objects.

## Bounded decoding and encoding

- Proposed maximum encoded document size: **2 MiB** (2 × 1024 × 1024 bytes). Reject larger input before decoding and bound the read to at most the cap plus one byte even if a file grows during reading. Apply the same cap to already-loaded data and to output before any write. Never silently truncate a document to meet it.
- Version 1 accepts at most 256 groups, at most 64 windows per group, and bundle identifiers no longer than 255 Swift characters **and** 1,020 UTF-8 bytes. Display dimensions use the provisional 1…100,000 point range per axis. Geometry and case-insensitive duplicate-app checks follow the in-memory validator. These count limits do not guarantee that every otherwise valid document fits 2 MiB: encoding must reject an oversized candidate, retain the old data, and give the user a useful explanation. The existing Capture byte-limit difference remains to be resolved before integration.
- The enclosing settings backup remains subject to its existing 5 MiB total cap; a 2 MiB layout payload does not imply the whole backup will fit. Export and import must check the whole backup and avoid partial output; existing backups without layouts remain distinguishable from one explicitly carrying an empty layout list. Actual restore and merge semantics remain subject to the storage safety design and failure-recovery implementation.
- Reject invalid UTF-8, malformed JSON, nonfinite numbers, unknown format versions, missing required fields, unknown keys, duplicate object keys at every level, duplicate group UUIDs, duplicate per-group app identities and invalid field values. Compare JSON object keys after escape decoding: for example `"id"` and `"\u0069d"` are duplicate keys. Reject malformed Unicode escape pairs rather than allowing parser-dependent interpretations. Unknown fields require a new format version; older readers must preserve the original newer file and refuse to overwrite it.
- A standard `JSONDecoder` alone is not sufficient evidence that duplicate object keys were rejected. The implementation must use a parser that enforces this rule or a separately tested, bounded validation pass that correctly handles strings, escapes, surrogate pairs and nesting. Do not use a regex to recognize JSON. Bound parser nesting and resource usage before decoding; never log untrusted keys, values or paths.
- Validate a complete candidate before any save or backup restore. A failed validation or failed preservation leaves existing data intact; an unsupported newer version is not reset or moved aside merely because it is newer. Exact multi-store recovery remains an implementation gate; atomic replacement of each separate file is not a transaction.

## Required checks before implementation is integrated

Test round trips and boundaries, including zero groups, maximum counts, the byte limit and one byte over, input growth during bounded read, invalid UTF-8 and escapes, escaped duplicate keys, deeply nested input, unsupported versions, nonfinite/overflowing numbers, duplicate identifiers, path-like identifiers, geometric edge cases and refusal to leak raw data in errors. Exercise oversized output with an existing file to prove it remains unchanged. Test settings backups both below and above their separate 5 MiB total limit. Verify old-version downgrade and later upgrade on disposable copies, plus multi-store failure and crash recovery, before claiming compatibility.
