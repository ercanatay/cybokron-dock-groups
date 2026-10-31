import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Application static code slices")
struct ApplicationStaticCodeSliceVerifierTests {
    @Test func selectedUniversalBundleIncludesRunningSliceAndRejectsTampering() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Cybokron-slice-code-fixture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("Selected.app", isDirectory: true)
        let tampered = root.appendingPathComponent("Tampered.app", isDirectory: true)
        try createSignedBundle(at: selected)
        let hashes = try #require(ApplicationStaticCodeVerifier.codeHashes(for: selected))
        #expect(!hashes.isEmpty)
        #expect(hashes.count <= 16)
        #expect(Set(hashes).count == hashes.count)
        let executable = selected.appendingPathComponent("Contents/MacOS/Fixture")
        let attrs = try FileManager.default.attributesOfItem(atPath: executable.path)
        let fileSize = try #require((attrs[.size] as? NSNumber)?.uint64Value)
        let handle = try FileHandle(forReadingFrom: executable)
        let prefixData = try handle.read(upToCount: 520)
        try handle.close()
        let prefix = try #require(prefixData)
        let slices = try #require(MachOSliceTable.parse(prefix: prefix, fileSize: fileSize))
        #expect(hashes.count == slices.count)
        let process = Process()
        process.executableURL = selected.appendingPathComponent("Contents/MacOS/Fixture")
        process.arguments = ["20"]
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        let comparisons = hashes.map { ApplicationRunningCodeVerifier.compare(pid: process.processIdentifier, expected: $0) }
        #expect(comparisons.contains(.matching))
        try FileManager.default.copyItem(at: selected, to: tampered)
        let infoURL = tampered.appendingPathComponent("Contents/Info.plist")
        var info = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any])
        info["CFBundleName"] = "Tampered"
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
        #expect(ApplicationStaticCodeVerifier.codeHashes(for: tampered) == nil)
        #expect(ApplicationStaticCodeVerifier.codeHashes(for: URL(string: "https://example.invalid/Fake.app")!) == nil)
        #expect(ApplicationStaticCodeVerifier.codeHashes(for: URL(string: "file://invalid.example/Fake.app")!) == nil)
        let escaped = root.appendingPathComponent("Escaped.app", isDirectory: true)
        let escapedMacOS = escaped.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: escapedMacOS, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: escapedMacOS.appendingPathComponent("Fixture"), withDestinationURL: URL(fileURLWithPath: "/bin/sleep"))
        let escapedInfo: [String: Any] = ["CFBundleIdentifier": "com.cybokron.fixture.escape", "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: escapedInfo, format: .xml, options: 0).write(to: escaped.appendingPathComponent("Contents/Info.plist"))
        #expect(ApplicationStaticCodeVerifier.codeHashes(for: escaped) == nil)
    }

    private func createSignedBundle(at url: URL) throws {
        let dir = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: dir.appendingPathComponent("Fixture"))
        let plist: [String: Any] = ["CFBundleIdentifier": "com.cybokron.fixture.slices", "CFBundleName": "Slice Fixture", "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", url.path]
        sign.standardOutput = Pipe(); sign.standardError = Pipe()
        try sign.run(); sign.waitUntilExit()
        try #require(sign.terminationStatus == 0)
    }
}
