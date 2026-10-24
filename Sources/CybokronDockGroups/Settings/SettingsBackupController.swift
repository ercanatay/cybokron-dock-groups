import AppKit
import DockGroupsCore
import UniformTypeIdentifiers

/// Exports the groups — archived ones too — the templates and the preferences to a `.dockgroups`
/// backup file and restores them from one: either replacing everything (the templates only when the
/// backup has some), or merging the backup's new groups and templates into the current ones.
/// Panels and alerts are sheets on the Settings window, and files are read and written off the
/// main thread, so the rest of the app keeps working meanwhile.
@MainActor
final class SettingsBackupController: ObservableObject {
    /// What the last export or import did, shown under the buttons.
    enum Status: Equatable {
        case exported(fileName: String)
        case imported(groupCount: Int, itemCount: Int)
        case merged(addedGroupCount: Int, skippedGroupCount: Int, addedArchivedGroupCount: Int = 0, addedTemplateCount: Int = 0)
    }

    @Published private(set) var isBusy = false
    @Published private(set) var status: Status?

    /// The window the panels and alerts attach to.
    weak var window: NSWindow?

    private let store: GroupStore
    private let preferences: PreferencesStore
    private let templates: TemplateStore
    /// Told about the groups a restore or merge put in the store, so standalone ones get their
    /// Dock tiles (`StandaloneController.adoptRestoredGroups`).
    private let groupsRestored: ([DockGroup]) -> Void

    /// `.dockgroups` files are JSON.
    static let backupType = UTType(filenameExtension: SettingsBackup.fileExtension, conformingTo: .json) ?? .json

    init(
        store: GroupStore,
        preferences: PreferencesStore,
        templates: TemplateStore,
        groupsRestored: @escaping ([DockGroup]) -> Void = { _ in }
    ) {
        self.store = store
        self.preferences = preferences
        self.templates = templates
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
        let backup = SettingsBackup(groups: store, preferences: preferences, templates: templates, appVersion: AppInfo.version)
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
                // At most SettingsBackup.maximumFileSize is read; app locations are checked.
                Result { try SettingsBackup.read(from: url) }
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
        let summary = SettingsRestoreSummary(
            backup: backup,
            currentGroups: store.groups,
            currentArchivedGroups: store.archivedGroups,
            currentTemplates: templates.templates
        )
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
            try backup.restore(to: store, preferences: preferences, templates: templates)
            groupsRestored(store.groups)
            status = .imported(groupCount: backup.groups.count, itemCount: backup.itemCount)
        } catch {
            presentAlert(
                title: L10n.Settings.Backup.restoreFailed,
                message: L10n.Settings.Backup.restoreFailedDetail(error.localizedDescription),
                style: .warning
            )
        }
    }

    private func merge(_ backup: SettingsBackup) {
        let groupsBefore = Set(store.groups.map(\.id))
        do {
            let result = try backup.merge(into: store, templates: templates)
            // Archived groups aren't standalone: only the active ones may need a Dock tile.
            groupsRestored(result.groups.addedGroups)
            status = .merged(
                addedGroupCount: result.groups.addedGroups.count,
                skippedGroupCount: backup.groups.count - result.groups.addedGroups.count,
                addedArchivedGroupCount: result.groups.addedArchivedGroups.count,
                addedTemplateCount: result.addedTemplates.count
            )
        } catch {
            // The groups stay merged when only the templates couldn't be written: standalone ones
            // still get their Dock tiles.
            let added = store.groups.filter { !groupsBefore.contains($0.id) }
            if !added.isEmpty {
                groupsRestored(added)
            }
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
        case .newerSchemaVersion, .tooLarge:
            return L10n.Settings.Backup.nothingChanged
        }
    }

    private static func confirmationDetail(for summary: SettingsRestoreSummary, exportedAt: Date) -> String {
        typealias Texts = L10n.Settings.Backup
        var lines: [String] = []
        let exported = exportedAt.timeIntervalSince1970 > 0
            ? exportedAt.formatted(date: .abbreviated, time: .shortened) : nil
        let groups = L10n.Common.groupCount(summary.groupCount)
        let items = L10n.Common.itemCount(summary.itemCount)
        var contents: String
        switch (summary.groupCount, exported) {
        case (0, nil): contents = Texts.confirmNoGroups
        case (0, let date?): contents = Texts.confirmNoGroups(exported: date)
        case (_, nil): contents = Texts.confirmContents(groups: groups, items: items)
        case (_, let date?): contents = Texts.confirmContents(groups: groups, items: items, exported: date)
        }
        if summary.leftOutItemCount > 0 {
            contents += " " + Texts.leftOut(summary.leftOutItemCount)
        }
        if summary.resetLaunchOptionCount > 0 {
            contents += " " + Texts.launchReset(summary.resetLaunchOptionCount)
        }
        for note in [summary.archivedGroupsNote, summary.templatesNote].compactMap({ $0 }) {
            contents += " " + note
        }
        lines.append(contents)

        var replace = [Texts.confirmReplace]
        if summary.replacedGroupCount > 0 {
            replace.append(Texts.confirmReplaced(summary.replacedGroupCount))
        }
        if summary.removedGroupCount > 0 {
            replace.append(Texts.confirmRemoved(summary.removedGroupCount))
        }
        replace.append(contentsOf: [summary.replacedArchivedGroupsNote, summary.replacedTemplatesNote].compactMap { $0 })
        replace.append(Texts.confirmReplaceSettings)
        lines.append(replace.joined(separator: " "))

        lines.append(mergeDetail(for: summary))

        lines.append(Texts.confirmFinal)
        return lines.joined(separator: "\n\n")
    }

    /// The question's line about Merge: the groups it adds, then the archived groups and templates
    /// (spec §1.10).
    private static func mergeDetail(for summary: SettingsRestoreSummary) -> String {
        typealias Texts = L10n.Settings.Backup
        let addsLibrary = summary.mergedArchivedGroupCount > 0 || summary.mergedTemplateCount > 0
        var merge: [String]
        if summary.mergedGroupCount > 0 {
            merge = [Texts.confirmMergeAdds(
                groups: L10n.Common.groupCount(summary.mergedGroupCount),
                items: L10n.Common.itemCount(summary.mergedItemCount)
            )]
        } else if addsLibrary {
            merge = [Texts.Library.mergeKeeps]
        } else if summary.groupCount == 0, summary.archivedGroupCount == 0 {
            return Texts.confirmMergeNothing
        } else {
            return Texts.confirmMergeAllHere
        }
        if summary.skippedGroupCount > 0 {
            merge.append(Texts.confirmSkipped(summary.skippedGroupCount))
        }
        if summary.mergedArchivedGroupCount > 0 {
            merge.append(Texts.Library.mergesArchived(summary.mergedArchivedGroupCount))
        }
        merge.append(contentsOf: [summary.mergedTemplatesNote, summary.clearedShortcutsNote].compactMap { $0 })
        return merge.joined(separator: " ")
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
