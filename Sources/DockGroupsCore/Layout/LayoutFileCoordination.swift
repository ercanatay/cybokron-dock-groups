import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Advisory exclusive-lock coordination for cooperating layout writers.
///
/// LIMITATIONS — advisory/cooperating-writer only:
/// - The stable `.window-layout.lock` must never be unlinked or truncated.
/// - Only protects against other cooperating writers that also call this enum.
/// - Trusted caller-supplied parent directory; hostile same-user or ancestor
///   traversal exclusions apply (use `O_NOFOLLOW`).
/// - Not crash-durable; this is not a whole-store transaction mechanism.
/// - Fail-closed: any syscall failure before the lock is acquired throws.
/// - Deferred descriptor-close errors are not reported; no durability guarantee.
internal enum LayoutFileCoordinationError: Error, Equatable, Sendable {
    case invalidURL
    case invalidDirectory
    case invalidLockFile
    case lockBusy
    case lockFailed
}

internal enum LayoutFileCoordination {
    /// Acquire a nonblocking advisory exclusive `flock` on `.window-layout.lock`
    /// inside `directory`, run `perform`, release (close descriptor) on return
    /// or throw, and propagate `perform` errors. The lock descriptor is never
    /// exposed.
    static func withExclusiveLock<T>(
        in directory: URL,
        capability: (URL) throws -> Bool? = { url in
            try url.resourceValues(forKeys: [.volumeSupportsAdvisoryFileLockingKey]).volumeSupportsAdvisoryFileLocking
        },
        perform: () throws -> T
    ) throws -> T {
        // Reject non-local or remote URLs and paths containing NUL.
        guard directory.isFileURL else {
            throw LayoutFileCoordinationError.invalidURL
        }
        if let host = directory.host, !host.isEmpty, host.lowercased() != "localhost" {
            throw LayoutFileCoordinationError.invalidURL
        }
        let dirPath = directory.path
        guard dirPath.hasPrefix("/") else {
            throw LayoutFileCoordinationError.invalidURL
        }
        guard !dirPath.utf8.contains(UInt8(0)) else {
            throw LayoutFileCoordinationError.invalidURL
        }

        // Verify parent is an existing directory via O_DIRECTORY | O_NOFOLLOW.
        let dirFD = open(dirPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dirFD >= 0 else {
            throw LayoutFileCoordinationError.invalidDirectory
        }
        defer { _ = close(dirFD) }

        var dirStat = stat()
        guard fstat(dirFD, &dirStat) == 0 else {
            throw LayoutFileCoordinationError.invalidDirectory
        }
        guard (Int32(dirStat.st_mode) & Int32(S_IFMT)) == Int32(S_IFDIR) else {
            throw LayoutFileCoordinationError.invalidDirectory
        }

        // Per-call defaulted capability check; fail closed before opening lock file.
        do {
            guard let supported = try capability(directory), supported else {
                throw LayoutFileCoordinationError.lockFailed
            }
        } catch {
            throw LayoutFileCoordinationError.lockFailed
        }

        // Open the stable lock file via openat relative to the directory fd.
        let lockName = ".window-layout.lock"
        let lockFD = openat(
            dirFD,
            lockName,
            O_RDWR | O_CREAT | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard lockFD >= 0 else {
            throw LayoutFileCoordinationError.invalidLockFile
        }
        defer { _ = close(lockFD) }

        var lockStat = stat()
        guard fstat(lockFD, &lockStat) == 0 else {
            throw LayoutFileCoordinationError.invalidLockFile
        }
        guard (Int32(lockStat.st_mode) & Int32(S_IFMT)) == Int32(S_IFREG) else {
            throw LayoutFileCoordinationError.invalidLockFile
        }

        // Nonblocking advisory exclusive flock.
        let flockRes = flock(lockFD, LOCK_EX | LOCK_NB)
        guard flockRes == 0 else {
            let err = errno
            if err == EWOULDBLOCK || err == EAGAIN {
                throw LayoutFileCoordinationError.lockBusy
            }
            throw LayoutFileCoordinationError.lockFailed
        }

        // Run the callback; hold the descriptor open until it returns or throws.
        do {
            let result = try perform()
            // Descriptor closed by defer; never expose it.
            return result
        } catch {
            // Descriptor still closed by defer; propagate callback error.
            throw error
        }
    }
}
