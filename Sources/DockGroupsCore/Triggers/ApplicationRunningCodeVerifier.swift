import Foundation
import Security

/// Unused synchronous experimental primitive for verifying that a running process
/// matches a locally authorized expected code hash. This is not authorization,
/// publisher trust, or evidence of a close; it only compares a pid's code to an
/// expected value under a requirement built from `ApplicationCodeHash`.
///
/// PID reuse, process lifetime, locally authorized expected values, races, async
/// cancellation, publisher trust, and the current rules must be handled by the caller.
/// This alone does not authenticate any app or verify any specific process identity.
internal enum ApplicationRunningCodeVerifier {
    internal enum Comparison: Equatable { case matching, different, unknown }

    static func compare(pid: Int32, expected: ApplicationCodeHash) -> Comparison {
        guard pid > 0 else { return .unknown }

        var requirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(expected.requirementExpression as CFString, SecCSFlags(), &requirement)
        guard let requirement, requirementStatus == errSecSuccess else { return .unknown }

        var code: SecCode?
        let status = SecCodeCopyGuestWithAttributes(
            nil,
            [kSecGuestAttributePid as String: Int(pid)] as CFDictionary,
            SecCSFlags(),
            &code
        )
        guard let code, status == errSecSuccess else { return .unknown }

        let validityStatus = SecCodeCheckValidity(code, SecCSFlags(), nil)
        if validityStatus != errSecSuccess { return .unknown }

        let checkStatus = SecCodeCheckValidity(code, SecCSFlags(), requirement)
        switch checkStatus {
        case errSecSuccess: return .matching
        case errSecCSReqFailed: return .different
        default: return .unknown
        }
    }
}
