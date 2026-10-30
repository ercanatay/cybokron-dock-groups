import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Internal atomic file-creation-only helper for validated WindowLayoutDocument.
///
/// LIMITATIONS — read before relying:
/// - INTERNAL ONLY for creating a previously nonexistent file from a validated document.
/// - NO replacement, recovery, backups, app/UI/AX/permission/window integration.
/// - NOT protected from hostile same-user mutation or symlink traversal of earlier ancestor components.
/// - NOT cross-file / crash-transaction safe.
/// - Requires caller-supplied existing trusted parent directory (not created here).
/// - Final target never overwrites any existing file, directory or symlink.
/// - Encodes and checks 2 MiB cap BEFORE any filesystem modification.
/// - Uses openat / linkat / unlinkat with O_EXCL / O_NOFOLLOW; no shell commands.
/// - Errors are constant and never carry path or payload.
internal enum LayoutFileCreateNewError: Error, Equatable, Sendable {
    case invalidURL
    case invalidParent
    case documentTooLarge
    case parentNotOpened
    case tempCreateFailed
    case tempWriteFailed
    case tempFsyncFailed
    case tempCloseFailed
    case linkFailed
    case targetExists
    case cleanupFailedBeforePublish
    case cleanupFailedAfterPublish
}

internal enum LayoutFileCreateNew {
    static let maxBytes = 2 * 1024 * 1024

    /// Creates `url` from an already-validated `document` with atomic no-clobber publication.
    /// The parent directory must exist and be trusted by the caller; it is not created here.
    ///
    /// Writes the freshly encoded document bytes; never touches the original or replaces/deletes the target.
    /// The final target never overwrites any existing file, directory or symlink.
    /// Errors are constant and never carry path or payload.
    static func createNew(from document: WindowLayoutDocument, at url: URL, writeImpl: (Int32, UnsafeRawPointer, Int) -> Int = { Darwin.write($0,$1,$2) }, unlinkImpl: (Int32, String) -> Int32 = { fd, name in name.withCString { Darwin.unlinkat(fd, $0, 0) } }) throws {
        let (parentFd, finalName) = try Self.validatedParentFd(for: url)
        defer { _ = close(parentFd) }

        let encoded: Data
        do {
            encoded = try WindowLayoutJSONEncoder.encode(document)
        } catch WindowLayoutJSONEncoder.EncodingError.exceedsByteLimit {
            throw LayoutFileCreateNewError.documentTooLarge
        } catch {
            throw LayoutFileCreateNewError.documentTooLarge
        }

        try Self.createBytes(encoded, parentFd: parentFd, finalName: finalName, writeImpl: writeImpl, unlinkImpl: unlinkImpl)
    }

    /// Creates a new file at `url` from the exact bytes a reader previously read and validated
    /// (the snapshot's `data`), using the same atomic no-clobber creation path.
    ///
    /// Documents bytes read earlier from the snapshot; it never re-encodes and never writes to or
    /// replaces/deletes the source. The final target never overwrites any existing file, directory or symlink.
    ///
    /// LIMITATIONS — read before relying:
    /// - Writes the bytes read earlier; does not guarantee a disk snapshot or crash durability, and is
    ///   not backup management.
    /// - INTERNAL ONLY for creating a previously nonexistent file from a validated snapshot.
    /// - NO replacement, recovery, backups, app/UI/AX/permission/window integration.
    /// - Errors are constant and never carry path or payload.
    static func createNew(from snapshot: LayoutFileReader.Snapshot, at url: URL, writeImpl: (Int32, UnsafeRawPointer, Int) -> Int = { Darwin.write($0,$1,$2) }, unlinkImpl: (Int32, String) -> Int32 = { fd, name in name.withCString { Darwin.unlinkat(fd, $0, 0) } }) throws {
        let (parentFd, finalName) = try Self.validatedParentFd(for: url)
        defer { _ = close(parentFd) }

        try Self.createBytes(snapshot.data, parentFd: parentFd, finalName: finalName, writeImpl: writeImpl, unlinkImpl: unlinkImpl)
    }

    // MARK: - Private creation path

    private static func validatedParentFd(for url: URL) throws -> (parentFd: Int32, finalName: String) {
        // 1. URL validation (constant errors, no path leakage)
        guard url.isFileURL else {
            throw LayoutFileCreateNewError.invalidURL
        }
        if let host = url.host, !host.isEmpty, host.lowercased() != "localhost" {
            throw LayoutFileCreateNewError.invalidURL
        }
        let path = url.path
        guard path.hasPrefix("/") else {
            throw LayoutFileCreateNewError.invalidURL
        }
        guard !path.utf8.contains(UInt8(0)) else {
            throw LayoutFileCreateNewError.invalidURL
        }

        // 2. Final component name (validated after cap check, as per original precedence; see createBytes)
        let finalName = url.lastPathComponent

        // Parent directory must exist and be a directory (caller-supplied, trusted; not protected from traversal)
        let parentURL = url.deletingLastPathComponent()
        guard parentURL.isFileURL else {
            throw LayoutFileCreateNewError.invalidParent
        }
        let parentPath = parentURL.path
        guard !parentPath.isEmpty else {
            throw LayoutFileCreateNewError.invalidParent
        }

        let parentFd = open(parentPath, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        guard parentFd >= 0 else {
            throw LayoutFileCreateNewError.invalidParent
        }

        var parentStat = stat()
        guard fstat(parentFd, &parentStat) == 0 else {
            _ = close(parentFd)
            throw LayoutFileCreateNewError.invalidParent
        }
        guard (Int32(parentStat.st_mode) & Int32(S_IFMT)) == Int32(S_IFDIR) else {
            _ = close(parentFd)
            throw LayoutFileCreateNewError.invalidParent
        }

        return (parentFd, finalName)
    }

    private static func createBytes(_ data: Data, parentFd: Int32, finalName: String, writeImpl: (Int32, UnsafeRawPointer, Int) -> Int, unlinkImpl: (Int32, String) -> Int32) throws {
        // 1. Enforce 2 MiB cap BEFORE any filesystem modification (even temp creation); snapshot recheck is intentional.
        guard data.count <= maxBytes else {
            throw LayoutFileCreateNewError.documentTooLarge
        }

        // 2. Final component name (validated after cap check, as per original precedence)
        guard !finalName.isEmpty else { throw LayoutFileCreateNewError.invalidURL }
        if finalName == "." || finalName == ".." || finalName.contains("/") || finalName.utf8.contains(UInt8(0)) {
            throw LayoutFileCreateNewError.invalidURL
        }

        // 3. Random private temporary file in the opened parent directory
        let tempName = ".tmp.\(UUID().uuidString)"
        let tempFd = openat(parentFd, tempName, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard tempFd >= 0 else {
            throw LayoutFileCreateNewError.tempCreateFailed
        }

        // Write loop executed entirely inside withUnsafeBytes; base address used only inside closure.
        var writeFailed = false
        var written = 0
        let totalLength = data.count
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else {
                writeFailed = true
                return
            }
            while written < totalLength {
                let remaining = totalLength - written
                let n = writeImpl(tempFd, base.advanced(by: written), remaining)
                if n < 0 {
                    if errno == EINTR { continue }
                    writeFailed = true
                    return
                }
                if n == 0 {
                    writeFailed = true
                    return
                }
                if n > remaining {
                    writeFailed = true
                    return
                }
                written += n
            }
        }

        if writeFailed {
            _ = close(tempFd)
            if unlinkImpl(parentFd, tempName) < 0 {
                throw LayoutFileCreateNewError.cleanupFailedBeforePublish
            }
            throw LayoutFileCreateNewError.tempWriteFailed
        }

        if fsync(tempFd) != 0 {
            _ = close(tempFd)
            if unlinkImpl(parentFd, tempName) < 0 {
                throw LayoutFileCreateNewError.cleanupFailedBeforePublish
            }
            throw LayoutFileCreateNewError.tempFsyncFailed
        }

        if close(tempFd) != 0 {
            if unlinkImpl(parentFd, tempName) < 0 {
                throw LayoutFileCreateNewError.cleanupFailedBeforePublish
            }
            throw LayoutFileCreateNewError.tempCloseFailed
        }

        let linkRes = linkat(parentFd, tempName, parentFd, finalName, 0)
        if linkRes < 0 {
            let capturedErrno = errno
            if unlinkImpl(parentFd, tempName) < 0 {
                throw LayoutFileCreateNewError.cleanupFailedBeforePublish
            }
            if capturedErrno == EEXIST {
                throw LayoutFileCreateNewError.targetExists
            }
            throw LayoutFileCreateNewError.linkFailed
        }

        if unlinkImpl(parentFd, tempName) < 0 {
            throw LayoutFileCreateNewError.cleanupFailedAfterPublish
        }
    }
}
