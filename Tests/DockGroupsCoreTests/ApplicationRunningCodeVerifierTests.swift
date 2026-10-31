import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Application running-code verification")
struct ApplicationRunningCodeVerifierTests {
    @Test func distinguishesSameIdentifierWithDifferentSignedCodeAndRejectsMissingProcess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Cybokron-running-code-fixture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("Selected.app", isDirectory: true)
        let other = root.appendingPathComponent("Other.app", isDirectory: true)
        try makeSignedBundle(at: selected, name: "Selected")
        try makeSignedBundle(at: other, name: "Other")
        let expected = try #require(ApplicationStaticCodeVerifier.codeHashes(for: selected)?.first)
        let different = try #require(ApplicationStaticCodeVerifier.codeHashes(for: other)?.first)
        #expect(expected != different)
        var children: [Process] = []
        defer {
            for process in children {
                if process.isRunning { process.terminate() }
                process.waitUntilExit()
            }
        }
        let first = try runSleeper(in: selected); children.append(first)
        let second = try runSleeper(in: other); children.append(second)
        #expect(ApplicationRunningCodeVerifier.compare(pid: first.processIdentifier, expected: expected, bundleIdentifier: "com.cybokron.fixture.running") == .matching)
        let wrongIdentifier = ApplicationRunningCodeVerifier.compare(pid: first.processIdentifier, expected: expected, bundleIdentifier: "com.cybokron.fixture.other")
        #expect(wrongIdentifier == .different)
        #expect(ApplicationIdentityCount.count([wrongIdentifier]) == nil)
        #expect(ApplicationRunningCodeVerifier.compare(pid: first.processIdentifier, expected: expected, bundleIdentifier: "x\" or anchor apple") == .unknown)
        let mismatch = ApplicationRunningCodeVerifier.compare(pid: second.processIdentifier, expected: expected, bundleIdentifier: "com.cybokron.fixture.running")
        #expect(mismatch == .different)
        #expect(ApplicationIdentityCount.count([mismatch]) == nil)
        #expect(ApplicationRunningCodeVerifier.compare(pid: 0, expected: expected, bundleIdentifier: "com.cybokron.fixture.running") == .unknown)
        #expect(ApplicationRunningCodeVerifier.compare(pid: -1, expected: expected, bundleIdentifier: "com.cybokron.fixture.running") == .unknown)
        #expect(ApplicationRunningCodeVerifier.compare(pid: Int32.max, expected: expected, bundleIdentifier: "com.cybokron.fixture.running") == .unknown)
    }

    private func makeSignedBundle(at url: URL, name: String) throws {
        let dir = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Use one architecture here. Universal-binary binding needs separate investigation:
        // the default static hash can differ from the running slice's hash.
        let thin = Process()
        thin.executableURL = URL(fileURLWithPath: "/usr/bin/lipo")
        #if arch(arm64)
        let architecture = "arm64e"
        #else
        let architecture = "x86_64"
        #endif
        thin.arguments = ["-thin", architecture, "/bin/sleep", "-output", dir.appendingPathComponent("Fixture").path]
        thin.standardOutput = Pipe(); thin.standardError = Pipe()
        try thin.run(); thin.waitUntilExit()
        try #require(thin.terminationStatus == 0)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.cybokron.fixture.running", "CFBundleName": name, "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
        let signing = Process()
        signing.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signing.arguments = ["--force", "--sign", "-", "-r", "=designated => identifier \"com.cybokron.fixture.running\"", url.path]
        signing.standardOutput = Pipe(); signing.standardError = Pipe()
        try signing.run(); signing.waitUntilExit()
        try #require(signing.terminationStatus == 0)
    }

    private func runSleeper(in url: URL) throws -> Process {
        let process = Process()
        process.executableURL = url.appendingPathComponent("Contents/MacOS/Fixture")
        process.arguments = ["20"]
        try process.run()
        return process
    }
}
