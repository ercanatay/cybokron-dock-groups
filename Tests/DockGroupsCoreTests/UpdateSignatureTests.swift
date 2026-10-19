import Foundation
import Testing
@testable import DockGroupsCore

/// `UpdateInstaller.verifySignature`: the staged app's signature must be intact; a Developer ID
/// one must come from the running app's team, an ad hoc one has no signer to compare.
@Suite("Update signature check")
struct UpdateSignatureTests {
    /// Answers codesign calls as for an app signed with `requirement` and `details`, verifying with
    /// `verification`.
    final class FakeCodesign: ToolRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = []
        let verification: ToolResult
        let requirement: String
        let details: String

        init(verification: ToolResult = ToolResult(status: 0, output: ""), requirement: String, details: String) {
            self.verification = verification
            self.requirement = requirement
            self.details = details
        }

        var calls: [[String]] { lock.withLock { _calls } }

        func run(_ tool: URL, arguments: [String]) async throws -> ToolResult {
            lock.withLock { _calls.append(arguments) }
            guard tool == SystemTools.codesign else { return ToolResult(status: 1, output: "unexpected tool") }
            switch arguments.first {
            case "--verify": return verification
            case "-d": return ToolResult(status: 0, output: "Executable=/x/Contents/MacOS/x\n" + requirement)
            case "-dv": return ToolResult(status: 0, output: details)
            default: return ToolResult(status: 1, output: "unexpected arguments")
            }
        }
    }

    static let adHocRequirement = #"# designated => cdhash H"df808d7764783089ace6886a3ab7fc81fe9eae6e" or cdhash H"4feb446bc89811a3317ae7f38d3f53c1c3d969fc""#
    static let adHocDetails = "Identifier=com.cybokron.dockgroups\nCodeDirectory v=20400 size=262 flags=0x2(adhoc) hashes=2+3 location=embedded\nSignature=adhoc\nTeamIdentifier=not set"

    static func developerIDRequirement(team: String) -> String {
        #"designated => anchor apple generic and identifier "com.cybokron.dockgroups" and (certificate leaf[field.1.2.840.113635.100.6.1.9] /* exists */ or certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = "\#(team)")"#
    }

    static func developerIDDetails(team: String) -> String {
        "Identifier=com.cybokron.dockgroups\nAuthority=Developer ID Application: Example (\(team))\nAuthority=Developer ID Certification Authority\nAuthority=Apple Root CA\nTeamIdentifier=\(team)"
    }

    private let app = URL(fileURLWithPath: "/tmp/staging/Cybokron Dock Groups.app", isDirectory: true)

    private func installer(_ tools: ToolRunning) -> UpdateInstaller {
        UpdateInstaller(directories: UpdateDirectories(root: URL(fileURLWithPath: "/tmp/unused")), tools: tools)
    }

    // MARK: - Simulated codesign

    @Test func adHocSignaturesSkipTheTeamCheck() async throws {
        let tools = FakeCodesign(requirement: Self.adHocRequirement, details: Self.adHocDetails)

        try await installer(tools).verifySignature(ofStagedApp: app, expectedTeamIdentifier: "AAAAA11111")
        try await installer(tools).verifySignature(ofStagedApp: app, expectedTeamIdentifier: nil)

        #expect(tools.calls.first == ["--verify", "--strict", app.path])
    }

    @Test func developerIDSignaturesMustComeFromTheRunningTeam() async throws {
        let tools = FakeCodesign(requirement: Self.developerIDRequirement(team: "AAAAA11111"), details: Self.developerIDDetails(team: "AAAAA11111"))

        try await installer(tools).verifySignature(ofStagedApp: app, expectedTeamIdentifier: "AAAAA11111")
        await #expect(throws: UpdateInstallError.wrongSigner(found: "AAAAA11111", expected: "BBBBB22222")) {
            try await installer(tools).verifySignature(ofStagedApp: app, expectedTeamIdentifier: "BBBBB22222")
        }
        // A running copy signed ad hoc has no team to hold the update to.
        try await installer(tools).verifySignature(ofStagedApp: app, expectedTeamIdentifier: nil)
    }

    @Test func aBrokenSignatureIsRefused() async {
        let tools = FakeCodesign(
            verification: ToolResult(status: 1, output: "/tmp/x.app: a sealed resource is missing or invalid"),
            requirement: Self.adHocRequirement,
            details: Self.adHocDetails
        )

        await #expect(throws: UpdateInstallError.invalidSignature("/tmp/x.app: a sealed resource is missing or invalid")) {
            try await installer(tools).verifySignature(ofStagedApp: app, expectedTeamIdentifier: nil)
        }
        #expect(tools.calls.count == 1, "nothing more is asked of a broken signature")
    }

    @Test func signaturesAreReadFromCodesignsOutput() {
        let adHoc = CodeSignature(requirementOutput: Self.adHocRequirement, detailsOutput: Self.adHocDetails)
        let developerID = CodeSignature(requirementOutput: Self.developerIDRequirement(team: "AAAAA11111"), detailsOutput: Self.developerIDDetails(team: "AAAAA11111"))

        #expect(adHoc == CodeSignature(isAppleAnchored: false, teamIdentifier: nil))
        #expect(adHoc.signingTeam == nil)
        #expect(developerID == CodeSignature(isAppleAnchored: true, teamIdentifier: "AAAAA11111"))
        #expect(developerID.signingTeam == "AAAAA11111")
        // A team without Apple's anchor vouches for nothing.
        #expect(CodeSignature(requirementOutput: Self.adHocRequirement, detailsOutput: "TeamIdentifier=CCCCC33333").signingTeam == nil)
    }

    @Test func messagesNameTheProblem() {
        #expect(UpdateInstallError.invalidSignature("code object is not signed at all").localizedDescription
            == "The downloaded app's code signature isn't valid, so it wasn't installed: code object is not signed at all")
        #expect(UpdateInstallError.wrongSigner(found: "AAAAA11111", expected: "BBBBB22222").localizedDescription
            == "The downloaded app is signed by another developer (team AAAAA11111 instead of BBBBB22222), so it wasn't installed.")
    }

    // MARK: - Real codesign

    /// An app bundle whose executable is a copy of `/usr/bin/true` (a real Mach-O), signed ad hoc
    /// as the releases are.
    private func signedApp(in temporary: TemporaryDirectory) async throws -> URL {
        let app = temporary.url.appending(path: "Cybokron Dock Groups.app", directoryHint: .isDirectory)
        let macOS = app.appending(components: "Contents", "MacOS", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appending(path: "Cybokron Dock Groups"))
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.cybokron.dockgroups",
            "CFBundleShortVersionString": "0.7.0",
            "CFBundleExecutable": "Cybokron Dock Groups",
            "CFBundlePackageType": "APPL",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appending(components: "Contents", "Info.plist"))
        let signing = try await SystemToolRunner().run(SystemTools.codesign, arguments: ["--force", "--sign", "-", app.path])
        try #require(signing.succeeded, "\(signing.output)")
        return app
    }

    @Test func anIntactAdHocSignaturePasses() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let app = try await signedApp(in: temporary)
        let installer = installer(SystemToolRunner())

        try await installer.verifySignature(ofStagedApp: app, expectedTeamIdentifier: "AAAAA11111")
        #expect(await installer.signature(ofAppAt: app) == CodeSignature(isAppleAnchored: false, teamIdentifier: nil))
    }

    @Test func aModifiedAppIsRefused() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let app = try await signedApp(in: temporary)
        let plist = app.appending(components: "Contents", "Info.plist")
        let handle = try FileHandle(forWritingTo: plist)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("<!-- changed -->\n".utf8))
        try handle.close()

        await #expect(throws: UpdateInstallError.self) {
            try await installer(SystemToolRunner()).verifySignature(ofStagedApp: app, expectedTeamIdentifier: nil)
        }
    }

    @Test func anUnsignedAppIsRefused() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let app = try temporary.makeScriptAppBundle(named: "Unsigned")

        do {
            try await installer(SystemToolRunner()).verifySignature(ofStagedApp: app, expectedTeamIdentifier: nil)
            Issue.record("an unsigned app passed")
        } catch let UpdateInstallError.invalidSignature(reason) {
            #expect(reason.contains("not signed"))
        }
    }
}
