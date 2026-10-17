import Testing
@testable import DockGroupsCore

@Suite("Semantic version")
struct SemanticVersionTests {
    private func version(_ text: String) throws -> SemanticVersion {
        try #require(SemanticVersion(text))
    }

    @Test func parsesTagsWithOrWithoutPrefix() throws {
        #expect(try version("v0.5.0") == SemanticVersion(major: 0, minor: 5, patch: 0))
        #expect(try version("0.5.1") == SemanticVersion(major: 0, minor: 5, patch: 1))
        #expect(try version(" V1.2 ") == SemanticVersion(major: 1, minor: 2, patch: 0))
        #expect(try version("2") == SemanticVersion(major: 2, minor: 0, patch: 0))

        let beta = try version("v1.0.0-beta.2+exp.sha.5114f85")
        #expect(beta.prerelease == ["beta", "2"])
        #expect(beta.build == "exp.sha.5114f85")
        #expect(beta.isPrerelease)
        #expect(beta.description == "1.0.0-beta.2+exp.sha.5114f85")
        #expect(try version("v0.5.0").description == "0.5.0")
    }

    @Test(arguments: ["", "v", "1.2.3.4", "1..2", "a.b.c", "1.2.x", "-1.0.0", "1.2.3-", "1.2.3-be$ta", "1.2.3-alpha..1", "1.2.3+", "release-0.5"])
    func rejectsWhatIsNotAVersion(_ text: String) {
        #expect(SemanticVersion(text) == nil)
    }

    @Test func ordersByPrecedence() throws {
        // The example order from the Semantic Versioning 2.0 specification, plus releases after it.
        let ordered = try [
            "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2",
            "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1", "1.1.0", "1.10.0", "2.0.0",
        ].map(version)
        for (lower, higher) in zip(ordered, ordered.dropFirst()) {
            #expect(lower < higher, "\(lower) < \(higher)")
            #expect(!(higher < lower), "!(\(higher) < \(lower))")
        }
        // Numbers compare numerically, not as text.
        #expect(try version("0.9.9") < version("0.10.0"))
        #expect(try version("v0.5.0") < version("0.5.1"))
    }

    @Test func buildMetadataDoesNotCount() throws {
        let first = try version("1.0.0+001")
        let second = try version("1.0.0+20130313144700")
        #expect(first == second)
        #expect(!(first < second) && !(second < first))
        #expect(Set([first, second]).count == 1)
    }
}
