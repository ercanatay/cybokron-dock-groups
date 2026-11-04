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
    /// Advances on every accepted uncertain observation. Stale and duplicate observations never
    /// change it. A delivery captures it and treats any change as "my observation is outdated".
    private(set) var revision: UInt64 = 0
    private var revisionExhausted = false

    init() {}

    /// Whether `captured` is still the latest revision. Fails closed once the counter overflowed.
    func isCurrent(revision captured: UInt64) -> Bool {
        !revisionExhausted && revision == captured
    }

    private mutating func advanceRevision() {
        if revision == UInt64.max {
            // Can't tell revisions apart any more: fail closed, permanently.
            revisionExhausted = true
            isStopped = true
        } else {
            revision += 1
        }
    }

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

    /// Whether a generation is running (not stopped, and begun since the last configuration change).
    var isObserving: Bool { !isStopped && currentGeneration != nil }

    func isActive(generation: UInt64) -> Bool {
        !isStopped && currentGeneration == generation
    }

    mutating func stop() {
        isStopped = true
        for key in trackers.keys {
            trackers[key] = AppPresenceTracker(generation: currentGeneration ?? 1)
        }
    }

    /// The result of an accepted snapshot.
    struct Observation: Equatable, Sendable {
        /// Rules whose edge fired. Always empty when `isUncertain`.
        var firedRuleIDs: [UUID] = []
        /// The snapshot was accepted but can't be trusted: a sequence gap, or a configured rule's
        /// count is missing or negative. All baselines were reset.
        var isUncertain = false
        /// The snapshot was accepted (active, current generation, newer sequence).
        var isAccepted = false
    }

    @discardableResult
    mutating func observe(generation: UInt64, sequence: UInt64, counts: [String: Int]) -> [UUID] {
        process(generation: generation, sequence: sequence, counts: counts, failClosed: false).firedRuleIDs
    }

    /// Like `observe`, but reports uncertainty. On an uncertain snapshot every baseline is reset
    /// and nothing fires; the next reliable snapshot only establishes the baseline.
    mutating func observeDetailed(generation: UInt64, sequence: UInt64, counts: [String: Int]) -> Observation {
        process(generation: generation, sequence: sequence, counts: counts, failClosed: true)
    }

    private mutating func process(generation: UInt64, sequence: UInt64, counts: [String: Int], failClosed: Bool) -> Observation {
        guard !isStopped else { return Observation() }
        guard let current = currentGeneration, generation == current else { return Observation() }

        var gap = false
        if let last = lastSequence {
            guard sequence > last else { return Observation() }
            if last != UInt64.max, last + 1 != sequence {
                gap = true
                for key in trackers.keys {
                    trackers[key] = AppPresenceTracker(generation: current)
                }
            }
        }

        lastSequence = sequence

        if failClosed {
            let missing = rules.contains { rule in
                guard let count = counts[rule.identifier.matchKey] else { return true }
                return count < 0
            }
            if gap || missing {
                for rule in rules {
                    trackers[rule.id] = AppPresenceTracker(generation: current)
                }
                advanceRevision()
                return Observation(firedRuleIDs: [], isUncertain: true, isAccepted: true)
            }
        }

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

        return Observation(firedRuleIDs: emitted, isUncertain: false, isAccepted: true)
    }
}
