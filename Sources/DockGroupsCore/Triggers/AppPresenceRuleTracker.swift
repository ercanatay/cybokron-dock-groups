import Foundation

internal struct AppPresenceRuleTracker {
    struct Rule: Equatable, Sendable {
        let id: UUID
        let identifier: TriggerApplicationIdentifier
        let edge: TriggerEdge
    }

    private var rules: [Rule] = []
    private var trackers: [UUID: AppPresenceTracker] = [:]
    private var highWaterToken: UInt64?
    private var currentGeneration: UInt64?
    private var lastSequence: UInt64?
    private var isStopped = false

    init() {}

    @discardableResult
    mutating func configure(_ newRules: [Rule]) -> Bool {
        if newRules.count > 100 {
            rules = []
            trackers = [:]
            currentGeneration = nil
            lastSequence = nil
            isStopped = true
            return false
        }
        let ids = newRules.map { $0.id }
        if Set(ids).count != ids.count {
            rules = []
            trackers = [:]
            currentGeneration = nil
            lastSequence = nil
            isStopped = true
            return false
        }

        func unchanged(_ a: [Rule], _ b: [Rule]) -> Bool {
            guard a.count == b.count else { return false }
            for (old, new) in zip(a, b) {
                guard old.id == new.id else { return false }
                guard old.identifier.rawValue == new.identifier.rawValue else { return false }
                guard old.edge == new.edge else { return false }
            }
            return true
        }

        if unchanged(rules, newRules) {
            rules = newRules
            return true
        }

        isStopped = true
        currentGeneration = nil
        lastSequence = nil
        trackers = [:]
        rules = newRules
        return true
    }

    @discardableResult
    mutating func beginGeneration(_ token: UInt64) -> Bool {
        if let hwt = highWaterToken {
            guard token > hwt else { return false }
        }
        highWaterToken = token
        currentGeneration = token
        lastSequence = nil
        isStopped = false
        for key in trackers.keys {
            trackers[key] = AppPresenceTracker(generation: token)
        }
        return true
    }

    func isActive(generation: UInt64) -> Bool {
        !isStopped && currentGeneration == generation
    }

    mutating func stop() {
        isStopped = true
        for key in trackers.keys {
            trackers[key] = AppPresenceTracker(generation: currentGeneration ?? 1)
        }
    }

    @discardableResult
    mutating func observe(generation: UInt64, sequence: UInt64, counts: [String: Int]) -> [UUID] {
        guard !isStopped else { return [] }
        guard let current = currentGeneration, generation == current else { return [] }

        if let last = lastSequence {
            guard sequence > last else { return [] }
            if last != UInt64.max, last + 1 != sequence {
                for key in trackers.keys {
                    trackers[key] = AppPresenceTracker(generation: current)
                }
            }
        }

        lastSequence = sequence

        var emitted: [UUID] = []
        for rule in rules {
            let matchKey = rule.identifier.matchKey
            let rawCount = counts[matchKey]

            if rawCount == nil || rawCount! < 0 {
                trackers[rule.id] = AppPresenceTracker(generation: current)
                continue
            }

            let countVal = rawCount!
            var tracker = trackers[rule.id] ?? AppPresenceTracker(generation: current)
            if tracker.generation != current {
                tracker = AppPresenceTracker(generation: current)
            }

            let edge = tracker.observe(count: countVal, generation: current)
            if let edge = edge {
                if (rule.edge == .starts && edge == .opened)
                    || (rule.edge == .ends && edge == .closed) {
                    emitted.append(rule.id)
                }
            }
            trackers[rule.id] = tracker
        }

        return emitted
    }
}
