import AppKit
import DockGroupsCore
import UniformTypeIdentifiers

/// Exports the groups and preferences to a `.dockgroups` backup file and restores them from one:
/// either replacing everything, or merging the backup's new groups into the current ones.
/// Panels and alerts are sheets on the Settings window, and files are read and written off the
/// main thread, so the rest of the app keeps working meanwhile.
@MainActor
final class SettingsBackupController: ObservableObject {
    /// What the last export or import did, shown under the buttons.
    enum Status: Equatable {
        case exported(fileName: String)
        case imported(groupCount: Int, appCount: Int)
        case merged(addedGroupCount: Int, skippedGroupCount: Int)
    }

    @Published private(set) var isBusy = false
    @Published private(set) var status: Status?

    /// The window the panels and alerts attach to.
    weak var window: NSWindow?

    private let store: GroupStore
    private let preferences: PreferencesStore
    /// Told about the groups a restore or merge put in the store, so standalone ones get their
    /// Dock tiles (`StandaloneController.adoptRestoredGroups`).
    private let groupsRestored: ([DockGroup]) -> Void

    /// `.dockgroups` files are JSON.
    static let backupType = UTType(filenameExtension: SettingsBackup.fileExtension, conformingTo: .json) ?? .json

    init(store: GroupStore, preferences: PreferencesStore, groupsRestored: @escaping ([DockGroup]) -> Void = { _ in }) {
        self.store = store
        self.preferences = preferences
        self.groupsRestored = groupsRestored
    }

    // MARK: - Export

    func exportSettings() {
        let panel = NSSavePanel()
        panel.title = L10n.Settings.Backup.exportPanelTitle
        panel.message = L10n.Settings.Backup.exportPanelMessage
        panel.prompt = L10n.Settings.Backup.export
        panel.nameFieldStringValue = SettingsBackup.defaultFileName()
        panel.allowedContentTypes = [Self.backupType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        present(panel) { [weak self] url in self?.export(to: url) }
    }

    private func export(to url: URL) {
        // Taken now, so the backup holds what's on screen when the user confirms.
        let backup = SettingsBackup(groups: store, preferences: preferences, appVersion: AppInfo.version)
        isBusy = true
        Task {
            let result = await Task.detached {
                Result { try backup.encoded().write(to: url, options: .atomic) }
            }.value
            isBusy = false
            switch result {
            case .success:
                status = .exported(fileName: url.lastPathComponent)
            case .failure(let error):
                presentAlert(
                    title: L10n.Settings.Backup.exportFailed,
                    message: error.localizedDescription,
                    style: .warning
                )
            }
        }
    }

    // MARK: - Import

    func importSettings() {
        let panel = NSOpenPanel()
        panel.title = L10n.Settings.Backup.importPanelTitle
        panel.message = L10n.Settings.Backup.importPanelMessage(AppInfo.name)
        panel.prompt = L10n.Settings.Backup.importLabel
        panel.allowedContentTypes = [Self.backupType, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        present(panel) { [weak self] url in self?.readBackup(at: url) }
    }

    private func readBackup(at url: URL) {
        isBusy = true
        Task {
            let result = await Task.detached {
                Result { () throws -> SettingsBackup in
                    let data = try Data(contentsOf: url)
                    return try SettingsBackup.decode(from: data)
                }
            }.value
            isBusy = false
            switch result {
            case .success(let backup):
                confirmRestore(of: backup)
            case .failure(let error as SettingsBackupError):
                presentAlert(title: error.localizedDescription, message: Self.rejectionDetail(for: error), style: .warning)
            case .failure(let error):
                presentAlert(title: L10n.Settings.Backup.readFailed, message: error.localizedDescription, style: .warning)
            }
        }
    }

    private func confirmRestore(of backup: SettingsBackup) {
        let summary = SettingsRestoreSummary(backup: backup, currentGroups: store.groups)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.Settings.Backup.confirmTitle
        alert.informativeText = Self.confirmationDetail(for: summary, exportedAt: backup.exportedAt)
        alert.addButton(withTitle: L10n.Settings.Backup.replaceAll)
        alert.addButton(withTitle: L10n.Settings.Backup.merge)
        alert.addButton(withTitle: L10n.Common.cancel)
        alert.buttons.first?.hasDestructiveAction = true
        present(alert) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: self?.restore(backup)
            case .alertSecondButtonReturn: self?.merge(backup)
            default: break
            }
        }
    }

    private func restore(_ backup: SettingsBackup) {
        do {
            try backup.restore(to: store, preferences: preferences)
            groupsRestored(store.groups)
            status = .imported(groupCount: backup.groups.count, appCount: backup.appCount)
        } catch {
            presentAlert(
                title: L10n.Settings.Backup.restoreFailed,
                message: L10n.Settings.Backup.restoreFailedDetail(error.localizedDescription),
                style: .warning
            )
        }
    }

    private func merge(_ backup: SettingsBackup) {
        do {
            let result = try backup.merge(into: store)
            groupsRestored(result.addedGroups)
            status = .merged(
                addedGroupCount: result.addedGroups.count,
                skippedGroupCount: backup.groups.count - result.addedGroups.count
            )
        } catch {
            presentAlert(
                title: L10n.Settings.Backup.mergeFailed,
                message: L10n.Settings.Backup.mergeFailedDetail(error.localizedDescription),
                style: .warning
            )
        }
    }

    // MARK: - Texts

    private static func rejectionDetail(for error: SettingsBackupError) -> String {
        switch error {
        case .notABackup:
            return L10n.Settings.Backup.notABackupDetail
        case .newerSchemaVersion:
            return L10n.Settings.Backup.nothingChanged
        }
    }

    private static func confirmationDetail(for summary: SettingsRestoreSummary, exportedAt: Date) -> String {
        typealias Texts = L10n.Settings.Backup
        var lines: [String] = []
        let exported = exportedAt.timeIntervalSince1970 > 0
            ? exportedAt.formatted(date: .abbreviated, time: .shortened) : nil
        let groups = L10n.Common.groupCount(summary.groupCount)
        let apps = L10n.Common.appCount(summary.appCount)
        switch (summary.groupCount, exported) {
        case (0, nil): lines.append(Texts.confirmNoGroups)
        case (0, let date?): lines.append(Texts.confirmNoGroups(exported: date))
        case (_, nil): lines.append(Texts.confirmContents(groups: groups, apps: apps))
        case (_, let date?): lines.append(Texts.confirmContents(groups: groups, apps: apps, exported: date))
        }

        var replace = [Texts.confirmReplace]
        if summary.replacedGroupCount > 0 {
            replace.append(Texts.confirmReplaced(summary.replacedGroupCount))
        }
        if summary.removedGroupCount > 0 {
            replace.append(Texts.confirmRemoved(summary.removedGroupCount))
        }
        replace.append(Texts.confirmReplaceSettings)
        lines.append(replace.joined(separator: " "))

        var merge = [summary.groupCount == 0
            ? Texts.confirmMergeNothing
            : summary.mergedGroupCount == 0
            ? Texts.confirmMergeAllHere
            : Texts.confirmMergeAdds(
                groups: L10n.Common.groupCount(summary.mergedGroupCount),
                apps: L10n.Common.appCount(summary.mergedAppCount)
            )]
        if summary.mergedGroupCount > 0, summary.skippedGroupCount > 0 {
            merge.append(Texts.confirmSkipped(summary.skippedGroupCount))
        }
        lines.append(merge.joined(separator: " "))

        lines.append(Texts.confirmFinal)
        return lines.joined(separator: "\n\n")
    }

    // MARK: - Presentation

    private func present(_ panel: NSSavePanel, then handle: @escaping (URL) -> Void) {
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            handle(url)
        }
        if let window, window.isVisible {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            NSApp.activate()
            panel.begin(completionHandler: completion)
        }
    }

    private func present(_ alert: NSAlert, then handle: @escaping (NSApplication.ModalResponse) -> Void = { _ in }) {
        if let window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            NSApp.activate()
            handle(alert.runModal())
        }
    }

    private func presentAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        present(alert)
    }
}
