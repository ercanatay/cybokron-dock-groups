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
        try LayoutFileCoordination.withExclusiveLock(in: dir) {
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

}
