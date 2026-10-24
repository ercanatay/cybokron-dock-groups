import Foundation

/// What a popup cell says about its item — the sentences of its tooltip (what a click does, in
/// groups that can be edited how it can be dragged, and the item's details) and its VoiceOver label
/// and hint — as cases the app turns into text. Apps and websites without details say what they
/// always did.
///
/// An item is called by the name it's shown with (`displayName`: its alias, when it has one), also
/// when it can't be found; its own name then appears in the details line.
public struct PopupCellText: Equatable, Sendable {
    /// The tooltip's first sentence: what clicking the item does, or why it can't be opened.
    public enum Help: Equatable, Sendable {
        case openApp(name: String)
        case bringToFront(name: String)
        case openWebsite(address: String)
        case openFile(name: String)
        case openFolder(name: String)
        /// A file, folder or website with the app chosen to open it.
        case openWith(name: String, appName: String)
        /// An app that isn't on this Mac.
        case appMissing(name: String)
        /// A file or folder that was moved, renamed or deleted.
        case itemMissing(name: String)
        /// A file or folder on a volume that isn't connected.
        case volumeUnavailable(name: String, volume: String)
    }

    /// The tooltip's second sentence, in groups that can be edited: how the item can be dragged.
    public enum Drag: Equatable, Sendable {
        /// Free Layout: to any cell, or onto another item to swap them.
        case freeItem
        /// Free Layout, for an app: to any cell, or onto another app to swap them.
        case freeApp
        /// To reorder, or out of the popup to remove it.
        case ordered
        /// Out of the popup to remove it (an item that can't be opened).
        case missing
    }

    /// VoiceOver's label: the item's name, with its kind for everything but apps.
    public enum Label: Equatable, Sendable {
        case app(name: String)
        case website(name: String)
        case file(name: String)
        case folder(name: String)
    }

    /// VoiceOver's hint: what activating the item does.
    public enum Hint: Equatable, Sendable {
        case openApp, bringToFront, website, file, folder
        /// A file, folder or website with the app chosen to open it.
        case openWith(appName: String)
    }

    /// The tooltip's last line, for an item with details: “Name: Q3 Report.pdf · Tags: finance, q3
    /// · Notes: Send the totals…”.
    public struct Details: Equatable, Sendable {
        /// The item's own name, when an alias is shown instead.
        public let name: String?
        public let tags: [String]
        /// The notes on one line (`ItemDetails.notesSummary`).
        public let notes: String?

        public init(name: String? = nil, tags: [String] = [], notes: String? = nil) {
            self.name = name
            self.tags = tags
            self.notes = notes
        }

        /// The details of `item`; `nil` when it has none.
        public init?(item: GroupItem) {
            let details = item.details
            guard !details.isEmpty else { return nil }
            self.init(
                name: details.alias.flatMap { $0 == item.name ? nil : item.name },
                tags: details.tags,
                notes: details.notesSummary
            )
        }
    }

    public private(set) var help: Help
    /// `nil` where the group can't be edited (the Most Used list, a standalone group's own app).
    public let drag: Drag?
    /// `nil` for an item without an alias, tags or task notes.
    public let details: Details?
    public let label: Label
    public private(set) var hint: Hint
    /// Seconds Open All and Start wait before opening the item; `nil` for none (a click opens it
    /// right away either way).
    public let launchDelay: Int?

    public init(item: GroupItem, presence: ItemPresence, isRunning: Bool, isEditable: Bool, isFreeLayout: Bool) {
        let name = item.displayName
        let drag: Drag
        switch item.kind {
        case .website:
            help = .openWebsite(address: item.websiteURL?.absoluteString ?? name)
            drag = isFreeLayout ? .freeItem : .ordered
            label = .website(name: name)
            hint = .website
        case .application:
            if presence.isOpenable {
                help = isRunning ? .bringToFront(name: name) : .openApp(name: name)
                drag = isFreeLayout ? .freeApp : .ordered
            } else {
                help = .appMissing(name: name)
                drag = .missing
            }
            label = .app(name: name)
            hint = isRunning ? .bringToFront : .openApp
        case .file, .folder:
            let isFolder = item.kind == .folder
            switch presence {
            case .missing:
                help = .itemMissing(name: name)
                drag = .missing
            case .volumeUnavailable(let volume):
                help = .volumeUnavailable(name: name, volume: volume)
                drag = .missing
            case .available, .unverified, .online:
                help = isFolder ? .openFolder(name: name) : .openFile(name: name)
                drag = isFreeLayout ? .freeItem : .ordered
            }
            label = isFolder ? .folder(name: name) : .file(name: name)
            hint = isFolder ? .folder : .file
        }
        self.drag = isEditable ? drag : nil
        details = Details(item: item)
        let launch = item.launch.allowed(for: item.kind)
        launchDelay = launch.delay > 0 ? launch.delay : nil
        // An item that opens says with which app it does; one that can't be opened says why.
        if let opener = launch.opener {
            switch help {
            case .openWebsite, .openFile, .openFolder:
                help = .openWith(name: name, appName: opener.name)
                hint = .openWith(appName: opener.name)
            default:
                break
            }
        }
    }

    /// The tooltip's sentence about the launch delay: "Open All and Start open it after 3 seconds.";
    /// `nil` without one.
    public var launchDelayText: String? {
        guard let launchDelay else { return nil }
        return launchDelay == 1
            ? Localization.string("item.launch.help.delay.one", "Open All and Start open it after 1 second.")
            : Localization.format("item.launch.help.delay.other", "Open All and Start open it after %ld seconds.", launchDelay)
    }
}
