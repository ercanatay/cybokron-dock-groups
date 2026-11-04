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
///
/// A hash-only `compare(pid:expected:)` overload previously existed and has been removed.
/// A code hash alone is insufficient to authorize a trigger or prove process identity,
/// so the remaining `compare(pid:expected:bundleIdentifier:)` must not be treated as proof of either.
internal enum ApplicationRunningCodeVerifier {
    internal enum Comparison: Equatable { case matching, different, unknown }

    /// Experimental overload: constructs the requirement expression ONLY via
    /// `ApplicationCodeRequirement.expression(bundleIdentifier:codeHash:)`.
    /// Returns `.unknown` for invalid input. Not authorization.
    static func compare(pid: Int32, expected: ApplicationCodeHash, bundleIdentifier: String) -> Comparison {
        guard let expression = ApplicationCodeRequirement.expression(bundleIdentifier: bundleIdentifier, codeHash: expected) else {
            return .unknown
        }
        return verify(pid: pid, expression: expression)
    }

    /// Shared dynamic Security check. Takes an already-constructed expression string
    /// (never arbitrary unvalidated input from external callers). Validates pid,
    /// builds SecRequirement, obtains SecCode by pid, checks validity with a nil
    /// requirement first, then the supplied constructed requirement.
    /// Returns `.matching` on success, `.different` only for errSecCSReqFailed,
    /// otherwise `.unknown`. Preserves warnings about process identity races,
    /// authorization limits, and no integration.
    private static func verify(pid: Int32, expression: String) -> Comparison {
        guard pid > 0 else { return .unknown }

        var requirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(expression as CFString, SecCSFlags(), &requirement)
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
