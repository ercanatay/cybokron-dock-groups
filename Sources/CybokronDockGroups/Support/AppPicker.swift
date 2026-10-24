import AppKit
import UniformTypeIdentifiers

/// Lets the user choose apps with an open panel.
@MainActor
enum AppPicker {
    /// Shows an open panel for `.app` bundles — as a sheet on `window` when one is given — and calls
    /// `completion` with the chosen bundles (an empty list when the user cancels).
    static func chooseApps(
        forGroupNamed groupName: String,
        attachedTo window: NSWindow?,
        completion: @escaping ([URL]) -> Void
    ) {
        chooseApps(title: L10n.AppPicker.title, message: L10n.AppPicker.message(groupName), attachedTo: window, completion: completion)
    }

    /// The same open panel with its own title and message (Settings → Switching's protected apps,
    /// the details editor's "Open with" → Other…), its own button and, for one app only, single
    /// selection.
    static func chooseApps(
        title: String,
        message: String,
        prompt: String = L10n.Common.add,
        allowsMultipleSelection: Bool = true,
        attachedTo window: NSWindow?,
        completion: @escaping ([URL]) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.prompt = prompt
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)

        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            completion(response == .OK ? panel.urls : [])
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            panel.begin(completionHandler: handleResponse)
        }
    }
}
