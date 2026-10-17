import AppKit
import DockGroupsCore
import OSLog

/// Runs this copy of the app as a second copy: it sets nothing up, hands the URLs it was opened
/// with to the older copy that runs, then quits (see `InstanceHandoff` for why there can be two).
///
/// URLs the app is launched with arrive before `applicationDidFinishLaunching`; they're collected
/// and handed over in `finishLaunching()`. Launched without any (from Finder or `open -a`), this
/// copy opens the older one instead, which then reopens as when opened again.
@MainActor
final class SecondCopyHandoff {
    private let primary: NSRunningApplication
    private let primaryURL: URL
    private var pendingURLs: [URL] = []
    private var hasFinishedLaunching = false
    private var handoffsInFlight = 0
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "Handoff")

    /// A handoff to the older copy of this app that runs, or `nil` when this copy is the oldest.
    static func toOlderRunningCopy() -> SecondCopyHandoff? {
        let current = NSRunningApplication.current
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return nil }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated && $0.processIdentifier != current.processIdentifier && $0.bundleURL != nil }
        guard let oldest = InstanceHandoff.primary(among: others.map(instance), current: instance(current)),
              let primary = others.first(where: { $0.processIdentifier == oldest.processIdentifier }),
              let primaryURL = primary.bundleURL
        else { return nil }
        return SecondCopyHandoff(primary: primary, primaryURL: primaryURL)
    }

    private static func instance(_ application: NSRunningApplication) -> InstanceHandoff.Instance {
        InstanceHandoff.Instance(processIdentifier: application.processIdentifier, launchDate: application.launchDate)
    }

    private init(primary: NSRunningApplication, primaryURL: URL) {
        self.primary = primary
        self.primaryURL = primaryURL
        logger.notice("Another copy runs (pid \(primary.processIdentifier) at \(primaryURL.path, privacy: .public)); this copy (\(Bundle.main.bundleURL.path, privacy: .public)) hands over to it and quits")
    }

    /// Whether the older copy still runs; if it quit meanwhile, this copy runs as the app instead.
    var isPrimaryRunning: Bool { !primary.isTerminated }

    /// URLs this copy was opened with, handed over once launching has finished.
    func receive(_ urls: [URL]) {
        if hasFinishedLaunching {
            handOff(urls)
        } else {
            pendingURLs += urls
        }
    }

    /// Takes the URLs collected while launching from a handoff that won't happen, because the older
    /// copy quit meanwhile.
    func takePendingURLs() -> [URL] {
        defer { pendingURLs = [] }
        return pendingURLs
    }

    /// Hands over the URLs received while launching, or with none, opens the older copy.
    func finishLaunching() {
        hasFinishedLaunching = true
        handOff(takePendingURLs())
    }

    private func handOff(_ urls: [URL]) {
        handoffsInFlight += 1
        // Lets the older copy come forward, for windows it shows (cooperative activation).
        NSApp.yieldActivation(to: primary)
        let configuration = NSWorkspace.OpenConfiguration()
        // Exactly the older copy: LaunchServices must not pick another running copy, this one included.
        configuration.allowsRunningApplicationSubstitution = false
        let completion: @Sendable (NSRunningApplication?, (any Error)?) -> Void = { [weak self] _, error in
            let failure = error.map { String(describing: $0) }
            Task { @MainActor [weak self] in self?.handoffFinished(failure: failure) }
        }
        if urls.isEmpty {
            logger.notice("Opening the other copy")
            NSWorkspace.shared.openApplication(at: primaryURL, configuration: configuration, completionHandler: completion)
        } else {
            for url in urls {
                logger.notice("Handing \(url.absoluteString, privacy: .public) to the other copy")
            }
            NSWorkspace.shared.open(urls, withApplicationAt: primaryURL, configuration: configuration, completionHandler: completion)
        }
    }

    private func handoffFinished(failure: String?) {
        handoffsInFlight -= 1
        if let failure {
            logger.error("Handing over to the other copy failed: \(failure, privacy: .public)")
        }
        if handoffsInFlight == 0 {
            NSApp.terminate(nil)
        }
    }
}
