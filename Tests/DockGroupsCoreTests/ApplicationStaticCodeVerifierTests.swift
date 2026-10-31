import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Application static-code verification")
struct ApplicationStaticCodeVerifierTests {
    @Test func acceptsValidSignedBundleAndRejectsUnsignedOrTamperedCopies() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Cybokron-signature-fixture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let signed = root.appendingPathComponent("Signed.app", isDirectory: true)
        let unsigned = root.appendingPathComponent("Unsigned.app", isDirectory: true)
        let unsealed = root.appendingPathComponent("Unsealed.app", isDirectory: true)
        let tampered = root.appendingPathComponent("Tampered.app", isDirectory: true)
        try createBundle(at: signed)
        try createBundle(at: unsigned)
        try createBundle(at: unsealed)
        let strip = Process()
        strip.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        strip.arguments = ["--remove-signature", unsigned.path]
        strip.standardOutput = Pipe()
        strip.standardError = Pipe()
        try strip.run()
        strip.waitUntilExit()
        try #require(strip.terminationStatus == 0)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", signed.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        let valid = try #require(ApplicationStaticCodeVerifier.codeHash(for: signed))
        #expect(valid.hex.utf8.count == 40)
        #expect(ApplicationStaticCodeVerifier.codeHash(for: unsigned) == nil)
        #expect(ApplicationStaticCodeVerifier.codeHash(for: unsealed) == nil)
        try FileManager.default.copyItem(at: signed, to: tampered)
        let infoURL = tampered.appendingPathComponent("Contents/Info.plist")
        var info = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any])
        info["CFBundleName"] = "Modified After Signing"
        let changed = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try changed.write(to: infoURL)
        #expect(ApplicationStaticCodeVerifier.codeHash(for: tampered) == nil)
        #expect(ApplicationStaticCodeVerifier.codeHash(for: URL(string: "https://example.invalid/Fake.app")!) == nil)
    }

    private func createBundle(at url: URL) throws {
        let macOS = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent("Fixture"))
        let plist: [String: Any] = ["CFBundleIdentifier": "com.cybokron.fixture.signature", "CFBundleName": "Signature Fixture", "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
    }
}
