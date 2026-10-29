# Draft: replacing an existing window layout file

Status: design only. This document extends the [storage safety draft](window-layout-storage-spec.md). It is not an implementation, an authorization to import, or a claim of crash-safe or multi-store transactions. The create-only writer is a separate internal primitive; it must never be used to overwrite a target.

## Scope and assumptions

A future explicit save or import may need to replace a supported, valid `layouts.json`. The candidate must be fully decoded, validated and encoded within the current limits before any destination mutation. Ordinary save and import must not reset, rename, overwrite, or delete an unreadable, corrupt, oversized, or unsupported-version original. A separate user-visible recovery design is required for those cases.

The parent directory is app-controlled and trusted. Any proposed concurrency protection must state which processes cooperate and what happens if they do not. A lock used only by cooperating writers cannot protect against hostile same-user filesystem mutation, a non-cooperating older process, or ancestor symlink traversal. Rechecking a file immediately before rename is not an atomic compare-and-swap; another process can change it between those operations. Do not claim lost-update prevention unless the actual serialization mechanism and its assumptions are verified.

## Candidate coordination to evaluate

A separate stable lock file in the trusted directory is a possible coordination point for cooperating processes; locking the replaceable layout file itself cannot be assumed to serialize access to its replacement after a rename. All participating versions would need the same lock and protocol, and must hold it from snapshot through publication and cleanup. The lock file must not be unlinked and recreated while in use, or different processes could lock different file objects. This is a candidate, not a proven implementation or protection against non-cooperating writers. Apple exposes [whether a volume supports advisory locking](https://developer.apple.com/documentation/foundation/urlresourcevalues/volumesupportsadvisoryfilelocking); unsupported or unknown capability needs a defined fail-closed behavior and tests. The local `flock(2)` manual says descriptors shared by `fork` or `dup` reference the same lock, so an explicit unlock by a child can release the parent’s lock. Lock scope, same-process thread semantics, timeout, process termination, and lock-file substitution remain to be established for the selected API and filesystem.

## Required preservation and publication properties

1. Record the exact prior bytes and their format status without exposing paths, identifiers, or content in logs or errors. The snapshot must be bounded while reading, including if the file grows. Validate the original before a normal replacement; preserve a newer or malformed original untouched.
2. Before changing the live name, create a separate recoverable copy of the prior bytes under a unique, non-overwriting name in the trusted directory. Verify the copy against the captured bytes; a name's existence or a successful copy call alone is insufficient. If creation, verification, sync, or any required directory operation fails, abort the replacement and report the stage without silently discarding the original. Specify retention, permissions, naming, storage limits, and what to do when no backup can be retained before implementing this step.
3. Write the validated candidate to a private uniquely created temporary file; handle short and interrupted writes, sync and close errors, and cleanup failures. Never truncate the live file. Publication must use a documented same-filesystem atomic replacement primitive and must not accidentally follow a final symlink. Atomic visibility of one name is not a guarantee that the data or directory entry survives power loss. Apple’s archived [`fsync(2)` manual](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fsync.2.html) describes drive buffering and power-loss limits; it does not establish the durability of a particular directory-entry protocol. Filesystem and platform support must be verified before choosing stronger sync operations.
4. Define the exact serialization and revalidation protocol for cooperating writers, including target identity changes and an absent target. If the originally observed file changes or disappears, reject with a conflict and retain a recoverable prior copy; do not retry with a new snapshot automatically. This requirement cannot be met by an unguarded check followed by rename.
5. Clearly distinguish errors before publication, after publication, and failures whose publication outcome cannot be established. After publication, never report that no change occurred merely because cleanup or sync failed. Retain evidence needed for recovery; do not delete the only verified copy or blindly roll back over a newer file.
6. Specify and test a durable recovery protocol, ordering of file and directory synchronization, and restart behavior before making any crash-durability claim. Without that protocol, report an interrupted or ambiguous operation as such. Recovery must identify and preserve original, candidate and backup data without assuming temporary files are safe to delete.

These properties address a single layout file only. Replacing layouts with groups or preferences is a separate multi-store problem: define a journal or other recovery mechanism, ordering, partial failure and rollback failure before implementation. A sequence of individually atomic renames does not provide a multi-file transaction.

## Test matrix before use

Use isolated temporary directories and synthetic data; do not exercise these cases against user stores.

- Existing valid file, empty file, malformed JSON, unsupported future schema, oversize and a file that grows during a read; verify exact prior bytes for every rejected case.
- Existing final symlink, dangling symlink, directory, absent parent, invalid URL, inaccessible file, and an unexpected target type; verify no unintended object changes.
- Backup name collision and injected failures in backup creation, short reads/writes, verification, file sync, close and directory sync. Assert the live file's bytes, retained backup and cleanup state after each failure.
- Candidate write, sync, close, publication, cleanup and post-publication sync failures, including a result where publication succeeded but cleanup failed. Assert the actual target and retained copies; do not equate a thrown error with unchanged state.
- Two cooperating writers, target changed or removed after snapshot, and a non-cooperating writer. Verify only guarantees the selected locking and publication primitives can actually provide.
- Interrupt or terminate at each documented durable boundary and restart recovery. Test retained copies and ambiguous states, including a failed or interrupted recovery. Ordinary unit tests cannot simulate every filesystem or power-loss behavior.
- Full restore/merge tests must separately cover absent versus empty layouts, group collision and orphan policy, backup failure, later store failure, rollback failure, and imported layouts remaining dormant.

Real downgrade/upgrade copies, actual user-facing recovery, AX/window identity and Space safety, multiple displays, and release review remain separate gates.
