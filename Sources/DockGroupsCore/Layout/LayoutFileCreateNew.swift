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
    static func createNew(from document: WindowLayoutDocument, at url: URL, writeImpl: (Int32, UnsafeRawPointer, Int) -> Int = { Darwin.write($0,$1,$2) }, unlinkImpl: (Int32, String) -> Int32 = { fd, name in name.withCString { Darwin.unlinkat(fd, $0, 0) } }) throws {
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

        // 2. Parent directory must exist and be a directory (caller-supplied, trusted; not protected from traversal)
        let parentURL = url.deletingLastPathComponent()
        guard parentURL.isFileURL else {
            throw LayoutFileCreateNewError.invalidParent
        }
        let parentPath = parentURL.path
        guard !parentPath.isEmpty else {
            throw LayoutFileCreateNewError.invalidParent
        }

        // Open parent directory with O_DIRECTORY | O_NOFOLLOW to reduce symlink-traversal risk of parent itself
        let parentFd = open(parentPath, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        guard parentFd >= 0 else {
            throw LayoutFileCreateNewError.invalidParent
        }
        defer {
            // Parent fd is only used for openat/linkat/unlinkat; close at end.
            _ = close(parentFd)
        }

        // Verify parent is a directory via fstat (defense in depth)
        var parentStat = stat()
        guard fstat(parentFd, &parentStat) == 0 else {
            throw LayoutFileCreateNewError.invalidParent
        }
        guard (Int32(parentStat.st_mode) & Int32(S_IFMT)) == Int32(S_IFDIR) else {
            throw LayoutFileCreateNewError.invalidParent
        }

        // 3. Encode and enforce 2 MiB cap BEFORE any filesystem modification (even temp creation)
        let encoded: Data
        do {
            encoded = try WindowLayoutJSONEncoder.encode(document)
        } catch WindowLayoutJSONEncoder.EncodingError.exceedsByteLimit {
            throw LayoutFileCreateNewError.documentTooLarge
        } catch {
            // Any unforeseen encoding failure treated as too large / invalid
            throw LayoutFileCreateNewError.documentTooLarge
        }
        guard encoded.count <= Self.maxBytes else {
            throw LayoutFileCreateNewError.documentTooLarge
        }

        // 4. Final component name
        let finalName = url.lastPathComponent
        guard !finalName.isEmpty else {
            throw LayoutFileCreateNewError.invalidURL
        }
        if finalName == "." || finalName == ".." || finalName.contains("/") || finalName.utf8.contains(UInt8(0)) {
            throw LayoutFileCreateNewError.invalidURL
        }

        // 5. Random private temporary file in the opened parent directory
        let tempName = ".tmp.\(UUID().uuidString)"
        let tempFd = openat(parentFd, tempName, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard tempFd >= 0 else {
            throw LayoutFileCreateNewError.tempCreateFailed
        }

        // Write loop executed entirely inside withUnsafeBytes; base address used only inside closure.
        var written = 0
        let totalLength = encoded.count
        var writeFailed = false
        encoded.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else {
                    writeFailed = true
                    return
                }
                while written < totalLength {
                    let remaining = totalLength - written
                    let n = writeImpl(tempFd, base.advanced(by: written), remaining)
                    if n < 0 {
                        if errno == EINTR {
                            continue
                        }
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

        // 6. fsync before link
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

        // 7. Atomic linkat temporary -> final (same parent directory, hard link, no overwrite)
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

        // 8. Publication succeeded; unlink only the unique temporary name (leaves final intact as hard-link target)
        if unlinkImpl(parentFd, tempName) < 0 {
            throw LayoutFileCreateNewError.cleanupFailedAfterPublish
        }

        // Done: file created atomically at url with mode at most 0600 (from openat), subject to umask, no overwrite, no truncation.
    }
}
