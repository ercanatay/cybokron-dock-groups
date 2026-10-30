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
