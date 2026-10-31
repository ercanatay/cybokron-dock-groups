/// Empty result signals unknown if any identifier is nil or empty; global fail-closed policy is provisional and can disable all triggers.
public enum ApplicationSnapshotCounter {
    public static func counts(keys: Set<String>, identifiers: [String?]) -> [String: Int] {
        guard identifiers.allSatisfy({ ($0 ?? "").isEmpty == false }) else { return [:] }
        guard !keys.isEmpty else { return [:] }
        var result: [String: Int] = [:]
        for key in keys {
            result[key.lowercased()] = 0
        }
        for id in identifiers {
            guard let id = id else { return [:] }
            let lower = id.lowercased()
            if result.keys.contains(lower) {
                result[lower, default: 0] += 1
            }
        }
        return result
    }
}

internal struct AppPresenceTracker {
    private(set) var generation: UInt64
    private var baseline: Int?
    private var isDeactivated = false

    init(generation: UInt64 = 1) {
        self.generation = generation
        self.baseline = nil
        self.isDeactivated = false
    }

    @discardableResult
    mutating func beginGeneration() -> UInt64? {
        guard !isDeactivated, generation < UInt64.max else {
            isDeactivated = true
            baseline = nil
            return nil
        }
        generation += 1
        baseline = nil
        return generation
    }

    mutating func invalidate() {
        baseline = nil
    }

    mutating func observe(count: Int?, generation: UInt64) -> Edge? {
        guard !isDeactivated, generation == self.generation else { return nil }
        if let count = count, count >= 0 {
            if baseline == nil {
                baseline = count
                return nil
            }
            guard count != baseline else { return nil }
            let previous = baseline!
            baseline = count
            if previous == 0 && count > 0 {
                return .opened
            }
            if previous > 0 && count == 0 {
                return .closed
            }
            return nil
        } else {
            baseline = nil
            return nil
        }
    }

    enum Edge {
        case opened
        case closed
    }
}
