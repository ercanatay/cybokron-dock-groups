import AppKit
import ApplicationServices
import DockGroupsCore
import OSLog
import UniformTypeIdentifiers

/// Settings → Backup → Diagnostics: gathers a plain-text report about the app, the Mac and the
/// user's setup (`DiagnosticsReport`) to attach to a GitHub issue or a support request, and copies
/// it to the clipboard or saves it to a file the user picks.
@MainActor
final class DiagnosticsController: ObservableObject {
    /// What the last copy or save did, shown for a moment next to the buttons.
    enum Feedback: Equatable {
        case copied
        case saved(fileName: String)
        case failed(String)
    }

    @Published private(set) var isBusy = false
    @Published private(set) var feedback: Feedback?

    /// The window the save panel attaches to.
    weak var window: NSWindow?

    private let preferences: PreferencesStore
    private let store: GroupStore
    private let templates: TemplateStore
    private let updater: AutoUpdater
    private let shortcuts: GlobalShortcutMonitor
    private let isStatusItemShown: () -> Bool
    private var feedbackReset: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "Diagnostics")

    init(
        preferences: PreferencesStore,
        store: GroupStore,
        templates: TemplateStore,
        updater: AutoUpdater,
        shortcuts: GlobalShortcutMonitor,
        isStatusItemShown: @escaping () -> Bool
    ) {
        self.preferences = preferences
        self.store = store
        self.templates = templates
        self.updater = updater
        self.shortcuts = shortcuts
        self.isStatusItemShown = isStatusItemShown
    }

    // MARK: - Actions

    func copyToClipboard() {
        makeReport { [weak self] text in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            self?.show(.copied)
        }
    }

    func saveToFile() {
        let panel = NSSavePanel()
        panel.title = L10n.Settings.Diagnostics.panelTitle
        panel.message = L10n.Settings.Diagnostics.panelMessage
        panel.prompt = L10n.Settings.Diagnostics.panelPrompt
        panel.nameFieldStringValue = DiagnosticsReport.fileName(for: Date())
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.save(to: url)
        }
        if let window, window.isVisible {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            NSApp.activate()
            panel.begin(completionHandler: completion)
        }
    }

    private func save(to url: URL) {
        makeReport { [weak self] text in
            guard let self else { return }
            Task {
                let result = await Task.detached {
                    Result { try Data(text.utf8).write(to: url, options: .atomic) }
                }.value
                switch result {
                case .success:
                    self.show(.saved(fileName: url.lastPathComponent))
                case .failure(let error):
                    self.logger.error("Saving diagnostics failed: \(error.localizedDescription, privacy: .public)")
                    self.show(.failed(error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Report

    /// Builds the report — reading the log off the main thread — and hands it to `completion`.
    private func makeReport(then completion: @escaping @MainActor (String) -> Void) {
        guard !isBusy else { return }
        isBusy = true
        let info = currentInfo()
        Task {
            let errors = await Task.detached(priority: .userInitiated) {
                Self.recentErrors(limit: DiagnosticsReport.maximumErrorCount)
            }.value
            var complete = info
            complete.recentErrors = errors
            isBusy = false
            completion(DiagnosticsReport.text(for: complete))
        }
    }

    /// Everything but the logged errors, as it is now.
    private func currentInfo() -> DiagnosticsInfo {
        let bundle = Bundle.main
        let state = JSONFileUpdateStatePersistence().load()
        return DiagnosticsInfo(
            app: .init(
                version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                path: bundle.bundlePath
            ),
            system: .current(),
            isAccessibilityTrusted: AXIsProcessTrusted(),
            isStatusItemShown: isStatusItemShown(),
            preferences: preferences.preferences,
            updates: .init(
                lastCheckDate: updater.lastCheckDate ?? state.lastCheckDate,
                lastResult: Self.describe(updater.status),
                offeredVersion: Self.offeredVersion(in: updater.status),
                skippedVersions: state.skippedVersions
            ),
            groups: store.groups,
            groupShortcutStatuses: shortcuts.groupStatuses,
            archivedGroupCount: store.archivedGroups.count,
            templateCount: templates.templates.count,
            recentErrors: []
        )
    }

    private static func describe(_ status: AutoUpdater.Status) -> String {
        switch status {
        case .idle: return "not checked since the app started"
        case .checking: return "checking"
        case .upToDate(let version): return "up to date (v\(version.description))"
        case .available(let release, let asset):
            return "v\(release.version.description) available\(asset == nil ? " (no disk image)" : "")"
        case .downloading(let release, _): return "downloading v\(release.version.description)"
        case .installing(let release): return "installing v\(release.version.description)"
        case .restarting(let release): return "restarting into v\(release.version.description)"
        case .stagedForDryRun(let release, _): return "v\(release.version.description) staged (dry run)"
        case .checkFailed(let message): return "check failed: \(message)"
        case .installFailed(let release, _, let message): return "installing v\(release.version.description) failed: \(message)"
        }
    }

    private static func offeredVersion(in status: AutoUpdater.Status) -> String? {
        switch status {
        case .available(let release, _), .downloading(let release, _), .installing(let release),
             .restarting(let release), .stagedForDryRun(let release, _), .installFailed(let release, _, _):
            return release.version.description
        case .idle, .checking, .upToDate, .checkFailed:
            return nil
        }
    }

    /// The latest errors and faults this process logged (the log keeps them for the current run
    /// only), oldest first.
    nonisolated private static func recentErrors(limit: Int) -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return [] }
        let predicate = NSPredicate(format: "subsystem == %@", "com.cybokron.dockgroups")
        guard let entries = try? store.getEntries(matching: predicate) else { return [] }
        let formatter = ISO8601DateFormatter()
        var lines: [String] = []
        for case let entry as OSLogEntryLog in entries where entry.level == .error || entry.level == .fault {
            lines.append("\(formatter.string(from: entry.date)) [\(entry.category)] \(entry.composedMessage)")
            if lines.count > limit {
                lines.removeFirst()
            }
        }
        return lines
    }

    // MARK: - Feedback

    /// Shows `feedback` for two seconds.
    private func show(_ feedback: Feedback) {
        self.feedback = feedback
        feedbackReset?.cancel()
        feedbackReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.feedback = nil
        }
    }
}
