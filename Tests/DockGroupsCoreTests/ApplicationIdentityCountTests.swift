import Testing
@testable import DockGroupsCore

@Suite("Application identity presence count")
struct ApplicationIdentityCountTests {
    @Test func onlyFullyVerifiedObservationsProduceCounts() {
        #expect(ApplicationIdentityCount.count([]) == 0)
        #expect(ApplicationIdentityCount.count([.matching]) == 1)
        #expect(ApplicationIdentityCount.count([.matching, .matching]) == 2)
        #expect(ApplicationIdentityCount.count([.different]) == nil)
        #expect(ApplicationIdentityCount.count([.unknown]) == nil)
        #expect(ApplicationIdentityCount.count([.matching, .different]) == nil)
        #expect(ApplicationIdentityCount.count([.matching, .unknown]) == nil)
        #expect(ApplicationIdentityCount.count([.different, .unknown]) == nil)
    }
}
