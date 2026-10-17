import AppKit
import Combine
import DockGroupsCore

/// Which apps are running, kept current from NSWorkspace launch, quit and wake notifications so
/// the popup's running indicators and Close All update live. Lives as long as the app.
@MainActor
final class RunningAppsMonitor: ObservableObject {
    /// Lowercased bundle identifiers of the running apps.
    @Published private(set) var runningBundleIdentifiers: Set<String> = []

    private let workspace: NSWorkspace
    private var observers: [NSObjectProtocol] = []

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
        reload()
        let names = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didWakeNotification,
        ]
        observers = names.map { name in
            workspace.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        }
    }

    func isRunning(_ app: AppReference) -> Bool {
        runningBundleIdentifiers.contains(app.bundleIdentifier.lowercased())
    }

    func runningCount(in group: DockGroup) -> Int {
        group.apps.filter(isRunning).count
    }

    private func reload() {
        let running = Set(
            workspace.runningApplications
                .filter { !$0.isTerminated }
                .compactMap { $0.bundleIdentifier?.lowercased() }
        )
        if running != runningBundleIdentifiers {
            runningBundleIdentifiers = running
        }
    }
}

/// The modifier keys held while the popup is open, so Close All can show what a click will do.
@MainActor
final class ModifierKeyState: ObservableObject {
    @Published private(set) var flags: NSEvent.ModifierFlags = []

    var quitMode: QuitMode { QuitMode(modifierFlags: flags) }

    func update(_ newFlags: NSEvent.ModifierFlags) {
        let relevant = newFlags.intersection([.command, .option])
        if relevant != flags {
            flags = relevant
        }
    }
}
