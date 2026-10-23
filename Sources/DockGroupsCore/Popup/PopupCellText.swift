import Foundation

/// What a popup cell says about its item — the two sentences of its tooltip (what a click does,
/// and in groups that can be edited how it can be dragged) and its VoiceOver label and hint — as
/// cases the app turns into text. Apps and websites say what they always did.
public struct PopupCellText: Equatable, Sendable {
    /// The tooltip's first sentence: what clicking the item does, or why it can't be opened.
    public enum Help: Equatable, Sendable {
        case openApp(name: String)
        case bringToFront(name: String)
        case openWebsite(address: String)
        case openFile(name: String)
        case openFolder(name: String)
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
    }

    public let help: Help
    /// `nil` where the group can't be edited (the Most Used list, a standalone group's own app).
    public let drag: Drag?
    public let label: Label
    public let hint: Hint

    public init(item: GroupItem, presence: ItemPresence, isRunning: Bool, isEditable: Bool, isFreeLayout: Bool) {
        let name = item.name
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
    }
}
