import CryptoKit
import Foundation
import OSLog

// Launch actions: the approval record (threat model D9): docs/design/launch-action-approvals.md.
//
// An action that's on in a groups file (or a standalone group's configuration) runs only when this
// Mac's approval file has the digest of exactly that action for exactly that item. The file is
// written only when the user turns an action on in the group window, and lives apart from the
// groups, so a groups file, backup, template or configuration copied from elsewhere brings no
// approval with it. This file reads, writes and compares; it opens nothing.

/// One approval: the identity of the item (as `AppReference.normalizedBundleIdentifier` has it)
/// and the digest of the action the user turned on for it (`LaunchActionApprovalDigest`).
struct LaunchActionApproval: Hashable, Sendable {
    let item: String
    let digest: String
}

/// The approvals of this Mac, as `launch-action-approvals.json` keeps them:
/// `{"formatVersion": 1, "approvals": [{"item": "https://github.com/cybokron", "digest": "<sha256>"}]}`.
///
/// An item can have more than one record (the same website in two groups with different profiles);
/// a record only counts for the item and digest it names.
struct LaunchActionApprovals: Hashable, Sendable {
    static let currentFormatVersion = 1

    var records: Set<LaunchActionApproval>

    init(_ records: Set<LaunchActionApproval> = []) {
        self.records = records
    }

    var isEmpty: Bool { records.isEmpty }

    /// What the approvals say about `item`'s action (`LaunchActionApprovalCheck`).
    func check(_ item: GroupItem) -> LaunchActionApprovalCheck {
        guard let digest = LaunchActionApprovalDigest.digest(for: item) else { return .noAction }
        let identity = item.normalizedBundleIdentifier
        if records.contains(LaunchActionApproval(item: identity, digest: digest)) { return .approved }
        return records.contains { $0.item == identity } ? .mismatch : .missing
    }

    /// `item` as the store keeps it on this Mac: an action that's on but whose digest isn't approved
    /// here is under review instead, as an imported one is (D4), so the window shows it for review
    /// and the item isn't opened. Anything else is kept as it is (an action that's on but not valid
    /// for the item never runs anyway: the launcher's plan refuses it).
    func requiringApproval(_ item: GroupItem) -> GroupItem {
        guard case .enabled(let action)? = item.launchActionSetting else { return item }
        switch check(item) {
        case .approved, .noAction: return item
        case .missing, .mismatch: break
        }
        var item = item
        item.launchActionSetting = .needsReview(.imported(action))
        return item
    }

    /// `group` with every item `requiringApproval`.
    func requiringApproval(_ group: DockGroup) -> DockGroup {
        guard group.apps.contains(where: Self.isOn) else { return group }
        var group = group
        group.apps = group.apps.map(requiringApproval)
        return group
    }

    /// The approvals still in use by one of `items`: an action that's on and approved. The others
    /// (an action turned off or changed, an item or group removed) are dropped.
    func keepingOnlyThoseOf(_ items: [GroupItem]) -> LaunchActionApprovals {
        let used = Set(items.filter(Self.isOn).compactMap { item in
            LaunchActionApprovalDigest.digest(for: item).map { LaunchActionApproval(item: item.normalizedBundleIdentifier, digest: $0) }
        })
        return LaunchActionApprovals(records.intersection(used))
    }

    /// Whether the item has an action that's on, valid or not.
    static func isOn(_ item: GroupItem) -> Bool {
        if case .enabled? = item.launchActionSetting { return true }
        return false
    }
}

/// What the approvals say about an item's action.
enum LaunchActionApprovalCheck: Hashable, Sendable {
    /// The digest of exactly this action for this item is approved.
    case approved
    /// No record for this item.
    case missing
    /// Records for this item, but none with this digest: the action, its address, browser or
    /// profile changed since it was approved.
    case mismatch
    /// The item has no action that's on and valid, so there's nothing to approve.
    case noAction
}

/// Why an item's launch action wasn't run for want of an approval. Fixed reasons that hold nothing
/// from the item, so they can be logged.
enum LaunchActionApprovalRefusal: String, Error, CaseIterable, Hashable, Sendable {
    /// The approval file has no record for the item (none was given on this Mac, or the file is
    /// missing or can't be read).
    case missing
    /// The approval file has records for the item, but not for this action.
    case mismatch
}

/// The digest an approval binds to: SHA-256 of a canonical text of the item's identity and kind,
/// the address it opens, the template, its browser and profile name, and the item's Open With app.
/// Changing any of them changes the digest, so an approval never covers another action.
enum LaunchActionApprovalDigest {
    /// The first line of the canonical text: what it is and its version.
    static let domain = "cybokron-dock-groups/launch-action-approval/1"

    /// The canonical text for `item`'s action, or `nil` when the item has no action that's on and
    /// valid for it or no address. One field per line, `name=<UTF-8 length>:<value>`, in a fixed
    /// order, so no value can be read as another field.
    static func canonical(for item: GroupItem) -> String? {
        guard let action = item.launchAction, let url = item.websiteURL else { return nil }
        let fields: [(String, String)]
        switch action {
        case .browserProfile(let browser, let profileName):
            fields = [
                ("item", item.normalizedBundleIdentifier),
                ("kind", item.kind.rawValue),
                ("url", url.absoluteString),
                ("template", LaunchActionCoding.browserProfileTemplate),
                ("browser", browser.rawValue),
                ("profile", profileName),
                ("opener", item.launch.opener?.bundleIdentifier.lowercased() ?? ""),
            ]
        }
        return ([domain] + fields.map { "\($0.0)=\($0.1.utf8.count):\($0.1)" }).joined(separator: "\n") + "\n"
    }

    /// The digest of `item`'s action as 64 lowercase hexadecimal digits; `nil` as for `canonical`.
    static func digest(for item: GroupItem) -> String? {
        canonical(for: item).map { text in
            SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Whether `text` looks like a digest: 64 lowercase hexadecimal digits.
    static func isWellFormed(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}

/// Where this Mac's approvals are kept: `~/Library/Application Support/Cybokron/DockGroups/
/// launch-action-approvals.json`, next to the groups, read by the main app and every standalone
/// group's app alike. Read again at every check, so an approval removed from the file (or the file
/// itself) counts at once; a missing or unreadable file approves nothing.
@MainActor
public final class LaunchActionApprovalStore {
    public static let fileName = "launch-action-approvals.json"

    /// The approval file of this Mac, next to `groups.json`.
    public static var defaultFileURL: URL {
        JSONFileSupport.directoryURL.appending(path: fileName, directoryHint: .notDirectory)
    }

    /// The approvals in `defaultFileURL`: what the app and the standalone groups' apps use.
    public static var onThisMac: LaunchActionApprovalStore {
        LaunchActionApprovalStore(fileURL: defaultFileURL)
    }

    /// `nil` for approvals kept in memory only (tests).
    let fileURL: URL?
    private var memory = LaunchActionApprovals()
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "LaunchActionApprovals")

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    private init() {
        fileURL = nil
    }

    /// Approvals kept in memory, for tests.
    static func inMemory(_ approvals: LaunchActionApprovals = LaunchActionApprovals()) -> LaunchActionApprovalStore {
        let store = LaunchActionApprovalStore()
        store.memory = approvals
        return store
    }

    /// The approvals as they are now; none when the file is missing or can't be read.
    func load() -> LaunchActionApprovals {
        guard let fileURL else { return memory }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return LaunchActionApprovals() }
        do {
            return try LaunchActionApprovalsDocument.decode(Data(contentsOf: fileURL)).approvals
        } catch {
            logger.error("The approval file can't be read; no launch action is approved: \(String(describing: error), privacy: .public)")
            return LaunchActionApprovals()
        }
    }

    /// Writes `approvals` as the whole file, atomically; an empty set removes the file.
    func save(_ approvals: LaunchActionApprovals) throws {
        guard let fileURL else {
            memory = approvals
            return
        }
        if approvals.isEmpty {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            return
        }
        try JSONFileSupport.write(LaunchActionApprovalsDocument(approvals: approvals), to: fileURL)
    }

    /// What the approvals say about `item`'s action, read now.
    func check(_ item: GroupItem) -> LaunchActionApprovalCheck {
        load().check(item)
    }

    /// Records that the user turned on `item`'s action, as it is now. Does nothing for an item
    /// without an action that's on and valid.
    func approve(_ item: GroupItem) throws {
        guard let digest = LaunchActionApprovalDigest.digest(for: item) else { return }
        var approvals = load()
        let record = LaunchActionApproval(item: item.normalizedBundleIdentifier, digest: digest)
        guard approvals.records.insert(record).inserted else { return }
        try save(approvals)
    }

    /// Drops the approvals none of `items` uses any more; writes only when something was dropped.
    func prune(keepingApprovalsOf items: [GroupItem]) throws {
        let approvals = load()
        let kept = approvals.keepingOnlyThoseOf(items)
        guard kept != approvals else { return }
        try save(kept)
    }
}

/// The approval file's envelope. Read strictly: a format this version doesn't know is refused
/// (nothing approved); a record that isn't an object with a string `item` and a well-formed
/// `digest`, and nothing else, is skipped.
struct LaunchActionApprovalsDocument: Codable {
    var formatVersion: Int
    var approvals: LaunchActionApprovals

    init(approvals: LaunchActionApprovals) {
        formatVersion = LaunchActionApprovals.currentFormatVersion
        self.approvals = approvals
    }

    enum DocumentError: Error, Equatable {
        case unsupportedFormatVersion(Int)
    }

    static func decode(_ data: Data) throws -> LaunchActionApprovalsDocument {
        let document = try JSONDecoder().decode(LaunchActionApprovalsDocument.self, from: data)
        guard document.formatVersion == LaunchActionApprovals.currentFormatVersion else {
            throw DocumentError.unsupportedFormatVersion(document.formatVersion)
        }
        return document
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, approvals
    }

    private static let itemKey = "item"
    private static let digestKey = "digest"

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        let values = try container.decode([JSONValue].self, forKey: .approvals)
        approvals = LaunchActionApprovals(Set(values.compactMap(Self.record)))
    }

    private static func record(_ value: JSONValue) -> LaunchActionApproval? {
        guard case .object(let object) = value, Set(object.keys) == [itemKey, digestKey],
              let item = object[itemKey]?.stringValue, !item.isEmpty, item == item.lowercased(),
              let digest = object[digestKey]?.stringValue, LaunchActionApprovalDigest.isWellFormed(digest)
        else { return nil }
        return LaunchActionApproval(item: item, digest: digest)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        let sorted = approvals.records.sorted { ($0.item, $0.digest) < ($1.item, $1.digest) }
        let values = sorted.map { JSONValue.object([Self.itemKey: .string($0.item), Self.digestKey: .string($0.digest)]) }
        try container.encode(values, forKey: .approvals)
    }
}
