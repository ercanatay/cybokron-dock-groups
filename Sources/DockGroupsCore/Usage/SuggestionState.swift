import Foundation

/// A suggestion the user turned down: a set of apps for a new group, or one app for an existing
/// group. It's only ever compared with new suggestions; its apps are never launched or resolved.
public struct DismissedSuggestion: Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case newGroup
        case addToGroup
    }

    public var kind: Kind
    /// Lowercased bundle identifiers, sorted and without duplicates.
    public var apps: [String]
    /// The group an add-to-group suggestion was for; `nil` for a new group.
    public var group: UUID?
    /// Not suggested again before this moment; `nil` means never again.
    public var until: Date?

    public init(kind: Kind, apps: [String], group: UUID? = nil, until: Date? = nil) {
        self.kind = kind
        self.apps = Array(Set(apps.map(UsageStats.key(for:)))).sorted()
        self.group = group
        self.until = until
    }

    /// Whether the dismissal no longer holds at `now` (a timed one whose moment has passed).
    public func hasExpired(at now: Date) -> Bool {
        guard let until else { return false }
        return until <= now
    }
}

/// What Local Suggestions keep besides the usage statistics (`suggestions-state.json`, design
/// local-suggestions.md §2.2): when they were turned on, on how many local calendar days since then
/// a launch was recorded, and what the user turned down. Only a count and the last day are kept,
/// never a list of days.
public struct SuggestionState: Hashable, Sendable {
    public static let currentFormatVersion = 1
    /// At most this many dismissals are kept.
    public static let maxDismissed = 200

    /// When Suggestions were last turned on; `nil` while they never were (or the state was reset).
    public var enabledAt: Date?
    /// The number of distinct local calendar days since `enabledAt` with a recorded launch.
    public var activeDays: Int
    /// The last of those days, `yyyy-MM-dd` in the local calendar.
    public var lastActiveDay: String?
    /// Oldest first.
    public var dismissed: [DismissedSuggestion]

    public init(enabledAt: Date? = nil, activeDays: Int = 0, lastActiveDay: String? = nil, dismissed: [DismissedSuggestion] = []) {
        self.enabledAt = enabledAt
        self.activeDays = max(activeDays, 0)
        self.lastActiveDay = lastActiveDay.flatMap(Self.validDay)
        self.dismissed = dismissed
    }

    /// A fresh observation window starting at `now`: no active days yet; the dismissals stay.
    public mutating func start(at now: Date) {
        enabledAt = now
        activeDays = 0
        lastActiveDay = nil
    }

    /// Counts the local calendar day of `now` as an active day, once per day, and only from
    /// `enabledAt` on: nothing happens without `enabledAt`, before it, or on a day already counted
    /// (or earlier than the last one, when the clock went back).
    /// - Returns: Whether anything changed.
    @discardableResult
    public mutating func recordActivity(at now: Date, calendar: Calendar = .current) -> Bool {
        guard let enabledAt, now >= enabledAt else { return false }
        let today = Self.day(of: now, calendar: calendar)
        if let lastActiveDay, today <= lastActiveDay { return false }
        activeDays += 1
        lastActiveDay = today
        return true
    }

    /// Adds a dismissal after the others. Over `maxDismissed`, expired ones go first, oldest first;
    /// then the oldest of the rest.
    public mutating func addDismissal(_ dismissal: DismissedSuggestion, now: Date) {
        dismissed.append(dismissal)
        prune(now: now)
    }

    /// Keeps at most `maxDismissed` dismissals, as `addDismissal` does.
    public mutating func prune(now: Date) {
        while dismissed.count > Self.maxDismissed {
            if let index = dismissed.firstIndex(where: { $0.hasExpired(at: now) }) {
                dismissed.remove(at: index)
            } else {
                dismissed.removeFirst()
            }
        }
    }

    /// `yyyy-MM-dd` of `date` in `calendar`.
    public static func day(of date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// `value` when it has the `yyyy-MM-dd` shape, `nil` otherwise.
    static func validDay(_ value: String) -> String? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.map(\.count) == [4, 2, 2],
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } })
        else { return nil }
        return value
    }
}

// MARK: - Codable

extension SuggestionState: Codable {
    private enum CodingKeys: String, CodingKey {
        case formatVersion, enabledAt, activeDays, lastActiveDay, dismissed
    }

    /// Read leniently: unknown keys are ignored, a missing or malformed value is its default, and
    /// unreadable dismissals are skipped. The file must be a JSON object.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let enabledAt = container.decodeLeniently(Double.self, forKey: .enabledAt)
            .flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
        let dismissed = (container.decodeLeniently([LenientDismissal].self, forKey: .dismissed) ?? []).compactMap(\.value)
        self.init(
            enabledAt: enabledAt,
            activeDays: container.decodeLeniently(Int.self, forKey: .activeDays) ?? 0,
            lastActiveDay: container.decodeLeniently(String.self, forKey: .lastActiveDay),
            dismissed: Array(dismissed.suffix(Self.maxDismissed))
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentFormatVersion, forKey: .formatVersion)
        try container.encodeIfPresent(enabledAt?.timeIntervalSince1970, forKey: .enabledAt)
        try container.encode(activeDays, forKey: .activeDays)
        try container.encodeIfPresent(lastActiveDay, forKey: .lastActiveDay)
        try container.encode(dismissed, forKey: .dismissed)
    }
}

extension DismissedSuggestion: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, apps, group, until
    }

    /// A known kind and at least one app are required, and an add-to-group dismissal needs its
    /// group; `until` that isn't a number means never again.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let apps = (container.decodeLeniently([LenientString].self, forKey: .apps) ?? [])
            .compactMap(\.value)
            .filter { !$0.isEmpty }
        let group = container.decodeLeniently(UUID.self, forKey: .group)
        guard !apps.isEmpty, kind == .newGroup || group != nil else {
            throw DecodingError.dataCorruptedError(forKey: .apps, in: container, debugDescription: "Expected apps (and a group)")
        }
        let until = container.decodeLeniently(Double.self, forKey: .until)
            .flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
        self.init(kind: kind, apps: apps, group: kind == .addToGroup ? group : nil, until: until)
    }

    /// `until` is always written, `null` for never again.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(apps, forKey: .apps)
        try container.encodeIfPresent(group, forKey: .group)
        if let until {
            try container.encode(until.timeIntervalSince1970, forKey: .until)
        } else {
            try container.encodeNil(forKey: .until)
        }
    }
}

/// Decodes an array element without failing the array: unreadable elements become `nil`.
private struct LenientDismissal: Decodable {
    let value: DismissedSuggestion?

    init(from decoder: Decoder) throws {
        value = try? DismissedSuggestion(from: decoder)
    }
}

private struct LenientString: Decodable {
    let value: String?

    init(from decoder: Decoder) throws {
        value = try? String(from: decoder)
    }
}
