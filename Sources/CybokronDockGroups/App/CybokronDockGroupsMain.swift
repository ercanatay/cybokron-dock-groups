import AppKit
import DockGroupsCore

@main
enum CybokronDockGroupsMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        // The same executable runs the main app and, copied into a group's own bundle, that group's
        // standalone agent; the bundle identifier tells which.
        let delegate: NSObject & NSApplicationDelegate
        if let groupID = AgentIdentity.groupID(fromBundleIdentifier: Bundle.main.bundleIdentifier) {
            delegate = AgentAppDelegate(groupID: groupID)
        } else {
            delegate = AppDelegate()
        }
        application.delegate = delegate
        // NSApplication holds its delegate weakly; keep ours alive for as long as the app runs.
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
