import AppKit
import DockGroupsCore
import SwiftUI

/// Fixed sizes of the popup, in points.
enum PopupMetrics {
    static let headerHeight: CGFloat = 56
    static let footerHeight: CGFloat = 28
    /// Header, footer and the two hairlines between them and the grid.
    static let chromeHeight: CGFloat = headerHeight + footerHeight + 2
    /// Narrowest popup; keeps the header readable for one-column groups.
    static let minimumWidth: CGFloat = 380
    static let headerTileSize: CGFloat = 30
    static let iconSize: CGFloat = 52

    static func grid(showsTitles: Bool) -> PopupGridMetrics {
        PopupGridMetrics(cellWidth: 84, cellHeight: showsTitles ? 86 : 70, spacing: 4, padding: 12)
    }
}

/// One app in the popup grid, with what the cell needs precomputed.
struct PopupCell: Identifiable {
    let app: AppReference
    let icon: NSImage
    let isInstalled: Bool

    var id: String { app.id }
}

/// Everything the popup shows for one group.
struct PopupContent {
    let group: DockGroup
    let tileImage: NSImage
    let cells: [PopupCell]
    let layout: PopupGridLayout
    let metrics: PopupGridMetrics
    let showsTitles: Bool
    /// Size of the whole panel.
    let size: CGSize
    /// Height of the grid area; smaller than the content when the grid scrolls.
    let gridHeight: CGFloat
    let scrolls: Bool
    let usesFrostedGlass: Bool
}

struct PopupActions {
    let open: (AppReference) -> Void
    let openAll: () -> Void
    let closeAll: (QuitMode) -> Void
    let manageGroups: () -> Void
}

/// The popup: the group's tile and name with Open All / Close All, the app grid, and a hint line.
struct PopupContentView: View {
    let content: PopupContent
    @ObservedObject var runningApps: RunningAppsMonitor
    @ObservedObject var modifierKeys: ModifierKeyState
    let actions: PopupActions

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = PanelPalette.forScheme(colorScheme)
        VStack(spacing: 0) {
            header(palette)
            Rectangle().fill(palette.hairline).frame(height: 1)
            grid(palette)
            Rectangle().fill(palette.hairline).frame(height: 1)
            footer(palette)
        }
        .frame(width: content.size.width, height: content.size.height)
        .background(content.usesFrostedGlass ? palette.glassTint : palette.solidBackground)
    }

    // MARK: - Header

    private func header(_ palette: PanelPalette) -> some View {
        let group = content.group
        let runningCount = runningApps.runningCount(in: group)
        let quitMode = modifierKeys.quitMode
        return HStack(spacing: 10) {
            Image(nsImage: content.tileImage)
                .resizable()
                .interpolation(.high)
                .frame(width: PopupMetrics.headerTileSize, height: PopupMetrics.headerTileSize)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(summary(appCount: group.apps.count, runningCount: runningCount))
                    .font(.system(size: 11))
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Open All", action: actions.openAll)
                .buttonStyle(PillButtonStyle(tint: PanelPalette.teal, filled: true))
                .fixedSize()
                .disabled(group.apps.isEmpty)
                .help("Open every app in this group; running apps come to the front.")
            Button(quitMode == .force ? "Force Quit" : "Close All") {
                // The keys held during the click decide, even if no flags change was seen.
                let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
                actions.closeAll(QuitMode(modifierFlags: flags))
            }
            .buttonStyle(PillButtonStyle(tint: quitMode == .force ? PanelPalette.warning : PanelPalette.indigo, filled: false))
            .fixedSize()
            .disabled(runningCount == 0)
            .help("Quit this group's running apps. ⌘-click to force quit without saving.")
        }
        .padding(.horizontal, 14)
        .frame(height: PopupMetrics.headerHeight)
    }

    private func summary(appCount: Int, runningCount: Int) -> String {
        let apps = appCount == 1 ? "1 app" : "\(appCount) apps"
        return runningCount > 0 ? "\(apps) · \(runningCount) running" : apps
    }

    // MARK: - Grid

    @ViewBuilder
    private func grid(_ palette: PanelPalette) -> some View {
        if content.cells.isEmpty {
            emptyState(palette)
                .frame(maxWidth: .infinity)
                .frame(height: content.gridHeight)
        } else {
            let metrics = content.metrics
            let columns = Array(
                repeating: GridItem(.fixed(metrics.cellWidth), spacing: metrics.spacing),
                count: content.layout.columns
            )
            ScrollView(.vertical) {
                LazyVGrid(columns: columns, spacing: metrics.spacing) {
                    ForEach(content.cells) { cell in
                        PopupAppCell(
                            cell: cell,
                            isRunning: runningApps.isRunning(cell.app),
                            showsTitle: content.showsTitles,
                            metrics: metrics,
                            palette: palette
                        ) {
                            actions.open(cell.app)
                        }
                    }
                }
                .padding(metrics.padding)
                .frame(maxWidth: .infinity)
            }
            .scrollDisabled(!content.scrolls)
            .scrollIndicators(content.scrolls ? .automatic : .hidden)
            .frame(height: content.gridHeight)
        }
    }

    private func emptyState(_ palette: PanelPalette) -> some View {
        VStack(spacing: 6) {
            Text("No apps in this group yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.secondaryText)
            Button("Add Apps…", action: actions.manageGroups)
                .buttonStyle(PillButtonStyle(tint: PanelPalette.teal, filled: false))
        }
    }

    // MARK: - Footer

    private func footer(_ palette: PanelPalette) -> some View {
        HStack(spacing: 0) {
            Text("Close All:  ⌥-click quits normally  ·  ⌘-click force quits")
                .font(.system(size: 10.5))
                .foregroundStyle(palette.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: PopupMetrics.footerHeight)
    }
}

/// An app in the grid: its icon with a running indicator and, optionally, its name.
private struct PopupAppCell: View {
    let cell: PopupCell
    let isRunning: Bool
    let showsTitle: Bool
    let metrics: PopupGridMetrics
    let palette: PanelPalette
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(nsImage: cell.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: PopupMetrics.iconSize, height: PopupMetrics.iconSize)
                    .opacity(cell.isInstalled ? 1 : 0.35)
                Circle()
                    .fill(isRunning ? PanelPalette.teal : Color.clear)
                    .frame(width: 4, height: 4)
                if showsTitle {
                    Text(cell.app.name)
                        .font(.system(size: 11))
                        .foregroundStyle(cell.isInstalled ? palette.primaryText : palette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.top, 6)
            .frame(width: metrics.cellWidth, height: metrics.cellHeight, alignment: .top)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isHovered ? palette.hover : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(CellButtonStyle(pressedFill: palette.pressed))
        .onHover { isHovered = $0 }
        .help(helpText)
        .accessibilityLabel(cell.app.name)
        .accessibilityHint(isRunning ? "Brings the app to the front" : "Opens the app")
    }

    private var helpText: String {
        guard cell.isInstalled else { return "\(cell.app.name) isn't on this Mac." }
        return isRunning ? "Bring \(cell.app.name) to the front" : "Open \(cell.app.name)"
    }
}

/// Shrinks the cell slightly and deepens its highlight while pressed.
private struct CellButtonStyle: ButtonStyle {
    let pressedFill: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(configuration.isPressed ? pressedFill : Color.clear)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// Capsule buttons of the popup header, filled or outlined in an accent color.
struct PillButtonStyle: ButtonStyle {
    let tint: Color
    let filled: Bool

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(filled ? Color(.sRGB, red: 0.02, green: 0.12, blue: 0.11) : tint)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(
                Capsule(style: .continuous)
                    .fill(filled ? tint : tint.opacity(configuration.isPressed ? 0.24 : 0.12))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(filled ? Color.clear : tint.opacity(0.55), lineWidth: 1)
            )
            .opacity(isEnabled ? (configuration.isPressed && filled ? 0.8 : 1) : 0.4)
            .contentShape(Capsule(style: .continuous))
    }
}
