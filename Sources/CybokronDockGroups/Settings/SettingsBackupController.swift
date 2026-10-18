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

    /// `.dockgroups` files are JSON.
    static let backupType = UTType(filenameExtension: SettingsBackup.fileExtension, conformingTo: .json) ?? .json

    init(store: GroupStore, preferences: PreferencesStore) {
        self.store = store
        self.preferences = preferences
    }

    // MARK: - Export

    func exportSettings() {
        let panel = NSSavePanel()
        panel.title = "Export Settings"
        panel.message = "Save your groups and settings to a backup file."
        panel.prompt = "Export"
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
                    title: "The settings couldn't be exported",
                    message: error.localizedDescription,
                    style: .warning
                )
            }
        }
    }

    // MARK: - Import

    func importSettings() {
        let panel = NSOpenPanel()
        panel.title = "Import Settings"
        panel.message = "Choose a Cybokron Dock Groups backup to restore."
        panel.prompt = "Import"
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
                presentAlert(title: "The file couldn't be read", message: error.localizedDescription, style: .warning)
            }
        }
    }

    private func confirmRestore(of backup: SettingsBackup) {
        let summary = SettingsRestoreSummary(backup: backup, currentGroups: store.groups)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Import the groups and settings in this backup?"
        alert.informativeText = Self.confirmationDetail(for: summary, exportedAt: backup.exportedAt)
        alert.addButton(withTitle: "Replace All")
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Cancel")
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
            status = .imported(groupCount: backup.groups.count, appCount: backup.appCount)
        } catch {
            presentAlert(
                title: "The backup couldn't be restored",
                message: "\(error.localizedDescription) Your current groups and settings were kept.",
                style: .warning
            )
        }
    }

    private func merge(_ backup: SettingsBackup) {
        do {
            let result = try backup.merge(into: store)
            status = .merged(
                addedGroupCount: result.addedGroups.count,
                skippedGroupCount: backup.groups.count - result.addedGroups.count
            )
        } catch {
            presentAlert(
                title: "The backup couldn't be merged",
                message: "\(error.localizedDescription) Your current groups were kept.",
                style: .warning
            )
        }
    }

    // MARK: - Texts

    private static func rejectionDetail(for error: SettingsBackupError) -> String {
        switch error {
        case .notABackup:
            return "Choose a .dockgroups file made with Export Settings…. Nothing was changed."
        case .newerSchemaVersion:
            return "Nothing was changed."
        }
    }

    private static func confirmationDetail(for summary: SettingsRestoreSummary, exportedAt: Date) -> String {
        var lines: [String] = []
        let exported = exportedAt.timeIntervalSince1970 > 0
            ? ", exported \(exportedAt.formatted(date: .abbreviated, time: .shortened))" : ""
        if summary.groupCount == 0 {
            lines.append("The backup has no groups\(exported).")
        } else {
            lines.append("The backup has \(count(summary.groupCount, "group")) with \(count(summary.appCount, "app"))\(exported).")
        }

        var replace = "Replace All uses the backup's groups and settings instead of yours."
        if summary.replacedGroupCount > 0 {
            replace += " \(count(summary.replacedGroupCount, "current group")) with the same name as a group in the backup will be replaced by it."
        }
        if summary.removedGroupCount > 0 {
            replace += " \(count(summary.removedGroupCount, "current group")) not in the backup will be removed."
        }
        replace += " Your settings (popup, shortcuts, Most Used and updates) will be replaced too."
        lines.append(replace)

        var merge = summary.groupCount == 0
            ? "Merge keeps your groups and settings and adds nothing."
            : summary.mergedGroupCount == 0
            ? "Merge keeps your groups and settings; every group in the backup is already here, so it adds nothing."
            : "Merge keeps your groups and settings and adds \(count(summary.mergedGroupCount, "group")) with \(count(summary.mergedAppCount, "app")) from the backup."
        if summary.mergedGroupCount > 0, summary.skippedGroupCount > 0 {
            merge += " \(count(summary.skippedGroupCount, "group")) already here (same name) will be skipped."
        }
        lines.append(merge)

        lines.append("The Most Used launch counts are kept. A copy of your current files is saved next to them in Application Support. This can't be undone.")
        return lines.joined(separator: "\n\n")
    }

    private static func count(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
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
