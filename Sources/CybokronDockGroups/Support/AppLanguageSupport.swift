import AppKit
import DockGroupsCore
import OSLog

/// The language picked in Settings (`PopupPreferences.language`): put into effect at launch, and
/// "Restart Now" to show a new choice.
///
/// Bundles read the language once, at their first string lookup, so the choice is applied before
/// anything else runs (`applyAtLaunch`) and a change shows after a restart. A standalone group's
/// agent applies the language from its configuration snapshot the same way, in its own defaults.
@MainActor
enum AppLanguageSupport {
    private static let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "Language")

    /// The language this process was started with; a different choice shows after a restart.
    private(set) static var launchLanguage: AppLanguage = .system
    /// Called right before the restart: the launch after it is quiet for triggers
    /// (`TriggerController.markQuietRelaunch`); set by the app delegate.
    static var beforeRelaunch: (() -> Void)?

    /// Reads the picked language — from `preferences.json`, or an agent's configuration — and puts
    /// it into effect. Call first thing in `main`, before any text is looked up.
    static func applyAtLaunch(asAgent: Bool) {
        let language: AppLanguage
        if asAgent {
            let configurationURL = AgentBundleLayout(bundleURL: Bundle.main.bundleURL).configurationURL
            // A missing or unreadable configuration is reported when the agent starts.
            guard let configuration = try? AgentConfiguration.load(from: configurationURL) else { return }
            language = configuration.preferences.language
        } else {
            // Unreadable preferences are moved aside and reset to the defaults (the system's language).
            language = (try? JSONFilePreferencesPersistence().loadPreferences())?.language ?? .system
        }
        launchLanguage = language
        if LanguageOverride.apply(language, to: .standard) {
            logger.notice("Language set to \(language.rawValue, privacy: .public)")
        }
    }

    /// The languages the picker offers: those the app has string tables for, in list order, plus
    /// `selected` if it isn't one of them (a choice restored from a newer version's backup).
    static func pickerLanguages(selected: AppLanguage) -> [SupportedLanguage] {
        var languages = SupportedLanguages.available(in: Bundle.main.localizations)
        if case .specific(let code) = selected,
           !languages.contains(where: { $0.code == code }),
           let language = SupportedLanguages.language(withCode: code) {
            languages.append(language)
        }
        return languages
    }

    /// The language "System" shows the app in: the one the system's preferred languages (System
    /// Settings → General → Language & Region) give it, whatever the current choice.
    static var systemLanguage: SupportedLanguage {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
        return SupportedLanguages.match(
            forPreferredLanguages: global ?? Locale.preferredLanguages,
            in: Bundle.main.localizations
        )
    }

    /// Saves the preferences, quits the running standalone agents (they start again in the new
    /// language at their next Dock click) and restarts the app: a helper process opens it again once
    /// this one has quit, as after an update.
    static func restart(preferences: PreferencesStore) {
        preferences.flushPendingSave()
        LanguageOverride.apply(preferences.preferences.language, to: .standard)
        let process = Process()
        process.executableURL = UpdateInstaller.shell
        process.arguments = UpdateInstaller.relaunchArguments(
            processID: ProcessInfo.processInfo.processIdentifier,
            appURL: Bundle.main.bundleURL,
            backupURL: nil
        )
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        beforeRelaunch?()
        do {
            try process.run()
        } catch {
            logger.error("Restart helper failed: \(String(describing: error), privacy: .public)")
            NSSound.beep()
            return
        }
        NSWorkspace.shared.runningApplications
            .filter { !$0.isTerminated && AgentIdentity.isAgent(bundleIdentifier: $0.bundleIdentifier) }
            .forEach { _ = $0.terminate() }
        logger.notice("Restarting for the language \(preferences.preferences.language.rawValue, privacy: .public)")
        NSApp.terminate(nil)
    }
}
