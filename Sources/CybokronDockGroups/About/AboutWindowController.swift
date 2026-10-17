import AppKit
import SwiftUI
import DockGroupsCore

/// The About window: the app icon, version and license, and where the idea came from.
@MainActor
final class AboutWindowController: NSWindowController {
    init() {
        let hostingController = NSHostingController(rootView: AboutView())
        hostingController.sizingOptions = []

        let window = NSWindow(contentViewController: hostingController)
        window.title = "About \(AppInfo.name)"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: AboutView.width, height: 720))
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
    static let width: CGFloat = 460
    static let iconSize: CGFloat = 64

    @Environment(\.colorScheme) private var scheme
    private var palette: PanelPalette { PanelPalette.forScheme(scheme) }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                supportSection
                header
                section("My Books") {
                    VStack(spacing: 8) {
                        ForEach(AboutData.books) { BookCard(book: $0, palette: palette) }
                    }
                }
                section("My Open Source Software") {
                    VStack(spacing: 8) {
                        ForEach(AboutData.projects) { project in
                            LinkRow(title: project.title, subtitle: project.subtitle, symbol: project.symbol,
                                    url: project.url, palette: palette)
                        }
                        Text("Full list at github.com/ercanatay")
                            .font(.caption)
                            .foregroundStyle(palette.secondaryText)
                    }
                }
                section("Medium Blogs") {
                    VStack(spacing: 8) {
                        ForEach(AboutData.blogs) { blog in
                            LinkRow(title: blog.title, subtitle: blog.subtitle, symbol: "text.book.closed",
                                    url: blog.url, palette: palette)
                        }
                    }
                }
                footer
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
        .frame(width: Self.width, height: 720)
        .background(palette.solidBackground)
    }

    private var supportSection: some View {
        section("Support This Project") {
            HStack(spacing: 8) {
                ForEach(AboutData.donations) { donation in
                    Button { NSWorkspace.shared.open(donation.url) } label: {
                        Label(donation.title, systemImage: donation.symbol)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .foregroundStyle(.white)
                            .background(LinearGradient(colors: [PanelPalette.teal, PanelPalette.indigo],
                                                       startPoint: .leading, endPoint: .trailing).opacity(0.85),
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help(donation.url.absoluteString)
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: Self.iconSize, height: Self.iconSize)
                .accessibilityLabel("\(AppInfo.name) icon")
            Text(AppInfo.name)
                .font(.title2.weight(.semibold))
                .foregroundStyle(palette.primaryText)
            Text("Version \(AppInfo.version) · open source, MIT License")
                .foregroundStyle(palette.secondaryText)
                .textSelection(.enabled)
            VStack(spacing: 4) {
                HStack(spacing: 16) {
                    Link("Source Code", destination: AppInfo.repositoryURL)
                    Link("License", destination: AppInfo.licenseURL)
                    Link("Changelog", destination: UpdateLinks.changelog)
                }
                Link("Found a bug? Open an issue", destination: AboutData.issuesURL)
            }
            .tint(PanelPalette.teal)
            .font(.callout)
        }
    }

    private var footer: some View {
        VStack(spacing: 6) {
            Text("Inspired by the functionality of DockGroups. Cybokron Dock Groups is an independent, original implementation written from scratch; it contains no code or artwork from DockGroups.")
                .font(.callout)
            if let copyright = AppInfo.copyright {
                Text(copyright).font(.caption)
            }
        }
        .foregroundStyle(palette.secondaryText)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(PanelPalette.teal)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BookCard: View {
    let book: AboutData.Book
    let palette: PanelPalette

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: book.coverURL) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                Image(systemName: "book.closed.fill")
                    .foregroundStyle(palette.secondaryText)
            }
            .frame(width: 44, height: 62)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            VStack(alignment: .leading, spacing: 6) {
                Text(book.titleLine)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(palette.primaryText)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 8) {
                    languageButton("🌐 English", url: book.englishURL)
                    languageButton("🇹🇷 Türkçe", url: book.turkishURL)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(palette.hover.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.hairline))
    }

    private func languageButton(_ title: String, url: URL) -> some View {
        Button { NSWorkspace.shared.open(url) } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .foregroundStyle(.white)
                .background(PanelPalette.indigo.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(url.absoluteString)
    }
}

private struct LinkRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let url: URL
    let palette: PanelPalette

    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .frame(width: 22)
                    .foregroundStyle(PanelPalette.teal)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.medium)).foregroundStyle(palette.primaryText)
                    Text(subtitle).font(.caption).foregroundStyle(palette.secondaryText)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(palette.secondaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(palette.hover.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
