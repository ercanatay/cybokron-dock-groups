import DockGroupsCore
import SwiftUI

/// Updates: automatic checks, checking right away, when the last check ran and what it found, the
/// skipped versions, installing another published version, and links to the releases and the
/// changelog.
struct UpdatesSettingsView: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var updater: AutoUpdater

    @State private var isShowingOtherVersions = false

    var body: some View {
        Form {
            Section {
                Toggle("Automatically check for updates", isOn: binding(\.automaticallyChecksForUpdates))
                LabeledContent("Current version") {
                    Text("v\(AppInfo.version)")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent("Last checked") {
                    Text(lastChecked)
                        .foregroundStyle(.secondary)
                }
                LabeledContent {
                    Button("Check Now") { updater.checkNow() }
                        .disabled(updater.isBusy)
                } label: {
                    status
                }
                LabeledContent {
                    Button("Other Versions…") { isShowingOtherVersions = true }
                        .disabled(updater.isBusy)
                } label: {
                    skippedVersions
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("Checks the project's GitHub releases at launch and every 6 hours; only the app's version number is sent along. A new version is installed only after you choose Download and Install. Other Versions… installs any published release, older or newer; going back skips the newer ones in automatic checks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Link(destination: UpdateLinks.releasesPage) {
                    Label("Open Releases Page", systemImage: "arrow.up.right.square")
                }
                Link(destination: UpdateLinks.changelog) {
                    Label("View Changelog", systemImage: "doc.text")
                }
            } header: {
                Text("Links")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $isShowingOtherVersions) {
            OtherVersionsView(updater: updater) { isShowingOtherVersions = false }
        }
    }

    /// Which newer versions automatic checks skip, next to "Other Versions…". Skips of versions not
    /// newer than the running one don't matter any more and aren't shown.
    @ViewBuilder
    private var skippedVersions: some View {
        let newer = updater.skippedVersions.filter { skipped in
            guard let current = updater.currentVersion, let version = SemanticVersion(skipped) else { return true }
            return version > current
        }
        if newer.isEmpty {
            Text("Back on the latest path: every newer release is offered")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(spacing: 8) {
                Text("Skipped newer versions: \(newer.joined(separator: ", "))")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Clear") { updater.clearSkippedVersions() }
                    .controlSize(.small)
                    .help("Let automatic checks offer these versions again")
            }
        }
    }

    private var lastChecked: String {
        guard let date = updater.lastCheckDate else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// One line about the latest check, under the Check Now button's label.
    @ViewBuilder
    private var status: some View {
        switch updater.status {
        case .idle:
            Text("Not checked since the app started")
                .foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…")
            }
        case .upToDate(let version):
            Label("You're up to date (v\(version.description))", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .available(let release, _), .stagedForDryRun(let release, _):
            HStack(spacing: 8) {
                Label("Version \(release.version.description) is available", systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
                Button("Show Update…") { updater.showWindow() }
                    .controlSize(.small)
            }
        case .downloading(let release, _), .installing(let release):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Installing version \(release.version.description)…")
            }
        case .restarting(let release):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Installed version \(release.version.description) — restarting…")
            }
        case .checkFailed(let message), .installFailed(_, _, let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<PopupPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { preferences.preferences[keyPath: keyPath] },
            set: { newValue in preferences.update { $0[keyPath: keyPath] = newValue } }
        )
    }
}
