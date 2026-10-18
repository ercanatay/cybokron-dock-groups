import DockGroupsCore
import SwiftUI

/// Backup: export the groups and settings to a file, and restore them from one.
struct BackupSettingsView: View {
    @ObservedObject var backup: SettingsBackupController

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
                    Text("Replaces your groups and settings with the ones in a backup file.")
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
        case nil:
            return nil
        }
    }
}
