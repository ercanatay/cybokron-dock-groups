import AppKit
import SwiftUI

/// The About window: the app icon, version and license, and where the idea came from.
@MainActor
final class AboutWindowController: NSWindowController {
    init() {
        let hostingController = NSHostingController(rootView: AboutView())
        hostingController.sizingOptions = [.preferredContentSize]

        let window = NSWindow(contentViewController: hostingController)
        window.title = "About \(AppInfo.name)"
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

private struct AboutView: View {
    static let iconSize: CGFloat = 64

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: Self.iconSize, height: Self.iconSize)
                .accessibilityLabel("\(AppInfo.name) icon")
            Text(AppInfo.name)
                .font(.title2.weight(.semibold))
            Text("Version \(AppInfo.version) · open source, MIT License")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("Inspired by the functionality of DockGroups. Cybokron Dock Groups is an independent, original implementation written from scratch; it contains no code or artwork from DockGroups.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            HStack(spacing: 16) {
                Link("Source Code", destination: AppInfo.repositoryURL)
                Link("License", destination: AppInfo.licenseURL)
            }
            .padding(.top, 2)
            if let copyright = AppInfo.copyright {
                Text(copyright)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(width: 360)
    }
}
