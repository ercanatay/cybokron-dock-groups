import Foundation

/// Unused experimental aggregation for identity comparison results.
///
/// Mismatch is treated as `.unknown` because it may represent an update rather
/// than a definitive mismatch. Callers must independently validate snapshot
/// completeness, process lifetimes, and source generation. This is not
/// production-ready and must not be integrated with production logic.
internal enum ApplicationIdentityCount {

    /// Returns the count of verified matching identities, or `nil` if any
    /// element is `.different` or `.unknown`.
    ///
    /// - Parameter identities: A snapshot of comparison results.
    /// - Returns: `identities.count` (including `0` for an empty verified snapshot),
    ///   or `nil` if any comparison is not `.matching`.
    static func count(_ identities: [ApplicationRunningCodeVerifier.Comparison]) -> Int? {
        for identity in identities {
            if identity == .different || identity == .unknown {
                return nil
            }
        }
        return identities.count
    }
}
