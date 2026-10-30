import Foundation

/// Internal unintegrated create-only verified-copy helper for trusted existing parent and cooperating writers.
///
/// TRUST LIMITATIONS — not a backup policy or crash transaction:
/// - Only cooperating writers that also acquire the advisory exclusive lock.
/// - Source can change by a non-cooperating actor at any time.
/// - Ancestor symlink traversal exclusions apply; no protection against hostile same-user mutation.
/// - No crash durability; not a whole-store transaction mechanism.
/// - No naming, retention, delete, import, UI, AX, permission, window, or real-app integration.
/// - Byte equality (`Data == Data`) is only a readback observation, not a disk-persistence guarantee.
/// - Errors are constant cases and never embed the file URL, path, name, or raw data.
internal enum LayoutVerifiedCopyError: Error, Equatable, Sendable {
    case invalidURL
    case sourceMissing
    case sourceRead(LayoutFileReaderError)
    case lock(LayoutFileCoordinationError)
    case creation(LayoutFileCreateNewError)
    case creationUnknown
    case verificationFailed
}

internal enum LayoutVerifiedCopy {
    /// Verified copy: read source snapshot, create target from snapshot, read target back, and require byte equality.
    /// Rejects invalid URLs, query/fragment, different parents, identical paths, reserved lock filenames, or remote/relative/NUL paths before opening the lock.
    /// Holds the exclusive lock over all three operations. Never deletes source or target on failure; a published target may remain.
    static func copy(
        from source: URL,
        to target: URL,
        create: (LayoutFileReader.Snapshot, URL) throws -> Void = { try LayoutFileCreateNew.createNew(from: $0, at: $1) }
    ) throws {
        // Pre-lock validation: reject invalid/non-file/remote/relative/NUL URLs, query/fragment,
        // different standardized parent paths, identical standardized paths,
        // or either filename .window-layout.lock with invalidURL.
        func reject(_ url: URL) -> Bool {
            guard url.isFileURL else { return true }
            if let host = url.host, !host.isEmpty, host.lowercased() != "localhost" { return true }
            let path = url.path
            guard path.hasPrefix("/") else { return true }
            guard !path.utf8.contains(UInt8(0)) else { return true }
            if url.query != nil || url.fragment != nil { return true }
            if url.lastPathComponent == ".window-layout.lock" { return true }
            return false
        }
        guard !reject(source) else { throw LayoutVerifiedCopyError.invalidURL }
        guard !reject(target) else { throw LayoutVerifiedCopyError.invalidURL }

        let sourceStd = source.standardizedFileURL
        let targetStd = target.standardizedFileURL
        guard sourceStd != targetStd else { throw LayoutVerifiedCopyError.invalidURL }

        let sourceParent = sourceStd.deletingLastPathComponent()
        let targetParent = targetStd.deletingLastPathComponent()
        guard sourceParent == targetParent else { throw LayoutVerifiedCopyError.invalidURL }

        // Hold exclusive advisory lock over the shared parent for all three operations.
        do {
            try LayoutFileCoordination.withExclusiveLock(in: sourceParent) { () -> Void in
                // (1) Read source snapshot.
                let sourceSnapshot: LayoutFileReader.Snapshot
                do {
                    if let snap = try LayoutFileReader.readSnapshot(from: source) {
                        sourceSnapshot = snap
                    } else {
                        throw LayoutVerifiedCopyError.sourceMissing
                    }
                } catch let error as LayoutFileReaderError {
                    throw LayoutVerifiedCopyError.sourceRead(error)
                }

                // (2) Create target; preserve cleanupFailedAfterPublish; unknown errors constant.
                do {
                    try create(sourceSnapshot, target)
                } catch let error as LayoutFileCreateNewError {
                    throw LayoutVerifiedCopyError.creation(error)
                } catch {
                    throw LayoutVerifiedCopyError.creationUnknown
                }

                // (3) Read target again; require non-nil and exact byte equality with source.
                do {
                    guard let targetSnapshot = try LayoutFileReader.readSnapshot(from: target) else {
                        throw LayoutVerifiedCopyError.verificationFailed
                    }
                    guard targetSnapshot.data == sourceSnapshot.data else {
                        throw LayoutVerifiedCopyError.verificationFailed
                    }
                } catch let error as LayoutVerifiedCopyError {
                    throw error
                } catch {
                    throw LayoutVerifiedCopyError.verificationFailed
                }
            }
        } catch let error as LayoutFileCoordinationError {
            throw LayoutVerifiedCopyError.lock(error)
        }
    }
}
