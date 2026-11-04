import Foundation
import Testing
@testable import CybokronDockGroups

@Test @MainActor func sourceDefaultsToStrictAndCanOptInForOneStart() async throws {
    var snapshots: [UInt64: [String: Int]] = [:]
    let source = ApplicationPresenceSource(readIdentifiers: { _ in [nil, "COM.EXAMPLE.APP"] }) { generation, _, counts in
        snapshots[generation] = counts
    }
    for generation: UInt64 in 1...3 {
        if generation == 2 {
            source.start(keys: ["com.example.app"], generation: generation, ignoreUnidentified: true)
        } else {
            source.start(keys: ["com.example.app"], generation: generation)
        }
        for _ in 0..<40 {
            if snapshots[generation] != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(snapshots[generation] != nil)
    }
    source.stop()
    #expect(snapshots[1] == [:])
    #expect(snapshots[2] == ["com.example.app": 1])
    #expect(snapshots[3] == [:])
}

@Test @MainActor func stopDropsQueuedInitialObservation() async throws {
    var count = 0
    let source = ApplicationPresenceSource { _, _, _ in count += 1 }
    source.start(keys: ["com.cybokronfixture.normal"], generation: 1)
    source.stop()
    try await Task.sleep(for: .milliseconds(100))
    #expect(count == 0)
}

@Test @MainActor func restartDropsQueuedInitialObservation() async throws {
    var seen: [(UInt64, UInt64)] = []
    let source = ApplicationPresenceSource { generation, sequence, _ in
        seen.append((generation, sequence))
    }
    source.start(keys: ["com.cybokronfixture.normal"], generation: 1)
    source.stop()
    source.start(keys: ["com.cybokronfixture.normal"], generation: 2)
    for _ in 0..<40 {
        if !seen.isEmpty { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    source.stop()
    #expect(!seen.isEmpty)
    #expect(seen.allSatisfy { $0.0 == 2 })
    #expect(seen.first?.1 == 1)
}
