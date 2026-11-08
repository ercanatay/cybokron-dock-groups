import Darwin
import Foundation
import Testing
@testable import DockGroupsCore

struct LayoutFileCoordinationTests {
    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func keepsStableLockFileAndReturnsCallbackValue() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let lock = dir.appendingPathComponent(".window-layout.lock")
        let value = try LayoutFileCoordination.withExclusiveLock(in: dir) { 42 }
        #expect(value == 42)
        let first = try FileManager.default.attributesOfItem(atPath: lock.path)
        _ = try LayoutFileCoordination.withExclusiveLock(in: dir) { true }
        let second = try FileManager.default.attributesOfItem(atPath: lock.path)
        let firstInode = try #require(first[.systemFileNumber] as? NSNumber)
        let secondInode = try #require(second[.systemFileNumber] as? NSNumber)
        #expect(firstInode == secondInode)
        let mode = try #require(first[.posixPermissions] as? NSNumber)
        #expect(mode.intValue & ~0o600 == 0)
    }

    @Test func refusesContentionWithoutRunningSecondCallback() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var called = false
        _ = try LayoutFileCoordination.withExclusiveLock(in: dir) {
            #expect(throws: LayoutFileCoordinationError.lockBusy) {
                try LayoutFileCoordination.withExclusiveLock(in: dir) { called = true }
            }
        }
        #expect(!called)
        #expect(try LayoutFileCoordination.withExclusiveLock(in: dir) { true })
    }

    @Test func callbackFailureReleasesLock() throws {
        struct Failure: Error, Equatable {}
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: Failure()) {
            try LayoutFileCoordination.withExclusiveLock(in: dir) { throw Failure() }
        }
        #expect(try LayoutFileCoordination.withExclusiveLock(in: dir) { true })
    }

    @Test func existingRegularLockIsNeverTruncated() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let lock = dir.appendingPathComponent(".window-layout.lock")
        let content = Data("sentinel".utf8)
        try content.write(to: lock)
        _ = try LayoutFileCoordination.withExclusiveLock(in: dir) { true }
        #expect(try Data(contentsOf: lock) == content)
    }

    @Test func symlinkLockCannotTouchTarget() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("target")
        let content = Data("sentinel".utf8)
        try content.write(to: target)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent(".window-layout.lock"), withDestinationURL: target)
        var called = false
        #expect(throws: (any Error).self) {
            try LayoutFileCoordination.withExclusiveLock(in: dir) { called = true }
        }
        #expect(!called)
        #expect(try Data(contentsOf: target) == content)
    }

    @Test func fifoLockIsRejectedWithoutBlocking() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent(".window-layout.lock").path
        #expect(mkfifo(path, 0o600) == 0)
        var called = false
        #expect(throws: (any Error).self) {
            try LayoutFileCoordination.withExclusiveLock(in: dir) { called = true }
        }
        #expect(!called)
    }

    @Test func invalidAndRemoteURLsAreRejectedBeforeCallback() throws {
        let url = try #require(URL(string: "file://remote.example/secret"))
        var called = false
        #expect(throws: LayoutFileCoordinationError.invalidURL) {
            try LayoutFileCoordination.withExclusiveLock(in: url) { called = true }
        }
        #expect(!called)
        #expect(throws: LayoutFileCoordinationError.invalidURL) {
            try LayoutFileCoordination.withExclusiveLock(in: URL(string: "https://example.org")!) { called = true }
        }
        #expect(!called)
    }

    @Test func unsupportedOrUnknownLockCapabilityDoesNotCreateFile() throws {
        for supported in [false, nil] as [Bool?] {
            let dir = try directory()
            defer { try? FileManager.default.removeItem(at: dir) }
            var called = false
            #expect(throws: LayoutFileCoordinationError.lockFailed) {
                try LayoutFileCoordination.withExclusiveLock(in: dir, capability: { _ in supported }) { called = true }
            }
            #expect(!called)
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        }
    }

    @Test func failedCapabilityLookupDoesNotCreateFile() throws {
        struct ProbeFailure: Error {}
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var called = false
        #expect(throws: LayoutFileCoordinationError.lockFailed) {
            try LayoutFileCoordination.withExclusiveLock(in: dir, capability: { _ in throw ProbeFailure() }) { called = true }
        }
        #expect(!called)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }


    @Test func symlinkDirectoryAndMissingDirectoryAreRejected() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        var called = false
        for dir in [alias, root.appendingPathComponent("missing")] {
            #expect(throws: LayoutFileCoordinationError.invalidDirectory) {
                try LayoutFileCoordination.withExclusiveLock(in: dir) { called = true }
            }
        }
        #expect(!called)
        #expect(try FileManager.default.contentsOfDirectory(atPath: real.path).isEmpty)
    }


    @Test func relativeFileURLIsRejectedAsInvalid() throws {
        let relative = try #require(URL(string: "file:missing-relative-layout-dir"))
        var called = false
        #expect(throws: LayoutFileCoordinationError.invalidURL) {
            try LayoutFileCoordination.withExclusiveLock(in: relative) { called = true }
        }
        #expect(!called)
    }

    /// A copy of the lock descriptor that outlives the call — what a child spawned on another
    /// thread holds until it execs — must not keep the lock held once the call returns.
    @Test func lockIsReleasedWhileACopyOfItsDescriptorIsStillOpen() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let suffix = "/\(dir.lastPathComponent)/.window-layout.lock"
        let copy = try LayoutFileCoordination.withExclusiveLock(in: dir) { () -> Int32 in
            try #require(Self.duplicateOpenDescriptor(pathSuffix: suffix))
        }
        defer { _ = close(copy) }
        #expect(try LayoutFileCoordination.withExclusiveLock(in: dir) { true })
    }

    /// `posix_spawn`/`Process` on another thread copies every descriptor into the child, and
    /// close-on-exec descriptors are closed only when the child execs. Back-to-back calls must not
    /// report `lockBusy` because of such an in-flight child.
    @Test func backToBackCallsAreNotBusyWhileChildrenSpawnConcurrently() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spawner = ConcurrentSpawner(spawns: 50)
        spawner.start()
        var calls = 0
        var busy = 0
        while !spawner.isFinished {
            do {
                _ = try LayoutFileCoordination.withExclusiveLock(in: dir) { true }
            } catch LayoutFileCoordinationError.lockBusy {
                busy += 1
            }
            calls += 1
        }
        #expect(spawner.failures == 0)
        #expect(calls > 0)
        #expect(busy == 0)
    }

    /// Duplicates the process's open descriptor whose path ends with `pathSuffix`.
    private static func duplicateOpenDescriptor(pathSuffix: String) -> Int32? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        for fd in 0..<min(getdtablesize(), 1 << 20) where fcntl(fd, F_GETPATH, &buffer) == 0 {
            if String(cString: buffer).hasSuffix(pathSuffix) {
                let copy = fcntl(fd, F_DUPFD_CLOEXEC, 0)
                return copy >= 0 ? copy : nil
            }
        }
        return nil
    }
}

/// Spawns `/usr/bin/true` repeatedly on a background thread.
private final class ConcurrentSpawner: @unchecked Sendable {
    private let spawns: Int
    private let lock = NSLock()
    private var finished = false
    private var failed = 0

    init(spawns: Int) { self.spawns = spawns }

    var isFinished: Bool { lock.withLock { finished } }
    var failures: Int { lock.withLock { failed } }

    func start() {
        Thread.detachNewThread { [self] in
            for _ in 0..<spawns {
                var pid: pid_t = 0
                let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
                defer { argv.forEach { free($0) } }
                var status: Int32 = 0
                if posix_spawn(&pid, "/usr/bin/true", nil, nil, argv, environ) != 0 || waitpid(pid, &status, 0) != pid {
                    lock.withLock { failed += 1 }
                }
            }
            lock.withLock { finished = true }
        }
    }
}
