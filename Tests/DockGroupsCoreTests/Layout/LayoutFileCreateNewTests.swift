import Foundation
import Testing
@testable import DockGroupsCore

struct LayoutFileCreateNewTests {
    private func isolatedDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    // RED: compile against stub; should fail until implementation passes.
    @Test func createsValidFileWithMode0600() throws {
        let dir = try isolatedDir()
        defer { remove(dir) }
        let doc = try WindowLayoutDocument(
            formatVersion: 1,
            groups: [WindowLayoutDocument.Group(id: UUID(), windows: [
                WindowLayoutDocument.Window(
                    bundleIdentifier: "com.example.App",
                    display: WindowLayoutDocument.DisplaySize(width: 1920, height: 1080),
                    frame: RelativeWindowFrame(x: 0, y: 0, width: 0.8, height: 0.6)
                )
            ])]
        )
        let target = dir.appendingPathComponent("layout.json")
        try LayoutFileCreateNew.createNew(from: doc, at: target)
        #expect(FileManager.default.fileExists(atPath: target.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: target.path)
        let mode = attrs[.posixPermissions] as? NSNumber
        #expect(mode != nil)
        #expect(mode!.intValue == 0o600)
        let readBack = try LayoutFileReader.readLayout(from: target)
        #expect(readBack != nil)
    }

    @Test func existingFileUntouched() throws {
        let dir = try isolatedDir()
        defer { remove(dir) }
        let existing = dir.appendingPathComponent("existing.json")
        let original = Data(#"{"formatVersion":1,"groups":[]}"#.utf8)
        try original.write(to: existing)
        let doc = try WindowLayoutDocument(formatVersion: 1, groups: [WindowLayoutDocument.Group(id: UUID(), windows: [WindowLayoutDocument.Window(bundleIdentifier: "a", display: WindowLayoutDocument.DisplaySize(width: 1, height: 1), frame: RelativeWindowFrame(x: 0, y: 0, width: 1, height: 1))])])
        let target = dir.appendingPathComponent("existing.json")
        #expect(throws: LayoutFileCreateNewError.targetExists) {
            try LayoutFileCreateNew.createNew(from: doc, at: target)
        }
        #expect(try Data(contentsOf: existing) == original)
    }

    @Test func corruptFileUntouched() throws {
        let dir = try isolatedDir()
        defer { remove(dir) }
        let corrupt = dir.appendingPathComponent("bad.json")
        let original = Data([0x01, 0x02, 0x03])
        try original.write(to: corrupt)
        let doc = try WindowLayoutDocument(formatVersion: 1, groups: [WindowLayoutDocument.Group(id: UUID(), windows: [WindowLayoutDocument.Window(bundleIdentifier: "a", display: WindowLayoutDocument.DisplaySize(width: 1, height: 1), frame: RelativeWindowFrame(x: 0, y: 0, width: 1, height: 1))])])
        #expect(throws: LayoutFileCreateNewError.targetExists) {
            try LayoutFileCreateNew.createNew(from: doc, at: corrupt)
        }
        #expect(try Data(contentsOf: corrupt) == original)
    }

    @Test func directoryTargetUntouched() throws {
        let dir = try isolatedDir()
        defer { remove(dir) }
        let sub = dir.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let doc = try WindowLayoutDocument(formatVersion: 1, groups: [WindowLayoutDocument.Group(id: UUID(), windows: [WindowLayoutDocument.Window(bundleIdentifier: "a", display: WindowLayoutDocument.DisplaySize(width: 1, height: 1), frame: RelativeWindowFrame(x: 0, y: 0, width: 1, height: 1))])])
        #expect(throws: LayoutFileCreateNewError.targetExists) {
            try LayoutFileCreateNew.createNew(from: doc, at: sub)
        }
    }

    @Test func symlinkTargetUntouched() throws {
        let dir = try isolatedDir()
        defer { remove(dir) }
        let realFile = dir.appendingPathComponent("real.json")
        try #"{}"#.write(to: realFile, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realFile)
        let doc = try WindowLayoutDocument(formatVersion: 1, groups: [WindowLayoutDocument.Group(id: UUID(), windows: [WindowLayoutDocument.Window(bundleIdentifier: "a", display: WindowLayoutDocument.DisplaySize(width: 1, height: 1), frame: RelativeWindowFrame(x: 0, y: 0, width: 1, height: 1))])])
        #expect(throws: LayoutFileCreateNewError.targetExists) {
            try LayoutFileCreateNew.createNew(from: doc, at: link)
        }
        // symlink target file untouched
        #expect(try Data(contentsOf: realFile) == #"{}"#.data(using: .utf8)!)
    }

    @Test func twoSequentialCreatesOneSucceedsAndReadBack() throws {
        let dir = try isolatedDir()
        defer { remove(dir) }
        let doc = try WindowLayoutDocument(formatVersion: 1, groups: [WindowLayoutDocument.Group(id: UUID(), windows: [WindowLayoutDocument.Window(bundleIdentifier: "a", display: WindowLayoutDocument.DisplaySize(width: 1, height: 1), frame: RelativeWindowFrame(x: 0, y: 0, width: 1, height: 1))])])
        let target = dir.appendingPathComponent("race.json")
        // First create succeeds (target nonexistent); second hits existing -> targetExists.
        try LayoutFileCreateNew.createNew(from: doc, at: target)
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(throws: LayoutFileCreateNewError.targetExists) {
            try LayoutFileCreateNew.createNew(from: doc, at: target)
        }
        // File readable back with full encoded bytes intact.
        let back = try LayoutFileReader.readLayout(from: target)
        #expect(back != nil)
    }

    @Test func malformedURLsDenied() throws {
        let doc = try WindowLayoutDocument(formatVersion: 1, groups: [])
        #expect(throws: LayoutFileCreateNewError.invalidURL) {
            try LayoutFileCreateNew.createNew(from: doc, at: URL(string: "http://example.com/x.json")!)
        }
        // Remote file host (not localhost) must be rejected.
        var comps = URLComponents()
        comps.scheme = "file"
        comps.host = "evil.host"
        comps.path = "/tmp/x.json"
        #expect(throws: LayoutFileCreateNewError.invalidURL) {
            try LayoutFileCreateNew.createNew(from: doc, at: comps.url!)
        }
    }

    @Test func oversizedModelRejectedBeforeDirectoryEntry() throws {
        let dir = try isolatedDir()
        defer { remove(dir) }
        // Build a document with many groups to push encoded size over 2MiB; simpler: inject oversized encoded manually?
        // Instead rely on encoder; we'll just trust encoder cap; test verifies error thrown and no new file.
        // 256 groups * 64 windows (max allowed) with unique long bundle IDs to push encoded JSON over 2 MiB.
        let baseID = String(repeating: "b", count: 250) // + i (≤2 chars for 0..63) = ≤252 chars
        let big = try WindowLayoutDocument(formatVersion: 1, groups: Array(0..<256).map { _ in
            WindowLayoutDocument.Group(id: UUID(), windows: Array(0..<64).map { i in
                WindowLayoutDocument.Window(bundleIdentifier: baseID + String(i), display: WindowLayoutDocument.DisplaySize(width: 1, height: 1), frame: RelativeWindowFrame(x: 0, y: 0, width: 1, height: 1))
            })
        })
        let target = dir.appendingPathComponent("oversized.json")
        #expect(throws: LayoutFileCreateNewError.documentTooLarge) {
            try LayoutFileCreateNew.createNew(from: big, at: target)
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func errorsDoNotLeakInput() throws {
        let doc = try WindowLayoutDocument(formatVersion: 1, groups: [WindowLayoutDocument.Group(id: UUID(), windows: [WindowLayoutDocument.Window(bundleIdentifier: "secret.bundle.id", display: WindowLayoutDocument.DisplaySize(width: 1, height: 1), frame: RelativeWindowFrame(x: 0, y: 0, width: 1, height: 1))])])
        do {
            _ = try LayoutFileCreateNew.createNew(from: doc, at: URL(string: "bad://host/file.json")!)
        } catch let err {
            let s = String(describing: err)
            #expect(!s.contains("secret.bundle.id"))
            #expect(!s.contains("bad://"))
        }
    }

    @Test func cleanupFailureBeforePublicationPreservesExistingFile() throws {
        let dir = try isolatedDir()
        defer { remove(dir) }
        let target = dir.appendingPathComponent("existing.json")
        let original = Data("original".utf8)
        try original.write(to: target)
        let doc = try WindowLayoutDocument(groups: [])
        let failCleanup: (Int32, String) -> Int32 = { _, _ in errno = EACCES; return -1 }
        #expect(throws: LayoutFileCreateNewError.cleanupFailedBeforePublish) {
            try LayoutFileCreateNew.createNew(from: doc, at: target, unlinkImpl: failCleanup)
        }
        #expect(try Data(contentsOf: target) == original)
        let leftovers = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".tmp.") }
        #expect(leftovers.count == 1)
    }

    @Test func cleanupFailureAfterPublicationReportsPublishedFile() throws {
        let dir = try isolatedDir()
        defer { remove(dir) }
        let target = dir.appendingPathComponent("new.json")
        let doc = try WindowLayoutDocument(groups: [])
        let failCleanup: (Int32, String) -> Int32 = { _, _ in errno = EACCES; return -1 }
        #expect(throws: LayoutFileCreateNewError.cleanupFailedAfterPublish) {
            try LayoutFileCreateNew.createNew(from: doc, at: target, unlinkImpl: failCleanup)
        }
        #expect(try LayoutFileReader.readLayout(from: target) == doc)
        let leftovers = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".tmp.") }
        #expect(leftovers.count == 1)
    }

    @Test func simultaneousCreatesHaveOneWinnerAndNoTempFiles() throws {
        let dir = try isolatedDir()
        defer { remove(dir) }
        let target = dir.appendingPathComponent("race.json")
        let doc = try WindowLayoutDocument(groups: [])
        let lock = NSLock()
        var outcomes: [String] = []
        DispatchQueue.concurrentPerform(iterations: 2) { _ in
            let outcome: String
            do { try LayoutFileCreateNew.createNew(from: doc, at: target); outcome = "created" }
            catch LayoutFileCreateNewError.targetExists { outcome = "exists" }
            catch { outcome = "unexpected" }
            lock.lock()
            outcomes.append(outcome)
            lock.unlock()
        }
        #expect(outcomes.sorted() == ["created", "exists"])
        #expect(try LayoutFileReader.readLayout(from: target) == doc)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names == ["race.json"])
    }

    @Test func partialAndInterruptedWritesProduceCompleteFile() throws {
        let dir = try isolatedDir()
        defer { remove(dir) }
        let target = dir.appendingPathComponent("partial.json")
        let doc = try WindowLayoutDocument(groups: [])
        var calls = 0
        let shortWrite: (Int32, UnsafeRawPointer, Int) -> Int = { fd, pointer, count in
            calls += 1
            if calls == 1 { errno = EINTR; return -1 }
            return write(fd, pointer, min(count, 3))
        }
        try LayoutFileCreateNew.createNew(from: doc, at: target, writeImpl: shortWrite)
        #expect(calls > 2)
        #expect(try LayoutFileReader.readLayout(from: target) == doc)
    }

    @Test func impossibleWriteCountDoesNotPublishFile() throws {
        let dir = try isolatedDir()
        defer { remove(dir) }
        let target = dir.appendingPathComponent("bad.json")
        let doc = try WindowLayoutDocument(groups: [])
        let invalid: (Int32, UnsafeRawPointer, Int) -> Int = { _, _, count in count + 1 }
        #expect(throws: LayoutFileCreateNewError.tempWriteFailed) {
            try LayoutFileCreateNew.createNew(from: doc, at: target, writeImpl: invalid)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func zeroByteWriteDoesNotPublish() throws {
        let dir = try isolatedDir()
        defer { remove(dir) }
        let target = dir.appendingPathComponent("zero.json")
        let doc = try WindowLayoutDocument(groups: [])
        let noProgress: (Int32, UnsafeRawPointer, Int) -> Int = { _, _, _ in 0 }
        #expect(throws: LayoutFileCreateNewError.tempWriteFailed) {
            try LayoutFileCreateNew.createNew(from: doc, at: target, writeImpl: noProgress)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func failedWriteAndCleanupReportRemainingTemporaryFile() throws {
        let dir = try isolatedDir()
        defer { remove(dir) }
        let target = dir.appendingPathComponent("failed.json")
        let doc = try WindowLayoutDocument(groups: [])
        let failedWrite: (Int32, UnsafeRawPointer, Int) -> Int = { _, _, _ in errno = EIO; return -1 }
        let failedCleanup: (Int32, String) -> Int32 = { _, _ in errno = EACCES; return -1 }
        #expect(throws: LayoutFileCreateNewError.cleanupFailedBeforePublish) {
            try LayoutFileCreateNew.createNew(from: doc, at: target, writeImpl: failedWrite, unlinkImpl: failedCleanup)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.count == 1 && names[0].hasPrefix(".tmp."))
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }


    @Test func relativeFileURLIsRejectedBeforeCreate() throws {
        let url = try #require(URL(string: "file:missing-\(UUID().uuidString)/layout.json"))
        let document = try WindowLayoutDocument(groups: [])
        #expect(throws: LayoutFileCreateNewError.invalidURL) {
            try LayoutFileCreateNew.createNew(from: document, at: url)
        }
    }

    @Test func createsNewFileWithExactValidatedSnapshotBytes() throws {
        let dir = try isolatedDir()
        defer { remove(dir) }
        let original = dir.appendingPathComponent("original.json")
        let bytes = Data("{\n  \"formatVersion\" : 1,\n  \"groups\" : []\n}\n".utf8)
        try bytes.write(to: original)
        let read = try LayoutFileReader.readSnapshot(from: original)
        let snapshot = try #require(read)
        let target = dir.appendingPathComponent("copy.json")
        try LayoutFileCreateNew.createNew(from: snapshot, at: target)
        #expect(try Data(contentsOf: target) == bytes)
        #expect(try Data(contentsOf: original) == bytes)
        #expect(try LayoutFileReader.readLayout(from: target) == snapshot.document)
    }

    @Test func snapshotCreationDoesNotReplaceExistingFile() throws {
        let dir = try isolatedDir()
        defer { remove(dir) }
        let original = dir.appendingPathComponent("original.json")
        let bytes = Data("{\"formatVersion\":1,\"groups\":[]}".utf8)
        try bytes.write(to: original)
        let read = try LayoutFileReader.readSnapshot(from: original)
        let snapshot = try #require(read)
        let target = dir.appendingPathComponent("occupied.json")
        let sentinel = Data("existing".utf8)
        try sentinel.write(to: target)
        #expect(throws: LayoutFileCreateNewError.targetExists) {
            try LayoutFileCreateNew.createNew(from: snapshot, at: target)
        }
        #expect(try Data(contentsOf: target) == sentinel)
        #expect(try Data(contentsOf: original) == bytes)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!names.contains { $0.hasPrefix(".tmp.") })
    }

    @Test func snapshotCreationHandlesShortAndInterruptedWrites() throws {
        let dir = try isolatedDir()
        defer { remove(dir) }
        let original = dir.appendingPathComponent("original.json")
        let bytes = Data("{\"formatVersion\":1,\"groups\":[]}".utf8)
        try bytes.write(to: original)
        let read = try LayoutFileReader.readSnapshot(from: original)
        let snapshot = try #require(read)
        let target = dir.appendingPathComponent("copy.json")
        var calls = 0
        let shortWrite: (Int32, UnsafeRawPointer, Int) -> Int = { fd, pointer, count in
            calls += 1
            if calls == 1 { errno = EINTR; return -1 }
            return write(fd, pointer, min(count, 2))
        }
        try LayoutFileCreateNew.createNew(from: snapshot, at: target, writeImpl: shortWrite)
        #expect(calls > 2)
        #expect(try Data(contentsOf: target) == bytes)
        #expect(try Data(contentsOf: original) == bytes)
    }

    @Test func snapshotCreationDoesNotReplaceSymlink() throws {
        let dir = try isolatedDir()
        defer { remove(dir) }
        let original = dir.appendingPathComponent("original.json")
        let bytes = Data("{\"formatVersion\":1,\"groups\":[]}".utf8)
        try bytes.write(to: original)
        let read = try LayoutFileReader.readSnapshot(from: original)
        let snapshot = try #require(read)
        let victim = dir.appendingPathComponent("victim")
        let sentinel = Data("keep".utf8)
        try sentinel.write(to: victim)
        let target = dir.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: victim)
        #expect(throws: LayoutFileCreateNewError.targetExists) {
            try LayoutFileCreateNew.createNew(from: snapshot, at: target)
        }
        #expect(try Data(contentsOf: victim) == sentinel)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.path) == victim.path)
    }

    @Test func snapshotCleanupFailureAfterPublicationReportsPublishedBytes() throws {
        let dir = try isolatedDir()
        defer { remove(dir) }
        let original = dir.appendingPathComponent("original.json")
        let bytes = Data("{ \"formatVersion\": 1, \"groups\": [] }".utf8)
        try bytes.write(to: original)
        let read = try LayoutFileReader.readSnapshot(from: original)
        let snapshot = try #require(read)
        let target = dir.appendingPathComponent("copy.json")
        let failCleanup: (Int32, String) -> Int32 = { _, _ in errno = EACCES; return -1 }
        #expect(throws: LayoutFileCreateNewError.cleanupFailedAfterPublish) {
            try LayoutFileCreateNew.createNew(from: snapshot, at: target, unlinkImpl: failCleanup)
        }
        #expect(try Data(contentsOf: target) == bytes)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.filter { $0.hasPrefix(".tmp.") }.count == 1)
    }

}
