import Foundation
import Testing
@testable import DockGroupsCore

struct LayoutVerifiedCopyTests {
    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var validBytes: Data { Data("{\n  \"formatVersion\" : 1, \"groups\" : []\n}\n".utf8) }

    @Test func copiesAndVerifiesExactBytesWithoutChangingSource() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.json")
        let target = dir.appendingPathComponent("copy.json")
        try validBytes.write(to: source)
        try LayoutVerifiedCopy.copy(from: source, to: target)
        #expect(try Data(contentsOf: source) == validBytes)
        #expect(try Data(contentsOf: target) == validBytes)
        #expect(try LayoutFileReader.readLayout(from: source) == LayoutFileReader.readLayout(from: target))
    }

    @Test func refusesExistingTargetAndPreservesBothFiles() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.json")
        let target = dir.appendingPathComponent("target.json")
        let originalTarget = Data("do not replace".utf8)
        try validBytes.write(to: source)
        try originalTarget.write(to: target)
        #expect(throws: LayoutVerifiedCopyError.creation(.targetExists)) {
            try LayoutVerifiedCopy.copy(from: source, to: target)
        }
        #expect(try Data(contentsOf: source) == validBytes)
        #expect(try Data(contentsOf: target) == originalTarget)
    }

    @Test func rejectsMissingInvalidAndFutureSourceWithoutCreatingTarget() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.json")
        let target = dir.appendingPathComponent("target.json")
        #expect(throws: LayoutVerifiedCopyError.sourceMissing) {
            try LayoutVerifiedCopy.copy(from: source, to: target)
        }
        let invalid = Data("{invalid".utf8)
        try invalid.write(to: source)
        #expect(throws: LayoutVerifiedCopyError.sourceRead(.invalidDocument)) {
            try LayoutVerifiedCopy.copy(from: source, to: target)
        }
        #expect(try Data(contentsOf: source) == invalid)
        let future = Data("{\"formatVersion\":999,\"groups\":[]}".utf8)
        try future.write(to: source)
        #expect(throws: LayoutVerifiedCopyError.sourceRead(.unsupportedFormat)) {
            try LayoutVerifiedCopy.copy(from: source, to: target)
        }
        #expect(try Data(contentsOf: source) == future)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func refusesBusyLockWithoutCreatingCopy() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.json")
        let target = dir.appendingPathComponent("copy.json")
        try validBytes.write(to: source)
        try LayoutFileCoordination.withExclusiveLock(in: dir) {
            #expect(throws: LayoutVerifiedCopyError.lock(.lockBusy)) {
                try LayoutVerifiedCopy.copy(from: source, to: target)
            }
        }
        #expect(try Data(contentsOf: source) == validBytes)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func verificationFailureLeavesPublishedCopyAndSource() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.json")
        let target = dir.appendingPathComponent("copy.json")
        try validBytes.write(to: source)
        let changed = Data("{\"formatVersion\":1,\"groups\":[]}".utf8)
        #expect(throws: LayoutVerifiedCopyError.verificationFailed) {
            try LayoutVerifiedCopy.copy(from: source, to: target, create: { snapshot, destination in
                try LayoutFileCreateNew.createNew(from: snapshot, at: destination)
                try changed.write(to: destination)
            })
        }
        #expect(try Data(contentsOf: target) == changed)
        #expect(try Data(contentsOf: source) == validBytes)
    }

    @Test func missingVerificationTargetIsFailure() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.json")
        let target = dir.appendingPathComponent("copy.json")
        try validBytes.write(to: source)
        #expect(throws: LayoutVerifiedCopyError.verificationFailed) {
            try LayoutVerifiedCopy.copy(from: source, to: target, create: { _, _ in })
        }
        #expect(try Data(contentsOf: source) == validBytes)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func creationFailureAfterPublicationRemainsExplicit() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.json")
        let target = dir.appendingPathComponent("copy.json")
        try validBytes.write(to: source)
        #expect(throws: LayoutVerifiedCopyError.creation(.cleanupFailedAfterPublish)) {
            try LayoutVerifiedCopy.copy(from: source, to: target, create: { snapshot, destination in
                try LayoutFileCreateNew.createNew(from: snapshot, at: destination)
                throw LayoutFileCreateNewError.cleanupFailedAfterPublish
            })
        }
        #expect(try Data(contentsOf: target) == validBytes)
        #expect(try Data(contentsOf: source) == validBytes)
    }

    @Test func rejectsRemoteRelativeSameAndCrossDirectoryURLs() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.json")
        try validBytes.write(to: source)
        let second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
        let remote = try #require(URL(string: "file://remote.example/source.json"))
        let relative = try #require(URL(string: "file:relative/source.json"))
        for (src, dst) in [(remote, source), (relative, source), (source, source), (source, second.appendingPathComponent("copy.json"))] {
            #expect(throws: LayoutVerifiedCopyError.invalidURL) { try LayoutVerifiedCopy.copy(from: src, to: dst) }
        }
        #expect(try Data(contentsOf: source) == validBytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: second.path).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".window-layout.lock").path))
    }

    @Test func rejectsSymlinkSourceAndDoesNotOverwriteSymlinkTarget() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.json")
        let sourceLink = dir.appendingPathComponent("source-link.json")
        let target = dir.appendingPathComponent("target.json")
        let victim = dir.appendingPathComponent("victim")
        let sentinel = Data("keep".utf8)
        try validBytes.write(to: source)
        try sentinel.write(to: victim)
        try FileManager.default.createSymbolicLink(at: sourceLink, withDestinationURL: source)
        #expect(throws: LayoutVerifiedCopyError.sourceRead(.cannotRead)) {
            try LayoutVerifiedCopy.copy(from: sourceLink, to: target)
        }
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: victim)
        #expect(throws: LayoutVerifiedCopyError.creation(.targetExists)) {
            try LayoutVerifiedCopy.copy(from: source, to: target)
        }
        #expect(try Data(contentsOf: source) == validBytes)
        #expect(try Data(contentsOf: victim) == sentinel)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.path) == victim.path)
    }

    @Test func refusesReservedLockNameAndURLQueryBeforeCreatingLock() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.json")
        try validBytes.write(to: source)
        let reserved = dir.appendingPathComponent(".window-layout.lock")
        let queryURL = try #require(URL(string: source.absoluteString + "?value=1"))
        let target = dir.appendingPathComponent("copy.json")
        #expect(throws: LayoutVerifiedCopyError.invalidURL) {
            try LayoutVerifiedCopy.copy(from: source, to: reserved)
        }
        #expect(throws: LayoutVerifiedCopyError.invalidURL) {
            try LayoutVerifiedCopy.copy(from: queryURL, to: target)
        }
        #expect(!FileManager.default.fileExists(atPath: reserved.path))
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(try Data(contentsOf: source) == validBytes)
    }

    @Test func unexpectedCreateErrorIsSanitizedAndDoesNotChangeSource() throws {
        struct Unexpected: Error {}
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.json")
        let target = dir.appendingPathComponent("copy.json")
        try validBytes.write(to: source)
        #expect(throws: LayoutVerifiedCopyError.creationUnknown) {
            try LayoutVerifiedCopy.copy(from: source, to: target, create: { _, _ in throw Unexpected() })
        }
        #expect(try Data(contentsOf: source) == validBytes)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func sizeBoundaryIsCopiedExactlyAndOversizeIsRejected() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.json")
        let target = dir.appendingPathComponent("copy.json")
        var bytes = Data("{\"formatVersion\":1,\"groups\":[]}".utf8)
        bytes.append(Data(repeating: 0x20, count: 2 * 1024 * 1024 - bytes.count))
        try bytes.write(to: source)
        try LayoutVerifiedCopy.copy(from: source, to: target)
        #expect(try Data(contentsOf: target) == bytes)
        let oversizeTarget = dir.appendingPathComponent("oversize.json")
        bytes.append(0x20)
        try bytes.write(to: source)
        #expect(throws: LayoutVerifiedCopyError.sourceRead(.tooLarge)) {
            try LayoutVerifiedCopy.copy(from: source, to: oversizeTarget)
        }
        #expect(try Data(contentsOf: source) == bytes)
        #expect(!FileManager.default.fileExists(atPath: oversizeTarget.path))
    }

    @Test func unexpectedErrorAfterPublicationDoesNotRemoveCopy() throws {
        struct Unexpected: Error {}
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.json")
        let target = dir.appendingPathComponent("copy.json")
        try validBytes.write(to: source)
        #expect(throws: LayoutVerifiedCopyError.creationUnknown) {
            try LayoutVerifiedCopy.copy(from: source, to: target, create: { snapshot, destination in
                try LayoutFileCreateNew.createNew(from: snapshot, at: destination)
                throw Unexpected()
            })
        }
        #expect(try Data(contentsOf: target) == validBytes)
        #expect(try Data(contentsOf: source) == validBytes)
    }

}
