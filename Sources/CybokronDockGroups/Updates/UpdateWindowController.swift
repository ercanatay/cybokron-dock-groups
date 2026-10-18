import AppKit
import DockGroupsCore
import SwiftUI

/// The update window: a small, non-modal window that follows `AutoUpdater` — checking, up to date,
/// a new version with its release notes, download progress, or what went wrong. It never blocks the
/// app (no alert or modal session), so the menu bar keeps working while it's open.
@MainActor
final class UpdateWindowController: NSWindowController {
    init(updater: AutoUpdater) {
        let hostingController = NSHostingController(rootView: UpdateView(updater: updater))
        hostingController.sizingOptions = [.preferredContentSize]

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Software Update"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        shouldCascadeWindows = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows the window and brings the app to the front.
    func show() {
        NSApp.activate()
        if let window, !window.isVisible {
            window.layoutIfNeeded()
            window.center()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct UpdateView: View {
    static let width: CGFloat = 500

    @ObservedObject var updater: AutoUpdater

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var content: some View {
        switch updater.status {
        case .idle, .checking:
            title("Checking for updates…")
            ProgressView()
                .progressViewStyle(.linear)
            buttons {
                Spacer()
                Button("Cancel") { updater.remindLater() }
                    .keyboardShortcut(.cancelAction)
            }

        case .upToDate(let version):
            title("You're up to date!")
            Text("\(AppInfo.name) \(version.description) is the newest version available.")
                .foregroundStyle(.secondary)
            links(pageURL: nil)
            buttons {
                Spacer()
                Button("OK") { updater.remindLater() }
                    .keyboardShortcut(.defaultAction)
            }

        case .available(let release, let asset):
            title("A new version of \(AppInfo.name) is available!")
            Text("Version \(release.version.description) is available — you have \(currentVersionText). \(asset == nil ? "This release has no disk image for automatic installation; download it from its release page." : "Would you like to download and install it now?")")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ReleaseNotesView(release: release)
            links(pageURL: release.pageURL)
            buttons {
                Button("Skip This Version") { updater.skip(release) }
                Spacer()
                Button("Remind Me Later") { updater.remindLater() }
                    .keyboardShortcut(.cancelAction)
                if asset == nil {
                    Button("Open Release Page") { open(release.pageURL ?? UpdateLinks.releasesPage) }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Download and Install") { updater.downloadAndInstall() }
                        .keyboardShortcut(.defaultAction)
                }
            }

        case .downloading(let release, let fraction):
            title("Downloading version \(release.version.description)…")
            ProgressView(value: min(max(fraction, 0), 1))
                .progressViewStyle(.linear)
            Text("\(Int((fraction * 100).rounded())) %")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

        case .installing(let release):
            title("Installing version \(release.version.description)…")
            ProgressView()
                .progressViewStyle(.linear)
            Text("\(AppInfo.name) restarts when it's done.")
                .foregroundStyle(.secondary)

        case .restarting(let release):
            title("Installed version \(release.version.description) — restarting…")
            ProgressView()
                .progressViewStyle(.linear)
            Text("\(AppInfo.name) is reopening.")
                .foregroundStyle(.secondary)

        case .stagedForDryRun(let release, let path):
            title("Dry run finished")
            Text("Version \(release.version.description) was downloaded, verified and copied to \(path). Nothing was replaced.")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            buttons {
                Spacer()
                Button("OK") { updater.remindLater() }
                    .keyboardShortcut(.defaultAction)
            }

        case .checkFailed(let message):
            title("Couldn't check for updates")
            failure(message)
            links(pageURL: nil)
            buttons {
                Button("Open Releases Page") { open(UpdateLinks.releasesPage) }
                Spacer()
                Button("Close") { updater.remindLater() }
                    .keyboardShortcut(.cancelAction)
                Button("Try Again") { updater.checkNow() }
                    .keyboardShortcut(.defaultAction)
            }

        case .installFailed(let release, let asset, let message):
            title("Version \(release.version.description) couldn't be installed")
            failure(message)
            links(pageURL: release.pageURL)
            buttons {
                Button("Open Release Page") { open(release.pageURL ?? UpdateLinks.releasesPage) }
                Spacer()
                Button("Close") { updater.remindLater() }
                    .keyboardShortcut(.cancelAction)
                if asset != nil {
                    Button("Try Again") { updater.downloadAndInstall() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var currentVersionText: String {
        updater.currentVersion?.description ?? AppInfo.version
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func failure(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func links(pageURL: URL?) -> some View {
        HStack(spacing: 16) {
            Link("Changelog", destination: UpdateLinks.changelog)
            Link(pageURL == nil ? "Releases" : "Release Page", destination: pageURL ?? UpdateLinks.releasesPage)
        }
        .font(.callout)
    }

    private func buttons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            content()
        }
        .padding(.top, 4)
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

/// The release notes, scrollable. GitHub's notes are Markdown; headings and list bullets are
/// simplified so inline Markdown (bold, links, code) renders.
private struct ReleaseNotesView: View {
    let release: ReleaseInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Release Notes")
                .font(.subheadline.weight(.semibold))
            ScrollView {
                Text(notes)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 160)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
        }
    }

    private var notes: AttributedString {
        let text = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return AttributedString("This release has no notes.") }
        let simplified = text
            .components(separatedBy: .newlines)
            .map(Self.simplify)
            .joined(separator: "\n")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: simplified, options: options)) ?? AttributedString(text)
    }

    /// `## Title` becomes bold, `- item` / `* item` a bullet.
    private static func simplify(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") {
            let title = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? "" : "**\(title)**"
        }
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            let indent = String(line.prefix { $0 == " " })
            return indent + "• " + trimmed.dropFirst(2)
        }
        return line
    }
}
