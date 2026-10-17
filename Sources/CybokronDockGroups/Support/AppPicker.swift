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
        let panel = NSOpenPanel()
        panel.title = "Add Apps to Group"
        panel.message = "Choose the apps to add to “\(groupName)”."
        panel.prompt = "Add"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
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
