import Foundation

/// Why a trigger's occurrence didn't run (triggers spec §1.7–§1.9). Its `explanation` completes
/// "Skipped today at 9:00: …".
public enum TriggerSkipReason: String, CaseIterable, Sendable {
    case paused
    /// The hourly budget was used up: this pause started.
    case budget
    case notNow
    /// Ask First waited without an answer, or no notice could be shown.
    case noAnswer
    case cooldown
    case alreadyRanToday
    /// A display or network change right after an automatic action (the echo window).
    case rightAfterAutomaticAction
    /// Another trigger ran in its place (one Start wins, §1.8).
    case anotherTrigger
    /// The same thing for the same group was just done.
    case alreadyDone
    case notCurrentGroup
    /// "Finish when it ends": the current group wasn't started by this trigger.
    case notStartedByTrigger
    case groupMissing

    public var explanation: String {
        switch self {
        case .paused: return Localization.string("core.trigger.skip.paused", "triggers were paused")
        case .budget: return Localization.string("core.trigger.skip.budget", "triggers ran too often and were paused")
        case .notNow: return Localization.string("core.trigger.skip.notNow", "you chose Not Now")
        case .noAnswer: return Localization.string("core.trigger.skip.noAnswer", "nobody answered")
        case .cooldown: return Localization.string("core.trigger.skip.cooldown", "it ran less than a minute before")
        case .alreadyRanToday: return Localization.string("core.trigger.skip.alreadyRanToday", "it already ran today")
        case .rightAfterAutomaticAction: return Localization.string("core.trigger.skip.echo", "it came right after another automatic action")
        case .anotherTrigger: return Localization.string("core.trigger.skip.anotherTrigger", "another trigger ran instead")
        case .alreadyDone: return Localization.string("core.trigger.skip.alreadyDone", "that had just been done")
        case .notCurrentGroup: return Localization.string("core.trigger.skip.notCurrentGroup", "the group wasn't the current group")
        case .notStartedByTrigger: return Localization.string("core.trigger.skip.notStartedByTrigger", "the group wasn't started by this trigger")
        case .groupMissing: return Localization.string("core.trigger.skip.groupMissing", "the group no longer exists")
        }
    }
}

/// Why a time ran too late to run at all (more than 30 minutes, §1.10). Completes "Missed at 9:00: …".
public enum TriggerMissReason: String, CaseIterable, Sendable {
    case macAsleep
    case appNotOpen
    case sessionInactive

    public var explanation: String {
        switch self {
        case .macAsleep: return Localization.string("core.trigger.missed.macAsleep", "the Mac was asleep")
        case .appNotOpen: return Localization.string("core.trigger.missed.appNotOpen", "the app wasn't open")
        case .sessionInactive: return Localization.string("core.trigger.missed.sessionInactive", "another user was using the Mac")
        }
    }
}

/// What happened the last time a trigger's event came.
public enum TriggerOutcome: Hashable, Sendable {
    case ran(TriggerAction)
    case skipped(TriggerSkipReason)
    case missed(TriggerMissReason)
}

/// What the evaluator and the coordinator remember between events and launches, kept in
/// `trigger-state.json` (spec §2.7): a convenience like `update-state.json`, never in backups.
/// Losing it means only that today's past times count as handled (§1.10). A crafted file can at
/// most pause triggers or make occurrences count as handled: nothing in it makes a trigger run.
public struct TriggerState: Equatable, Sendable {
    /// The most run times kept for the budget.
    public static let maximumRecentRuns = 50

    public struct Entry: Equatable, Sendable {
        public var lastRunAt: Date?
        public var lastOutcome: TriggerOutcome?
        /// When `lastOutcome` happened: the occurrence of a time, or the moment for the others.
        public var lastOutcomeAt: Date?
        /// Times: the latest occurrence dealt with (run, skipped, missed or passed while off).
        public var lastHandledOccurrence: Date?
        /// Conditions: how many times it held at the last known reading; `nil` when unknown.
        public var condition: Int?

        public init(lastRunAt: Date? = nil, lastOutcome: TriggerOutcome? = nil, lastOutcomeAt: Date? = nil, lastHandledOccurrence: Date? = nil, condition: Int? = nil) {
            self.lastRunAt = lastRunAt
            self.lastOutcome = lastOutcome
            self.lastOutcomeAt = lastOutcomeAt
            self.lastHandledOccurrence = lastHandledOccurrence
            self.condition = condition
        }
    }

    public enum PauseReason: String, Sendable {
        /// Pause Triggers in the menu bar menu.
        case user
        /// The hourly budget was used up.
        case budget
    }

    public var entries: [GroupTrigger.ID: Entry]
    /// No trigger runs before this moment; `Date.distantFuture` until resumed.
    public var pausedUntil: Date?
    public var pauseReason: PauseReason?
    /// The login session At Login triggers last ran for.
    public var lastLoginSession: Date?
    /// A launch before this moment is quiet: written before an update's or a language change's
    /// relaunch.
    public var quietLaunchUntil: Date?
    /// When automatic actions ran, for the budget (the last hour's).
    public var recentRuns: [Date]

    public init(
        entries: [GroupTrigger.ID: Entry] = [:],
        pausedUntil: Date? = nil,
        pauseReason: PauseReason? = nil,
        lastLoginSession: Date? = nil,
        quietLaunchUntil: Date? = nil,
        recentRuns: [Date] = []
    ) {
        self.entries = entries
        self.pausedUntil = pausedUntil
        self.pauseReason = pauseReason
        self.lastLoginSession = lastLoginSession
        self.quietLaunchUntil = quietLaunchUntil
        self.recentRuns = Array(recentRuns.suffix(Self.maximumRecentRuns))
    }

    public func entry(for id: GroupTrigger.ID) -> Entry {
        entries[id] ?? Entry()
    }

    /// Whether triggers are paused at `date`.
    public func isPaused(at date: Date) -> Bool {
        guard let pausedUntil else { return false }
        return date < pausedUntil
    }

    /// Pauses every trigger until `date`.
    public mutating func pause(until date: Date, reason: PauseReason) {
        pausedUntil = date
        pauseReason = reason
    }

    public mutating func resume() {
        pausedUntil = nil
        pauseReason = nil
    }

    /// Records what happened to a trigger's event.
    mutating func record(_ outcome: TriggerOutcome, for id: GroupTrigger.ID, at date: Date) {
        var entry = self.entry(for: id)
        entry.lastOutcome = outcome
        entry.lastOutcomeAt = date
        entries[id] = entry
    }

    /// Records that a trigger's action ran at `date`: its last run, and one run for the budget.
    mutating func recordRun(_ action: TriggerAction, for id: GroupTrigger.ID, at date: Date) {
        var entry = self.entry(for: id)
        entry.lastRunAt = date
        entry.lastOutcome = .ran(action)
        entry.lastOutcomeAt = date
        entries[id] = entry
        recentRuns = Array((recentRuns + [date]).suffix(Self.maximumRecentRuns))
    }

    /// The state without the entries of triggers that are gone.
    public func keepingEntries(of ids: Set<GroupTrigger.ID>) -> TriggerState {
        var state = self
        state.entries = entries.filter { ids.contains($0.key) }
        return state
    }
}

// MARK: - Codable

extension TriggerOutcome: Codable {
    private enum CodingKeys: String, CodingKey {
        case ran, skipped, missed
    }

    /// `{"ran": "start"}`, `{"skipped": "paused"}`, `{"missed": "macAsleep"}`; anything else throws
    /// (and the entry keeps no outcome).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let action = container.decodeLeniently(String.self, forKey: .ran).flatMap(TriggerAction.init(rawValue:)) {
            self = .ran(action)
        } else if let reason = container.decodeLeniently(String.self, forKey: .skipped).flatMap(TriggerSkipReason.init(rawValue:)) {
            self = .skipped(reason)
        } else if let reason = container.decodeLeniently(String.self, forKey: .missed).flatMap(TriggerMissReason.init(rawValue:)) {
            self = .missed(reason)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown trigger outcome"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ran(let action): try container.encode(action.rawValue, forKey: .ran)
        case .skipped(let reason): try container.encode(reason.rawValue, forKey: .skipped)
        case .missed(let reason): try container.encode(reason.rawValue, forKey: .missed)
        }
    }
}

extension TriggerState.Entry: Codable {
    private enum CodingKeys: String, CodingKey {
        case lastRunAt, lastOutcome, lastOutcomeAt, lastHandledOccurrence, condition
    }

    /// Every value is optional; one that can't be read is left out. Dates are seconds since 1970.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func date(_ key: CodingKeys) -> Date? {
            container.decodeLeniently(Double.self, forKey: key).flatMap(TriggerState.date(fromSeconds:))
        }
        lastRunAt = date(.lastRunAt)
        lastOutcome = container.decodeLeniently(TriggerOutcome.self, forKey: .lastOutcome)
        lastOutcomeAt = date(.lastOutcomeAt)
        lastHandledOccurrence = date(.lastHandledOccurrence)
        condition = container.decodeLeniently(Int.self, forKey: .condition).flatMap { $0 >= 0 ? $0 : nil }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(lastRunAt?.timeIntervalSince1970, forKey: .lastRunAt)
        try container.encodeIfPresent(lastOutcome, forKey: .lastOutcome)
        try container.encodeIfPresent(lastOutcomeAt?.timeIntervalSince1970, forKey: .lastOutcomeAt)
        try container.encodeIfPresent(lastHandledOccurrence?.timeIntervalSince1970, forKey: .lastHandledOccurrence)
        try container.encodeIfPresent(condition, forKey: .condition)
    }
}

extension TriggerState: Codable {
    static let currentFormatVersion = 1

    private enum CodingKeys: String, CodingKey {
        case formatVersion, triggers, pausedUntil, pauseReason, lastLoginSession, quietLaunchUntil, recentRuns
    }

    /// A date from seconds since 1970; `nil` for values no date can have.
    static func date(fromSeconds seconds: Double) -> Date? {
        guard seconds.isFinite, abs(seconds) < 1e12 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Every value is optional and read leniently: entries with a key that isn't a trigger
    /// identifier, and values that can't be read, are left out.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func date(_ key: CodingKeys) -> Date? {
            container.decodeLeniently(Double.self, forKey: key).flatMap(Self.date(fromSeconds:))
        }
        var entries: [GroupTrigger.ID: Entry] = [:]
        for (key, value) in container.decodeLeniently([String: LenientEntry].self, forKey: .triggers) ?? [:] {
            guard let id = UUID(uuidString: key), let entry = value.entry else { continue }
            entries[id] = entry
        }
        let runs = (container.decodeLeniently([Double].self, forKey: .recentRuns) ?? []).compactMap(Self.date(fromSeconds:))
        self.init(
            entries: entries,
            pausedUntil: date(.pausedUntil),
            pauseReason: container.decodeLeniently(String.self, forKey: .pauseReason).flatMap(PauseReason.init(rawValue:)),
            lastLoginSession: date(.lastLoginSession),
            quietLaunchUntil: date(.quietLaunchUntil),
            recentRuns: runs
        )
        if pausedUntil != nil, pauseReason == nil {
            pauseReason = .user
        }
    }

    /// Dates as seconds since 1970, like the update state; entries by identifier.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentFormatVersion, forKey: .formatVersion)
        var triggers: [String: Entry] = [:]
        for (id, entry) in entries {
            triggers[id.uuidString] = entry
        }
        try container.encode(triggers, forKey: .triggers)
        try container.encodeIfPresent(pausedUntil.map { min($0.timeIntervalSince1970, 1e11) }, forKey: .pausedUntil)
        try container.encodeIfPresent(pausedUntil == nil ? nil : pauseReason?.rawValue, forKey: .pauseReason)
        try container.encodeIfPresent(lastLoginSession?.timeIntervalSince1970, forKey: .lastLoginSession)
        try container.encodeIfPresent(quietLaunchUntil?.timeIntervalSince1970, forKey: .quietLaunchUntil)
        if !recentRuns.isEmpty {
            try container.encode(recentRuns.map(\.timeIntervalSince1970), forKey: .recentRuns)
        }
    }

    /// An entry that can't be read is left out rather than making the file unreadable.
    private struct LenientEntry: Decodable {
        let entry: Entry?

        init(from decoder: Decoder) throws {
            entry = try? Entry(from: decoder)
        }
    }
}
