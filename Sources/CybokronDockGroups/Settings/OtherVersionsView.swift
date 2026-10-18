import DockGroupsCore
import SwiftUI

/// Settings → Updates → "Other Versions…": the published releases (no drafts or prereleases), newest
/// first, each with Install — older or newer than the running version. Installing asks first, then
/// closes the sheet and follows in the update window like any update.
struct OtherVersionsView: View {
    @ObservedObject var updater: AutoUpdater
    let dismiss: () -> Void

    @State private var pending: PendingInstall?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Other Versions")
                .font(.headline)
            Text("Install any published release of \(AppInfo.name), older or newer. The app quits and reopens as the version you pick.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content
                .frame(height: 260)
            HStack {
                Link("Open Releases Page on GitHub", destination: UpdateLinks.releasesPage)
                    .font(.callout)
                Spacer()
                Button("Done", action: dismiss)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { updater.loadReleases() }
        .alert(
            pending?.title ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { pending in
            Button("Cancel", role: .cancel) {}
            Button("Install") {
                dismiss()
                updater.installPicked(pending.release, from: pending.releases)
            }
        } message: { pending in
            Text(pending.message)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch updater.releaseList {
        case .idle, .loading:
            VStack(spacing: 8) {
                ProgressView()
                Text("Loading releases from GitHub…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            VStack(spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { updater.loadReleases(force: true) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded(let releases) where releases.isEmpty:
            Text("GitHub lists no published releases.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded(let releases):
            List(releases, id: \.tagName) { release in
                row(release, in: releases)
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
        }
    }

    private func row(_ release: ReleaseInfo, in releases: [ReleaseInfo]) -> some View {
        let isCurrent = release.version == updater.currentVersion
        let hasInstaller = release.installerAsset != nil
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("v\(release.version.description)")
                    .font(.body.monospacedDigit().weight(isCurrent ? .semibold : .regular))
                if let date = release.publishedAt {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if isCurrent {
                Text("Current")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.18), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }
            Spacer()
            if !isCurrent {
                if !hasInstaller {
                    Text("No download")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Install") {
                    pending = PendingInstall(release: release, releases: releases, current: updater.currentVersion)
                }
                .disabled(!hasInstaller || updater.isBusy)
                .help(hasInstaller ? "Install version \(release.version.description)" : "This release has no disk image to install from.")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// A version waiting for confirmation, with what installing it means.
private struct PendingInstall {
    let release: ReleaseInfo
    let releases: [ReleaseInfo]
    let current: SemanticVersion?

    private var target: SemanticVersion { release.version }

    private var change: VersionChange? {
        current.map { ReleaseHistory.change(from: $0, to: target) }
    }

    var title: String {
        "Install version \(target.description)?"
    }

    var message: String {
        var parts = ["\(AppInfo.name) quits and reopens as version \(target.description)."]
        switch change {
        case .downgrade:
            let newer = current.map { ReleaseHistory.versionsSkipped(goingBackTo: target, from: $0, in: releases) }?.map(\.description) ?? []
            if target < ReleaseHistory.firstSelfUpdatingVersion {
                parts.append("Version \(target.description) can't update itself: to come back, download a newer version from the releases page.")
            } else if !newer.isEmpty {
                parts.append("Automatic checks then skip the newer versions (\(newer.joined(separator: ", "))); Check for Updates… still offers them.")
            }
            parts.append("An older version may not know about features added since; consider exporting a backup first (Settings → Backup).")
        case .upgrade:
            parts.append("Skipped versions are cleared, so automatic checks offer every newer release again.")
        case .reinstall, nil:
            break
        }
        return parts.joined(separator: " ")
    }
}
