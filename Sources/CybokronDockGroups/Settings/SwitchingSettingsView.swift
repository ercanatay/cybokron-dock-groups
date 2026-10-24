import AppKit
import DockGroupsCore
import SwiftUI

/// Settings → Switching (spec §2.8, §4.4): the protected apps — which Start, Finish and Close All
/// never quit, and switching never hides — added with an open panel or from the running apps, and
/// what Start and Finish do, with the current group. Each group's own Start and Finish settings
/// are in its group window.
struct SwitchingSettingsView: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var store: GroupStore
    @ObservedObject var session: ContextSession
    /// Redraws the pane when apps launch or quit, so "Add a Running App" lists the running ones.
    @ObservedObject var runningApps: RunningAppsMonitor
    let icons: AppIconProviding

    /// Why apps chosen in the open panel couldn't be added.
    @State private var problem: String?

    private var protectedApps: ProtectedApps { preferences.preferences.protectedApps }

    var body: some View {
        Form {
            protectedSection
            startSection
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .alert(
            L10n.GroupWindow.addAppsProblemTitle,
            isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })
        ) {
            Button(L10n.Common.ok) { problem = nil }
        } message: {
            Text(problem ?? "")
        }
    }

    // MARK: - Protected apps

    private var protectedSection: some View {
        Section {
            if protectedApps.isEmpty {
                Text(L10n.Switching.Settings.protectedEmpty)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(protectedApps.apps) { app in
                    row(for: app)
                }
            }
            HStack {
                Button(L10n.Common.addApps, action: addApps)
                addRunningAppMenu
                Spacer()
            }
            .disabled(protectedApps.isFull)
            if protectedApps.isFull {
                Text(L10n.Switching.Settings.full(ProtectedApps.maximumCount))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(L10n.Switching.Settings.protectedHeader)
        } footer: {
            Text(L10n.Switching.Settings.protectedFooter(AppInfo.name))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func row(for app: GroupItem) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: icons.icon(for: app))
                .resizable()
                .interpolation(.high)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            Text(app.name)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Button {
                remove(app)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(L10n.Switching.Settings.remove(app.name))
            .accessibilityLabel(L10n.Switching.Settings.remove(app.name))
        }
    }

    /// The running apps that aren't protected yet, read when the pane draws (it does again when an
    /// app launches or quits).
    private var addRunningAppMenu: some View {
        let candidates = protectedApps.addable(from: Self.runningRegularApps())
        return Menu(L10n.Switching.Settings.addRunningApp) {
            if candidates.isEmpty {
                Text(L10n.Switching.Settings.noRunningApps)
            } else {
                ForEach(candidates) { app in
                    Button(app.name) { add([app]) }
                }
            }
        }
        .fixedSize()
    }

    /// The running apps with a Dock icon, as group items: by bundle identifier, or by location
    /// when they have none.
    private static func runningRegularApps() -> [GroupItem] {
        NSWorkspace.shared.runningApplications.compactMap { application in
            guard application.activationPolicy == .regular, !application.isTerminated, let url = application.bundleURL else {
                return nil
            }
            if let identifier = application.bundleIdentifier, !identifier.isEmpty {
                return GroupItem(bundleIdentifier: identifier, name: application.localizedName ?? identifier, path: url.path)
            }
            return try? GroupItem(applicationURL: url)
        }
    }

    private func addApps() {
        AppPicker.chooseApps(
            title: L10n.Switching.Settings.pickerTitle,
            message: L10n.Switching.Settings.pickerMessage,
            attachedTo: NSApp.keyWindow
        ) { urls in
            var apps: [GroupItem] = []
            var failures: [String] = []
            for url in urls {
                do {
                    apps.append(try GroupItem(applicationURL: url))
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
            add(apps)
            if !failures.isEmpty {
                problem = failures.joined(separator: "\n")
            }
        }
    }

    private func add(_ apps: [GroupItem]) {
        guard !apps.isEmpty else { return }
        preferences.update { $0.protectedApps = $0.protectedApps.adding(apps) }
    }

    private func remove(_ app: GroupItem) {
        preferences.update { $0.protectedApps = $0.protectedApps.removing(identity: app.normalizedBundleIdentifier) }
    }

    // MARK: - Start and Finish

    private var startSection: some View {
        let current = session.current.flatMap(store.group(withID:))
        let previous = session.previous.flatMap(store.group(withID:))
        let quitting = store.groups.filter(\.switching.quitsApps)
        return Section {
            Text(L10n.Switching.Settings.startSummary)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent(L10n.Switching.Settings.quittingGroups) {
                Text(quitting.isEmpty ? L10n.Switching.Settings.noCurrentGroup : quitting.map(\.name).joined(separator: ", "))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent(L10n.Switching.Settings.currentGroup) {
                Text(current.map(Self.title(of:)) ?? L10n.Switching.Settings.noCurrentGroup)
                    .foregroundStyle(.secondary)
            }
            if current != nil, let previous {
                LabeledContent(L10n.Switching.Settings.previousGroup) {
                    Text(Self.title(of: previous))
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(L10n.Switching.Settings.startHeader)
        } footer: {
            Text(verbatim: "\(L10n.Switching.Settings.startAsking) \(L10n.Switching.Settings.currentDetail(AppInfo.name))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private static func title(of group: DockGroup) -> String {
        "\(group.emoji)  \(group.name)"
    }
}
