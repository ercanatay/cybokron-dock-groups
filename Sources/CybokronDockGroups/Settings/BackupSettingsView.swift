import DockGroupsCore
import SwiftUI

/// Backup: export the groups and settings to a file, and restore them from one. Diagnostics: a
/// report to attach to a support request.
struct BackupSettingsView: View {
    @ObservedObject var backup: SettingsBackupController
    @ObservedObject var diagnostics: DiagnosticsController

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Button("Export Settings…") { backup.exportSettings() }
                        .disabled(backup.isBusy)
                } label: {
                    Text("Export")
                    Text("Saves your groups and settings to a .dockgroups file.")
                }
                LabeledContent {
                    Button("Import Settings…") { backup.importSettings() }
                        .disabled(backup.isBusy)
                } label: {
                    Text("Import")
                    Text("Replaces your groups and settings with the ones in a backup file, or merges the backup's new groups into yours.")
                }
                if let status {
                    Label(status, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            } header: {
                Text("Backup")
            } footer: {
                Text("The backup holds your groups, their apps and every setting. Most Used launch counts aren't included. The file stays wherever you save it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        Button(diagnostics.feedback == .copied ? "Copied" : "Copy") { diagnostics.copyToClipboard() }
                            .disabled(diagnostics.isBusy)
                        Button("Save to File…") { diagnostics.saveToFile() }
                            .disabled(diagnostics.isBusy)
                    }
                } label: {
                    Text("Export Diagnostics")
                    Text("A text report to attach to a GitHub issue or a support request.")
                }
                if let feedback = diagnosticsFeedback {
                    Label(feedback.text, systemImage: feedback.isFailure ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(feedback.isFailure ? .orange : .green)
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Lists the app and macOS versions, your Mac's model, where the app is installed, Accessibility access, your settings, update checks, your group names with their app counts, and recent errors. It doesn't list the apps in your groups. Nothing is sent anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var status: String? {
        switch backup.status {
        case .exported(let fileName):
            return "Exported to “\(fileName)”"
        case .imported(let groupCount, let appCount):
            let groups = "\(groupCount) group\(groupCount == 1 ? "" : "s")"
            let apps = "\(appCount) app\(appCount == 1 ? "" : "s")"
            return "Restored \(groups) with \(apps)"
        case .merged(let addedGroupCount, let skippedGroupCount):
            let added = "\(addedGroupCount) group\(addedGroupCount == 1 ? "" : "s")"
            let skipped = skippedGroupCount > 0 ? "; \(skippedGroupCount) already here" : ""
            return "Merged \(added) from the backup\(skipped)"
        case nil:
            return nil
        }
    }

    private var diagnosticsFeedback: (text: String, isFailure: Bool)? {
        switch diagnostics.feedback {
        case .copied:
            return ("Diagnostics copied to the clipboard", false)
        case .saved(let fileName):
            return ("Saved to “\(fileName)”", false)
        case .failed(let message):
            return ("The report couldn't be saved: \(message)", true)
        case nil:
            return nil
        }
    }
}
