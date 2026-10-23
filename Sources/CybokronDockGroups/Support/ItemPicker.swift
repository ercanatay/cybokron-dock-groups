import AppKit
import DockGroupsCore

/// Lets the user choose files and folders for a group with an open panel: to add them, or to say
/// where a missing one is now (Locate…).
@MainActor
enum ItemPicker {
    /// Shows an open panel for files and folders of any kind — as a sheet on `window` when one is
    /// given — and calls `completion` with the chosen locations (an empty list when the user
    /// cancels). Document packages (`.rtfd`, `.pages`, …) are chosen as files; apps can be chosen
    /// too and are added as apps (`ItemAddition`).
    static func chooseFilesAndFolders(
        forGroupNamed groupName: String,
        attachedTo window: NSWindow?,
        completion: @escaping ([URL]) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.title = L10n.AddItems.title
        panel.message = L10n.AddItems.message(groupName)
        panel.prompt = L10n.Common.add
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.resolvesAliases = false
        present(panel, attachedTo: window) { completion($0) }
    }

    /// Asks where the missing file or folder `item` is now: an open panel for its kind (files, or
    /// folders), starting in the folder it was in (the panel, not the app, looks whether that's
    /// still there). Calls `completion` with the chosen location, or `nil` when the user cancels.
    static func locate(
        _ item: GroupItem,
        attachedTo window: NSWindow?,
        completion: @escaping (URL?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.message = L10n.Item.locateMessage(item.name)
        panel.prompt = L10n.Item.locatePrompt
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = item.kind == .file
        panel.canChooseDirectories = item.kind == .folder
        panel.treatsFilePackagesAsDirectories = false
        panel.resolvesAliases = false
        if let parent = item.fileURL?.deletingLastPathComponent(), FileLocation.isAbsoluteLocation(parent.path) {
            panel.directoryURL = parent
        }
        present(panel, attachedTo: window) { completion($0.first) }
    }

    private static func present(_ panel: NSOpenPanel, attachedTo window: NSWindow?, completion: @escaping ([URL]) -> Void) {
        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            completion(response == .OK ? panel.urls : [])
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            NSApp.activate()
            panel.begin(completionHandler: handleResponse)
        }
    }
}
