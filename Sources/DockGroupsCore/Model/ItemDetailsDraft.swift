import Foundation

/// An item's alias, tags and task notes while the details editor shows them: the text as typed,
/// and what saving it would keep.
///
/// Nothing reaches the store while the user types. The editor saves once, when it closes
/// (`GroupStore.saveDetails(of:endingWith:ofItem:inGroup:)`), so a standalone group's own app is
/// rebuilt at most once per edit, and not at all when nothing changed or the edit was cancelled.
public struct ItemDetailsDraft: Equatable, Sendable {
    /// How the editor was closed.
    public enum Ending: Equatable, Sendable {
        /// Done: keep what was typed.
        case done
        /// Cancel: forget what was typed.
        case cancel
        /// Closed another way (a click outside the popover): kept as with Done, so nothing typed is lost.
        case dismissed
    }

    /// The details the editor started from.
    public let original: ItemDetails
    /// The alias as typed; never longer than `ItemDetails.maximumAliasLength` characters.
    public var alias: String {
        didSet { alias = Self.cut(alias, to: ItemDetails.maximumAliasLength) }
    }
    /// The tags as typed, separated by commas.
    public var tagsText: String
    /// The task notes as typed; never longer than `ItemDetails.maximumNotesLength` characters.
    public var notes: String {
        didSet { notes = Self.cut(notes, to: ItemDetails.maximumNotesLength) }
    }

    public init(_ details: ItemDetails) {
        original = details
        alias = details.alias ?? ""
        tagsText = details.commaSeparatedTags
        notes = details.notes ?? ""
    }

    /// The tags that would be kept, cleaned up as `ItemDetails` keeps them: shown under the field
    /// while the user types.
    public var tags: [String] { ItemDetails.tags(fromCommaSeparated: tagsText) }

    /// How many distinct tags were typed beyond `ItemDetails.maximumTagCount`; they wouldn't be kept.
    public var leftOutTagCount: Int {
        max(ItemDetails.allTags(fromCommaSeparated: tagsText).count - ItemDetails.maximumTagCount, 0)
    }

    /// Characters typed into the task notes, for the counter next to the limit.
    public var notesLength: Int { notes.count }

    /// The details the text stands for, cleaned up (`ItemDetails.init`).
    public var details: ItemDetails {
        ItemDetails(alias: alias, tags: tags, notes: notes)
    }

    /// Whether saving would change the item's details.
    public var hasChanges: Bool { details != original }

    /// What closing the editor saves: the new details after Done or a dismissal when they differ
    /// from the ones it started with, `nil` otherwise — always `nil` after Cancel.
    public func detailsToSave(endingWith ending: Ending) -> ItemDetails? {
        guard ending != .cancel, hasChanges else { return nil }
        return details
    }

    private static func cut(_ text: String, to maximumLength: Int) -> String {
        text.count > maximumLength ? String(text.prefix(maximumLength)) : text
    }
}

extension GroupStore {
    /// Closes a details editor: saves what `draft` holds for the item (`ItemDetailsDraft.detailsToSave`)
    /// with one `updateDetails(_:ofItem:inGroup:)` — nothing after Cancel, or when nothing changed.
    /// - Returns: Whether the item's details changed.
    @discardableResult
    public func saveDetails(of draft: ItemDetailsDraft, endingWith ending: ItemDetailsDraft.Ending, ofItem identity: String, inGroup id: DockGroup.ID) -> Bool {
        guard let details = draft.detailsToSave(endingWith: ending) else { return false }
        return updateDetails(details, ofItem: identity, inGroup: id)
    }
}
