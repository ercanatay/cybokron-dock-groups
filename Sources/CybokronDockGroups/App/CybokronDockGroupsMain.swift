import AppKit
import DockGroupsCore

@main
enum CybokronDockGroupsMain {
    @MainActor
    static func main() {
        // The same executable runs the main app and, copied into a group's own bundle, that group's
        // standalone agent; the bundle identifier tells which.
        let agentGroupID = AgentIdentity.groupID(fromBundleIdentifier: Bundle.main.bundleIdentifier)
        // Before any text is looked up: bundles read the language once.
        AppLanguageSupport.applyAtLaunch(asAgent: agentGroupID != nil)
        let application = NSApplication.shared
        let delegate: NSObject & NSApplicationDelegate
        if let groupID = agentGroupID {
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
