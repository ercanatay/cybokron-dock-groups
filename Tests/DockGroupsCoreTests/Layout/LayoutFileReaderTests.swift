import Foundation
import Testing
@testable import DockGroupsCore

struct LayoutFileReaderTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // Valid document should decode.
    @Test func validDocument() throws {
        let dir = try tempDir()
        defer { cleanup(dir) }
        let file = dir.appendingPathComponent("layout.json")
        let json = """
        {"formatVersion":1,"groups":[{"id":"12345678-1234-1234-1234-123456789abc","windows":[{"bundleIdentifier":"com.example.App","display":{"width":1920,"height":1080},"frame":{"x":0,"y":0,"width":0.8,"height":0.6}}]}]}
        """
        try json.write(to: file, atomically: true, encoding: .utf8)
        let doc = try LayoutFileReader.readLayout(from: file)
        #expect(doc != nil)
    }

    // Missing file returns nil.
    @Test func missingFileReturnsNil() throws {
        let dir = try tempDir()
        defer { cleanup(dir) }
        let missing = dir.appendingPathComponent("no.json")
        let result = try LayoutFileReader.readLayout(from: missing)
        #expect(result == nil)
    }

    // Malformed JSON throws invalidDocument (not crash / embed path).
    @Test func malformedThrowsInvalidDocument() throws {
        let dir = try tempDir()
        defer { cleanup(dir) }
        let file = dir.appendingPathComponent("bad.json")
        try "not json".write(to: file, atomically: true, encoding: .utf8)
        do {
            _ = try LayoutFileReader.readLayout(from: file)
            Issue.record("Expected error")
        } catch LayoutFileReaderError.invalidDocument {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // Unsupported version preserves original bytes and throws unsupportedFormat.
    @Test func unsupportedVersionPreservesBytes() throws {
        let dir = try tempDir()
        defer { cleanup(dir) }
        let file = dir.appendingPathComponent("v99.json")
        let original = "{\"formatVersion\":99,\"groups\":[]}".data(using: .utf8)!
        try original.write(to: file)
        do {
            _ = try LayoutFileReader.readLayout(from: file)
            Issue.record("Expected error")
        } catch LayoutFileReaderError.unsupportedFormat {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        let after = try Data(contentsOf: file)
        #expect(original == after)
    }

    // At exact bound (2 MiB) should be accepted if valid; above bound (2 MiB + 1) rejected.
    @Test func exactBoundAndAbove() throws {
        let dir = try tempDir()
        defer { cleanup(dir) }
        // Build a minimal JSON under 2 MiB
        let minimal = "{\"formatVersion\":1,\"groups\":[{\"id\":\"12345678-1234-1234-1234-123456789abc\",\"windows\":[{\"bundleIdentifier\":\"com.a\",\"display\":{\"width\":1,\"height\":1},\"frame\":{\"x\":0,\"y\":0,\"width\":1,\"height\":1}}]}]}"
        let boundFile = dir.appendingPathComponent("bound.json")
        try minimal.write(to: boundFile, atomically: true, encoding: .utf8)
        // Call reader on under-limit file (previously missing!)
        let doc = try LayoutFileReader.readLayout(from: boundFile)
        #expect(doc != nil)
        // Above bound: create 2MiB+1 of non-JSON data (rejected before decode as tooLarge)
        let oversized = dir.appendingPathComponent("over.json")
        let big = Data(repeating: 0x20, count: 2 * 1024 * 1024 + 1)
        try big.write(to: oversized)
        do {
            _ = try LayoutFileReader.readLayout(from: oversized)
            Issue.record("Expected tooLarge")
        } catch LayoutFileReaderError.tooLarge {
            // expected
        } catch {
            Issue.record("Unexpected: \(error)")
        }
    }

    // Directory instead of file -> notRegular.
    @Test func directoryNotRegular() throws {
        let dir = try tempDir()
        defer { cleanup(dir) }
        let subdir = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        do {
            _ = try LayoutFileReader.readLayout(from: subdir)
            Issue.record("Expected error")
        } catch LayoutFileReaderError.notRegular {
            // expected
        } catch {
            Issue.record("Unexpected: \(error)")
        }
    }

    // Symlink to regular file at final component blocked by O_NOFOLLOW.
    @Test func symlinkBlocked() throws {
        let dir = try tempDir()
        defer { cleanup(dir) }
        let target = dir.appendingPathComponent("target.json")
        try "{}".write(to: target, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        do {
            _ = try LayoutFileReader.readLayout(from: link)
            Issue.record("Expected error")
        } catch LayoutFileReaderError.notRegular {
            // expected (symlink blocked -> not regular / cannot read)
        } catch LayoutFileReaderError.cannotRead {
            // acceptable
        } catch {
            Issue.record("Unexpected: \(error)")
        }
    }

    // FIFO should be rejected (not regular).
    @Test func fifoNotRegular() throws {
        let dir = try tempDir()
        defer { cleanup(dir) }
        let fifo = dir.appendingPathComponent("fifo")
        // Create FIFO using Process (mkfifo)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/mkfifo")
        task.arguments = [fifo.path]
        try task.run()
        task.waitUntilExit()
        #expect(task.terminationStatus == 0)
        do {
            _ = try LayoutFileReader.readLayout(from: fifo)
            Issue.record("Expected error")
        } catch LayoutFileReaderError.notRegular {
            // expected
        } catch LayoutFileReaderError.cannotRead {
        } catch {
            Issue.record("Unexpected: \(error)")
        }
    }

    // Error messages must not contain paths.
    @Test func errorPathRedaction() throws {
        let dir = try tempDir()
        defer { cleanup(dir) }
        let file = dir.appendingPathComponent("bad.json")
        try "bad".write(to: file, atomically: true, encoding: .utf8)
        do {
            _ = try LayoutFileReader.readLayout(from: file)
        } catch {
            let s = String(describing: error)
            #expect(!s.contains("bad.json"))
            #expect(!s.contains(dir.path))
        }
    }

    // MARK: - New RED tests (before fix)

    // Dangling symlink must not be mistaken for missing; symlink must fail.
    @Test func danglingSymlinkRejected() throws {
        let dir = try tempDir()
        defer { cleanup(dir) }
        let target = dir.appendingPathComponent("gone.json")
        // Create and then remove target so symlink is dangling
        try "{}".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: target)
        let link = dir.appendingPathComponent("dangling.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        // Before fix: fileExists follows symlink, sees missing -> returns nil (WRONG)
        // After fix: open with O_NOFOLLOW should fail (ELOOP) -> throw
        do {
            _ = try LayoutFileReader.readLayout(from: link)
            Issue.record("Expected error for dangling symlink")
        } catch LayoutFileReaderError.cannotRead {
            // expected after fix
        } catch LayoutFileReaderError.notRegular {
            // acceptable
        } catch {
            Issue.record("Unexpected: \(error)")
        }
    }

    // Non-file URLs rejected with .cannotRead before path access.
    @Test func nonFileURLRejected() throws {
        let url = URL(string: "http://example.com/layout.json")!
        do {
            _ = try LayoutFileReader.readLayout(from: url)
            Issue.record("Expected .cannotRead for non-file URL")
        } catch LayoutFileReaderError.cannotRead {
            // expected after fix
        } catch {
            Issue.record("Unexpected: \(error)")
        }
    }

    // Valid exact 2 MiB JSON padded with whitespace decodes correctly.
    @Test func validExact2MiBPaddedWithWhitespace() throws {
        let dir = try tempDir()
        defer { cleanup(dir) }
        // Minimal valid JSON payload plus whitespace to reach exactly 2MiB
        let base = "{\"formatVersion\":1,\"groups\":[]}"
        let paddingNeeded = 2 * 1024 * 1024 - base.utf8.count
        #expect(paddingNeeded >= 0)
        let whitespace = String(repeating: " ", count: paddingNeeded)
        let content = base + whitespace
        #expect(content.utf8.count == 2 * 1024 * 1024)
        let file = dir.appendingPathComponent("exact2m.json")
        try content.write(to: file, atomically: true, encoding: .utf8)
        let doc = try LayoutFileReader.readLayout(from: file)
        #expect(doc != nil)
    }

    // Above 2 MiB rejected and file left unchanged.
    @Test func above2MiBRejectedAndUnchanged() throws {
        let dir = try tempDir()
        defer { cleanup(dir) }
        let file = dir.appendingPathComponent("over.json")
        let oversized = Data(repeating: 0x20, count: 2 * 1024 * 1024 + 1)
        try oversized.write(to: file)
        do {
            _ = try LayoutFileReader.readLayout(from: file)
            Issue.record("Expected tooLarge")
        } catch LayoutFileReaderError.tooLarge {
            // expected
        }
        let after = try Data(contentsOf: file)
        #expect(after == oversized)
    }

    // Malformed file bytes preserved after read attempt.
    @Test func malformedFileBytesPreserved() throws {
        let dir = try tempDir()
        defer { cleanup(dir) }
        let file = dir.appendingPathComponent("badbytes.json")
        let original = Data([0x7B, 0x22, 0x66, 0x6F, 0x72, 0x6D, 0x61, 0x74, 0x22]) // partial "{\"format"
        try original.write(to: file)
        do {
            _ = try LayoutFileReader.readLayout(from: file)
            Issue.record("Expected invalidDocument")
        } catch LayoutFileReaderError.invalidDocument {
            // expected
        }
        let after = try Data(contentsOf: file)
        #expect(after == original)
    }

    // Read-cap enforcement via injected read seam; cumulative bytes requested/read never exceed cap+1.
    @Test func readCapEnforcementViaSeam() throws {
        let dir = try tempDir()
        defer { cleanup(dir) }
        // Fixture larger than cap so it hits maxRead and throws; counts must stay bounded.
        let file = dir.appendingPathComponent("cap.json")
        let oversized = Data(repeating: 0x20, count: 2 * 1024 * 1024 + 10)
        try oversized.write(to: file)
        let cap = 2 * 1024 * 1024
        let maxRead = cap + 1

        var requestedTotal = 0
        var readTotal = 0

        let recordedRead: (Int32, UnsafeMutablePointer<UInt8>, Int) -> Int = { fd, buf, count in
            requestedTotal += count
            let n = read(fd, buf, count)
            if n > 0 { readTotal += n }
            return n
        }

        do {
            _ = try LayoutFileReader.readLayout(from: file, readImpl: recordedRead)
            Issue.record("Expected tooLarge")
        } catch LayoutFileReaderError.tooLarge {
            // expected
        }
        // Verify cumulative requested/read never exceed cap+1 (includes partial reads / EINTR handling loop).
        #expect(requestedTotal <= maxRead, "Requested bytes \(requestedTotal) exceeded maxRead \(maxRead)")
        #expect(readTotal <= maxRead, "Read bytes \(readTotal) exceeded maxRead \(maxRead)")
        // Path never referenced in count assertions (no leakage).
    }
    @Test func remoteFileHostIsRejectedWithoutReadingLocalPath() throws {
        let dir = try tempDir()
        defer { cleanup(dir) }
        let file = dir.appendingPathComponent("layout.json")
        try Data(#"{"formatVersion":1,"groups":[]}"#.utf8).write(to: file)
        var components = URLComponents()
        components.scheme = "file"
        components.host = "remotehost.example"
        components.path = file.path
        let remoteURL = try #require(components.url)
        #expect(throws: LayoutFileReaderError.cannotRead) { try LayoutFileReader.readLayout(from: remoteURL) }
    }

    @Test func shortReadsAndInterruptedReadPreserveBound() throws {
        let dir = try tempDir()
        defer { cleanup(dir) }
        let file = dir.appendingPathComponent("layout.json")
        let original = Data(#"{"formatVersion":1,"groups":[]}"#.utf8)
        try original.write(to: file)
        var interrupted = false
        var totalRead = 0
        var calls = 0
        let spy: (Int32, UnsafeMutablePointer<UInt8>, Int) -> Int = { fd, buffer, requested in
            calls += 1
            #expect(requested <= 2 * 1024 * 1024 + 1 - totalRead)
            if !interrupted {
                interrupted = true
                errno = EINTR
                return -1
            }
            let n = read(fd, buffer, min(requested, 3))
            if n > 0 { totalRead += n }
            return n
        }
        let doc = try LayoutFileReader.readLayout(from: file, readImpl: spy)
        #expect(doc != nil)
        #expect(interrupted)
        #expect(calls > 2)
        #expect(totalRead == original.count)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func newerVersionWithNewSchemaRemainsUntouched() throws {
        let dir = try tempDir()
        defer { cleanup(dir) }
        let file = dir.appendingPathComponent("future.json")
        let original = Data(#"{"formatVersion":99,"futureField":{"format":"new"},"groups":{"future":"shape"}}"#.utf8)
        try original.write(to: file)
        #expect(throws: LayoutFileReaderError.unsupportedFormat) { try LayoutFileReader.readLayout(from: file) }
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func impossibleReadResultIsRejected() throws {
        let dir = try tempDir()
        defer { cleanup(dir) }
        let file = dir.appendingPathComponent("layout.json")
        try Data(#"{"formatVersion":1,"groups":[]}"#.utf8).write(to: file)
        let invalidReader: (Int32, UnsafeMutablePointer<UInt8>, Int) -> Int = { _, _, requested in requested + 1 }
        #expect(throws: LayoutFileReaderError.cannotRead) { try LayoutFileReader.readLayout(from: file, readImpl: invalidReader) }
    }

    @Test func fileGrowingDuringReadIsRejected() throws {
        let dir = try tempDir()
        defer { cleanup(dir) }
        let file = dir.appendingPathComponent("growing.json")
        let prefix = Data(#"{"formatVersion":1,"groups":[]}"#.utf8)
        var original = prefix
        original.append(Data(repeating: 0x20, count: 2 * 1024 * 1024 - prefix.count))
        try original.write(to: file)
        var grew = false
        let spy: (Int32, UnsafeMutablePointer<UInt8>, Int) -> Int = { fd, buffer, requested in
            let n = read(fd, buffer, requested)
            if n > 0 && !grew {
                grew = true
                do {
                    let handle = try FileHandle(forWritingTo: file)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data([0x20]))
                } catch {
                    Issue.record("Could not grow synthetic fixture")
                }
            }
            return n
        }
        #expect(throws: LayoutFileReaderError.tooLarge) { try LayoutFileReader.readLayout(from: file, readImpl: spy) }
        #expect(grew)
        #expect(try Data(contentsOf: file).count == original.count + 1)
    }


    @Test func relativeFileURLIsRejectedBeforeRead() throws {
        let url = try #require(URL(string: "file:missing-\(UUID().uuidString)/layout.json"))
        #expect(throws: LayoutFileReaderError.cannotRead) { try LayoutFileReader.readLayout(from: url) }
    }

}
