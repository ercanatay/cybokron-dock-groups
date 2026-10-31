import Foundation
import Security
import Testing
@testable import DockGroupsCore

@Suite("Application code requirement construction")
struct ApplicationCodeRequirementTests {
    @Test func buildsRequirementOnlyFromValidIdentifierAndHash() throws {
        let hash = try #require(ApplicationCodeHash(bytes: Array(UInt8(0)..<UInt8(20))))
        let expression = try #require(ApplicationCodeRequirement.expression(bundleIdentifier: "Com.Example-App", codeHash: hash))
        #expect(expression == "identifier \"Com.Example-App\" and cdhash H\"000102030405060708090a0b0c0d0e0f10111213\"")
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(expression as CFString, SecCSFlags(), &requirement)
        #expect(status == errSecSuccess)
        #expect(requirement != nil)
    }

    @Test func rejectsIdentifiersThatCouldInjectRequirements() throws {
        let hash = try #require(ApplicationCodeHash(bytes: [UInt8](repeating: 0, count: 20)))
        for invalid in ["", "...---", "com.example\" or anchor apple", "com.example\napp", "com.exaKple.app", "com.example_app", String(repeating: "a", count: 256)] {
            #expect(ApplicationCodeRequirement.expression(bundleIdentifier: invalid, codeHash: hash) == nil)
        }
    }
}
