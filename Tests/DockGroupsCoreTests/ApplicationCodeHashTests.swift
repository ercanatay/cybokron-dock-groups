import Foundation
import Security
import Testing
@testable import DockGroupsCore

@Suite("Application code-hash candidate")
struct ApplicationCodeHashTests {
    @Test func acceptsExactlyTwentyBytesAndProducesBoundedRequirement() throws {
        let bytes = Array(UInt8(0)..<UInt8(20))
        let hash = try #require(ApplicationCodeHash(bytes: bytes))
        #expect(hash.hex == "000102030405060708090a0b0c0d0e0f10111213")
        #expect(hash.requirementExpression == "cdhash H\"000102030405060708090a0b0c0d0e0f10111213\"")
        #expect(ApplicationCodeHash(bytes: []) == nil)
        #expect(ApplicationCodeHash(bytes: [UInt8](repeating: 0, count: 19)) == nil)
        #expect(ApplicationCodeHash(bytes: [UInt8](repeating: 0, count: 21)) == nil)
    }

    @Test func generatedRequirementIsAcceptedByMacOS() throws {
        let hash = try #require(ApplicationCodeHash(bytes: Array(UInt8(0)..<UInt8(20))))
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(hash.requirementExpression as CFString, SecCSFlags(), &requirement)
        #expect(status == errSecSuccess)
        #expect(requirement != nil)
    }

    @Test func acceptsOnlyFortyASCIIHexDigits() throws {
        let uppercase = "ABCDEF0123456789ABCDEF0123456789ABCDEF01"
        let parsed = try #require(ApplicationCodeHash(hex: uppercase))
        #expect(parsed.hex == uppercase.lowercased())
        for invalid in ["", String(repeating: "0", count: 39), String(repeating: "0", count: 41), String(repeating: "ａ", count: 40), String(repeating: "0", count: 39) + "g", String(repeating: "0", count: 38) + "\n0", "\" or anchor apple or \"", String(repeating: "0", count: 40) + "\0"] {
            #expect(ApplicationCodeHash(hex: invalid) == nil)
        }
    }
}
