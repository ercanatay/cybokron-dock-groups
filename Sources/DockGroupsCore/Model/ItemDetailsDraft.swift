import Foundation

/// An item's alias, tags, task notes and launch options while the details editor shows them: the
/// text as typed, the delay and the app chosen, and what saving them would keep.
///
/// Nothing reaches the store while the user types or chooses. The editor saves once, when it
/// closes (`GroupStore.saveItemEdits(of:endingWith:ofItem:inGroup:)`), so a standalone group's own
/// app is rebuilt at most once per edit, and not at all when nothing changed or the edit was
/// cancelled.
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
    /// The launch options the editor started from.
    public let originalLaunch: ItemLaunchOptions
    /// The item's kind: an app has no "Open with" (`offersOpener`).
    public let kind: AppReference.Kind
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
    /// The launch delay chosen, in seconds; kept within 0…`ItemLaunchOptions.maximumDelay`.
    public var delay: Int {
        didSet { delay = min(max(delay, 0), ItemLaunchOptions.maximumDelay) }
    }
    /// The app chosen to open the item; `nil` for its default app. Never set for an app.
    public var opener: ItemOpener? {
        didSet { if !offersOpener { opener = nil } }
    }

    /// A draft of these details alone, for an item without launch options.
    public init(_ details: ItemDetails) {
        self.init(details: details, launch: ItemLaunchOptions(), kind: .application)
    }

    /// A draft of everything the editor edits of `item`.
    public init(_ item: GroupItem) {
        self.init(details: item.details, launch: item.launch, kind: item.kind)
    }

    private init(details: ItemDetails, launch: ItemLaunchOptions, kind: AppReference.Kind) {
        original = details
        self.kind = kind
        originalLaunch = launch.allowed(for: kind)
        alias = details.alias ?? ""
        tagsText = details.commaSeparatedTags
        notes = details.notes ?? ""
        delay = originalLaunch.delay
        opener = originalLaunch.opener
    }

    /// Whether the editor offers "Open with": files, folders and websites; apps open themselves.
    public var offersOpener: Bool { kind != .application }

    /// The delays the editor offers (`ItemLaunchOptions.allowedDelays`), and the item's own when a
    /// groups file gave it another one, so it isn't changed by just opening the editor.
    public var delayChoices: [Int] {
        Set(ItemLaunchOptions.allowedDelays + [originalLaunch.delay, delay]).sorted()
    }

    /// The launch options chosen.
    public var launch: ItemLaunchOptions {
        ItemLaunchOptions(delay: delay, opener: opener).allowed(for: kind)
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

    /// Whether saving would change the item: its details or its launch options.
    public var hasChanges: Bool { details != original || launch != originalLaunch }

    /// What closing the editor saves of the details: the new details after Done or a dismissal
    /// when they differ from the ones it started with, `nil` otherwise — always `nil` after Cancel.
    public func detailsToSave(endingWith ending: Ending) -> ItemDetails? {
        guard ending != .cancel, details != original else { return nil }
        return details
    }

    /// What closing the editor saves of the launch options, as `detailsToSave` does for the details.
    public func launchToSave(endingWith ending: Ending) -> ItemLaunchOptions? {
        guard ending != .cancel, launch != originalLaunch else { return nil }
        return launch
    }

    private static func cut(_ text: String, to maximumLength: Int) -> String {
        text.count > maximumLength ? String(text.prefix(maximumLength)) : text
    }
}

extension GroupStore {
    /// Closes a details editor: saves what `draft` holds for the item (`ItemDetailsDraft.detailsToSave`)
    /// with one `updateDetails(_:ofItem:inGroup:)` — nothing after Cancel, or when nothing changed.
    /// Its launch options aren't saved: `saveItemEdits` saves both.
    /// - Returns: Whether the item's details changed.
    @discardableResult
    public func saveDetails(of draft: ItemDetailsDraft, endingWith ending: ItemDetailsDraft.Ending, ofItem identity: String, inGroup id: DockGroup.ID) -> Bool {
        guard let details = draft.detailsToSave(endingWith: ending) else { return false }
        return updateDetails(details, ofItem: identity, inGroup: id)
    }

    /// Closes a details editor: saves what `draft` holds for the item — its details and its launch
    /// options — in one change of the group (`updateItem`), so the groups file is written once and
    /// a standalone group's app rebuilt once at most; nothing after Cancel, or when nothing changed.
    /// - Returns: Whether the item changed.
    @discardableResult
    public func saveItemEdits(of draft: ItemDetailsDraft, endingWith ending: ItemDetailsDraft.Ending, ofItem identity: String, inGroup id: DockGroup.ID) -> Bool {
        let details = draft.detailsToSave(endingWith: ending)
        let launch = draft.launchToSave(endingWith: ending)
        guard details != nil || launch != nil else { return false }
        return updateItem(identity, inGroup: id, details: details, launch: launch)
    }
}
