import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Narrow internal read-only loader for a caller-supplied local layout document.
///
/// LIMITATIONS — read before relying on the result:
/// - Read-only: no mutation, no save/rename/overwrite/backup/recovery is performed.
/// - No protection against mutation of an opened regular file during this read.
/// - No protection against parent-directory symlink traversal or cross-file transaction.
/// - Uses Darwin O_NOFOLLOW (final-component symlink blocked) and requires S_IFREG after open.
/// - Returns nil for a missing file (not an error); throws only for read/decode failures.
/// - Errors are constant and never contain the file URL, path, or raw OS error string.
///
internal enum LayoutFileReaderError: Error, Equatable, Sendable {
    case unsupportedFormat
    case invalidDocument
    case tooLarge
    case notRegular
    case cannotRead
}

internal enum LayoutFileReader {
    /// Maximum encoded document size (2 MiB). Reject anything larger even if it grows during read.
    private static let maxBytes = 2 * 1024 * 1024
    /// We may read at most cap + 1 byte to detect growth, then reject.
    private static let maxRead = maxBytes + 1
    private static let chunkSize = 65536

    static func readLayout(from url: URL, readImpl: (Int32, UnsafeMutablePointer<UInt8>, Int) -> Int = { fd, buf, count in read(fd, buf, count) }) throws -> WindowLayoutDocument? {
        // Reject non-file URLs before accessing any path.
        guard url.isFileURL else {
            throw LayoutFileReaderError.cannotRead
        }
        if let host = url.host, !host.isEmpty, host.lowercased() != "localhost" {
            throw LayoutFileReaderError.cannotRead
        }
        let path = url.path
        guard !path.utf8.contains(UInt8(0)) else {
            throw LayoutFileReaderError.cannotRead
        }

        // Remove faulty FileManager.fileExists pre-check that follows symlinks
        // and mistakes dangling final-component symlinks for missing files.
        // Call open directly with O_NOFOLLOW; only ENOENT means missing.
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT {
                return nil
            }
            throw LayoutFileReaderError.cannotRead
        }
        defer { _ = close(fd) }

        var statBuf = stat()
        let fstatRes = fstat(fd, &statBuf)
        guard fstatRes == 0 else {
            throw LayoutFileReaderError.cannotRead
        }
        guard (Int32(statBuf.st_mode) & Int32(S_IFMT)) == Int32(S_IFREG) else {
            throw LayoutFileReaderError.notRegular
        }

        // Bounded read in chunks; handle short reads and EINTR.
        var data = Data()
        data.reserveCapacity(chunkSize)
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        while true {
            // Enforce cap on every call: never request more than cap+1 - current.
            let remaining = maxRead - data.count
            if remaining <= 0 {
                throw LayoutFileReaderError.tooLarge
            }
            let toRead = min(chunkSize, remaining)
            let n = readImpl(fd, &buffer, toRead)
            if n < 0 {
                if errno == EINTR {
                    continue
                }
                throw LayoutFileReaderError.cannotRead
            }
            if n == 0 {
                break // EOF
            }
            guard n <= toRead else {
                throw LayoutFileReaderError.cannotRead
            }
            // Append what we actually read.
            data.append(buffer, count: n)
            // Reject immediately if we've reached cap + 1 (detection of growth).
            if data.count >= maxRead {
                throw LayoutFileReaderError.tooLarge
            }
            // Reject oversized (above cap, including if file grew during read to exceed cap).
            if data.count > maxBytes {
                throw LayoutFileReaderError.tooLarge
            }
        }

        // Reject oversized (above cap, including if file grew during read to exceed cap).
        if data.count > maxBytes {
            throw LayoutFileReaderError.tooLarge
        }

        // Decode; never embed input/path/raw OS error in thrown error.
        do {
            return try WindowLayoutJSONDecoder.decode(data)
        } catch let error as WindowLayoutJSONDecodeError {
            switch error {
            case .unsupportedFormatVersion:
                throw LayoutFileReaderError.unsupportedFormat
            default:
                throw LayoutFileReaderError.invalidDocument
            }
        } catch {
            throw LayoutFileReaderError.invalidDocument
        }
    }
}
