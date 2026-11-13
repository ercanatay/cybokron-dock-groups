import Foundation

/// An item's alias, tags, task notes, launch options and launch action while the details editor
/// shows them: the text as typed, the delay and the app chosen, a website's browser profile or
/// private window, and what saving them would keep.
///
/// A browser profile (launch-action-ui-slice.md) is set or turned on only once the user confirmed
/// it (`confirmLaunchAction`): Done asks first, and closing the editor another way keeps the item's
/// action as it was. Only browsers on this Mac can be chosen, and a name the grammar refuses can't
/// be saved (`canFinish`).
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
    /// The item's launch action when the editor opened; `nil` without one.
    public let originalLaunchAction: LaunchActionStatus?
    /// The action is on but this Mac has no approval for it (`GroupStore.isApprovalMissing(for:)`).
    public let isApprovalMissing: Bool
    /// The browsers found on this Mac when the editor opened: only these can be chosen.
    public let installedBrowsers: Set<BrowserFamily>
    /// The browser whose profile the website opens in; `nil` while the browser profile is off.
    /// Set through `chooseBrowser(_:)` or `setBrowserProfileOn(_:)`.
    public private(set) var browser: BrowserFamily?
    /// The profile name as typed; kept while the browser profile is off or a private window is
    /// chosen.
    public var profileName: String
    /// Whether the website opens in a private window of `browser` instead of a profile
    /// (`LaunchAction.browserPrivate`, launch-action-private-window.md); the profile name is then
    /// neither shown nor saved.
    public var isPrivateWindow: Bool
    /// The action the user confirmed in this editor (`confirmLaunchAction`).
    public private(set) var confirmedLaunchAction: LaunchAction?
    /// Whether the user turned the browser profile off in this editor: for an invalid action,
    /// whose toggle starts off, that's what removes it.
    private var turnedBrowserProfileOff = false

    /// A draft of these details alone, for an item without launch options.
    public init(_ details: ItemDetails) {
        self.init(details: details, launch: ItemLaunchOptions(), kind: .application, action: nil, installedBrowsers: [])
    }

    /// A draft of everything the editor edits of `item`.
    /// - Parameter installedBrowsers: The browsers on this Mac, which a website's browser profile
    ///   can be set to.
    ///   - isApprovalMissing: The item's action is on but this Mac has no approval for it, so the
    ///     editor offers Turn On, which writes it.
    public init(_ item: GroupItem, installedBrowsers: Set<BrowserFamily> = [], isApprovalMissing: Bool = false) {
        self.init(details: item.details, launch: item.launch, kind: item.kind, action: item.launchActionStatus, installedBrowsers: installedBrowsers,
                  isApprovalMissing: isApprovalMissing && item.launchActionStatus?.needsReview == false)
    }

    private init(details: ItemDetails, launch: ItemLaunchOptions, kind: AppReference.Kind, action: LaunchActionStatus?, installedBrowsers: Set<BrowserFamily>, isApprovalMissing: Bool = false) {
        self.isApprovalMissing = isApprovalMissing
        original = details
        self.kind = kind
        originalLaunch = launch.allowed(for: kind)
        alias = details.alias ?? ""
        tagsText = details.commaSeparatedTags
        notes = details.notes ?? ""
        delay = originalLaunch.delay
        opener = originalLaunch.opener
        originalLaunchAction = action
        self.installedBrowsers = installedBrowsers
        let starting = Self.startingAction(of: action)
        browser = starting?.browser
        profileName = starting?.profileName ?? ""
        isPrivateWindow = starting?.isPrivateWindow ?? false
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

    /// Whether saving would change the item: its details, its launch options or its launch action.
    public var hasChanges: Bool {
        details != original || launch != originalLaunch || launchActionToSave(endingWith: .done) != nil
    }

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

    // MARK: - Browser profile

    /// Whether the editor offers a browser profile: websites only.
    public var offersBrowserProfile: Bool { kind == .website }

    /// Whether `family` can be chosen: it's on this Mac.
    public func canChoose(_ family: BrowserFamily) -> Bool {
        installedBrowsers.contains(family)
    }

    /// Chooses the browser; `nil` turns the browser profile off. A browser that isn't on this Mac
    /// isn't taken. - Returns: Whether the choice was taken.
    @discardableResult
    public mutating func chooseBrowser(_ family: BrowserFamily?) -> Bool {
        guard offersBrowserProfile else { return family == nil }
        if let family, !canChoose(family) { return false }
        browser = family
        if family == nil { turnedBrowserProfileOff = true }
        return true
    }

    /// Whether the browser profile can be turned on: a browser is chosen already, or one is on this Mac.
    public var canTurnOnBrowserProfile: Bool {
        offersBrowserProfile && (browser != nil || !installedBrowsers.isEmpty)
    }

    /// Turns the browser profile on (the action's own browser when it's on this Mac, otherwise
    /// the first one that is) or off.
    public mutating func setBrowserProfileOn(_ isOn: Bool) {
        guard isOn else {
            browser = nil
            turnedBrowserProfileOff = true
            return
        }
        guard browser == nil, offersBrowserProfile else { return }
        let preferred = Self.startingAction(of: originalLaunchAction)?.browser
        browser = preferred.flatMap { canChoose($0) ? $0 : nil } ?? BrowserFamily.allCases.first(where: canChoose)
    }

    /// The action the editor's fields describe; `nil` while the browser profile is off.
    public var chosenLaunchAction: LaunchAction? {
        browser.map { isPrivateWindow ? .browserPrivate(browser: $0) : .browserProfile(browser: $0, profileName: profileName) }
    }

    /// Whether the profile name can be saved: the grammar takes it, the browser profile is off, or
    /// a private window is chosen (the name isn't used). When it can't, the editor says what a
    /// name may hold under the field.
    public var isProfileNameAccepted: Bool {
        browser == nil || isPrivateWindow || LaunchAction.isAcceptedProfileName(profileName)
    }

    /// Whether the item's action needs the user's review before the item opens again: it came in
    /// with a backup, or couldn't be used.
    public var launchActionNeedsReview: Bool { (originalLaunchAction?.needsReview ?? false) || isApprovalMissing }

    /// Whether Done can close the editor: the name is accepted, and a changed browser profile is
    /// for a browser on this Mac.
    public var canFinish: Bool {
        guard isProfileNameAccepted else { return false }
        guard let browser, chosenLaunchAction != startingLaunchAction else { return true }
        return canChoose(browser)
    }

    /// What Done must have the user confirm first: the chosen action when it's valid, for a
    /// browser on this Mac, differs from the one the editor started with and wasn't confirmed yet.
    public var launchActionAwaitingConfirmation: LaunchAction? {
        guard let action = confirmableAction, action != startingLaunchAction else { return nil }
        return action
    }

    /// What Turn On confirms for an action that needs review: the chosen one, once it's valid and
    /// for a browser on this Mac; `nil` when nothing needs turning on.
    public var launchActionToTurnOn: LaunchAction? {
        guard launchActionNeedsReview else { return nil }
        return confirmableAction
    }

    /// Records that the user confirmed `action`; ignored unless it's the chosen action.
    public mutating func confirmLaunchAction(_ action: LaunchAction) {
        guard action == chosenLaunchAction else { return }
        confirmedLaunchAction = action
    }

    /// What closing the editor does to the item's launch action; `nil` keeps it as it is. After
    /// Cancel always `nil`. A confirmed action is set and on; turning the browser profile off
    /// removes an action the item had — an invalid one, whose toggle starts off, once the user
    /// turned it on and off again. An unconfirmed or refused one changes nothing.
    public func launchActionToSave(endingWith ending: Ending) -> LaunchActionEdit? {
        guard ending != .cancel else { return nil }
        guard let chosen = chosenLaunchAction else {
            let removes = startingLaunchAction != nil || (originalLaunchAction == .invalid && turnedBrowserProfileOff)
            return removes ? .remove : nil
        }
        guard chosen == confirmedLaunchAction, chosen.rejection == nil, chosen.isAllowed(for: kind) else { return nil }
        if originalLaunchAction == .enabled(chosen), !isApprovalMissing { return nil }
        return .enable(chosen)
    }

    /// The action the editor's fields started from: the item's own, on or imported; none for an
    /// invalid one (there's nothing to show).
    private var startingLaunchAction: LaunchAction? { Self.startingAction(of: originalLaunchAction) }

    private static func startingAction(of status: LaunchActionStatus?) -> LaunchAction? {
        switch status {
        case .enabled(let action), .imported(let action): return action
        case .invalid, nil: return nil
        }
    }

    /// The chosen action when it could be confirmed now.
    private var confirmableAction: LaunchAction? {
        guard let action = chosenLaunchAction, action != confirmedLaunchAction, action.rejection == nil,
              action.isAllowed(for: kind), canChoose(action.browser) else { return nil }
        return action
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

    /// Closes a details editor: saves what `draft` holds for the item — its details, its launch
    /// options and its launch action (`ItemDetailsDraft.launchActionToSave`) — in one change of the group (`updateItem`), so the groups file is written once and
    /// a standalone group's app rebuilt once at most; nothing after Cancel, or when nothing changed.
    /// - Returns: Whether the item changed.
    @discardableResult
    public func saveItemEdits(of draft: ItemDetailsDraft, endingWith ending: ItemDetailsDraft.Ending, ofItem identity: String, inGroup id: DockGroup.ID) -> Bool {
        let details = draft.detailsToSave(endingWith: ending)
        let launch = draft.launchToSave(endingWith: ending)
        let action = draft.launchActionToSave(endingWith: ending)
        guard details != nil || launch != nil || action != nil else { return false }
        return updateItem(identity, inGroup: id, details: details, launch: launch, launchAction: action)
    }
}
