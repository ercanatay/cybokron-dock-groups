import AppKit
import DockGroupsCore
import SwiftUI

/// Fixed sizes of the popup, in points.
enum PopupMetrics {
    static let headerHeight: CGFloat = 56
    static let footerHeight: CGFloat = 28
    /// Header, footer and the two hairlines between them and the grid.
    static let chromeHeight: CGFloat = headerHeight + footerHeight + 2
    /// Narrowest popup; keeps the header (name, Open All, Hide All, Close All) readable for
    /// one-column groups.
    static let minimumWidth: CGFloat = 440
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
    /// Each app's cell while Free Layout is on; `nil` when the apps fill the grid in list order.
    let freeLayout: FreeLayout?
    let metrics: PopupGridMetrics
    let showsTitles: Bool
    /// Size of the whole panel.
    let size: CGSize
    /// Height of the grid area; smaller than the content when the grid scrolls.
    let gridHeight: CGFloat
    let scrolls: Bool
    let usesFrostedGlass: Bool
    /// Whether apps can be reordered and removed; `false` for the Most Used list and in agents.
    let isEditable: Bool
    /// The groups an app can be moved to from its context menu; empty unless the popup is editable.
    let moveTargets: [GroupMoveTarget]
    /// The Most Used list rather than one of the user's groups.
    let isMostUsed: Bool
}

struct PopupActions {
    let open: (AppReference) -> Void
    let openAll: () -> Void
    let closeAll: (QuitMode) -> Void
    /// Hides the running apps; apps that aren't running are left alone.
    let hideAll: () -> Void
    let manageGroups: () -> Void
    /// Asks for a website to add to the group; `nil` where the group can't be edited.
    let addWebsite: (() -> Void)?
    /// Shows the app in Finder.
    let showInFinder: (AppReference) -> Void
    /// Moves the app to this index of the group's app list.
    let moveApp: (AppReference, Int) -> Void
    /// Free Layout: puts the apps in these cells (`FreeLayout.slots`).
    let arrangeApps: ([String: Int]) -> Void
    /// Takes the app out of the group; the app itself isn't affected.
    let removeApp: (AppReference) -> Void
    /// Moves the app to the end of another group.
    let moveAppToGroup: (AppReference, DockGroup.ID) -> Void
    /// Sorts the group's apps by name, A to Z.
    let sortApps: () -> Void
    /// Whether the pointer is far enough outside the popup for a drop to remove the dragged app.
    let isPointerInRemovalArea: () -> Bool
}

/// An app being dragged in the popup grid.
private struct CellDrag: Equatable {
    let id: PopupCell.ID
    /// Where the pointer grabbed the cell, from the cell's top-left corner.
    let grabOffset: CGSize
    /// Top-left corner of the dragged cell, following the pointer (grid coordinates).
    var origin: CGPoint
    /// The slot the app moves to when dropped now: an index of the app list, or in Free Layout a
    /// grid cell.
    var targetIndex: Int
    /// The pointer is outside the popup: dropping removes the app from the group.
    var isInRemovalArea: Bool
}

/// The popup: the group's tile and name with Open All / Hide All / Close All, the app grid, and a
/// hint line.
///
/// Apps can be dragged within the grid to reorder them, and out of the popup to remove them from
/// the group, as with the Dock; their context menu moves them to another group. In Free Layout a
/// dragged app goes to the cell it's dropped on (swapping places with the app there) and the others
/// stay put. The Most Used list is read-only.
///
/// The keyboard (handled by `PopupPanelController`) selects apps and filters them by name: while
/// filtering, the matches are shown packed from the first cell, best first, and can't be dragged.
///
/// A group can hold websites too: they show a globe, open in the default browser and have no
/// running indicator. Each item's context menu opens it, copies a website's address or shows an
/// app in Finder, moves it to another group or removes it, and adds a website.
struct PopupContentView: View {
    let content: PopupContent
    @ObservedObject var runningApps: RunningAppsMonitor
    @ObservedObject var modifierKeys: ModifierKeyState
    @ObservedObject var keyboard: PopupKeyboardState
    let actions: PopupActions

    @Environment(\.colorScheme) private var colorScheme

    @State private var drag: CellDrag?
    /// The order shown after a drop, until the group's new order arrives from the store.
    @State private var droppedOrder: [PopupCell.ID]?
    /// The same for Free Layout: the cells shown after a drop.
    @State private var droppedLayout: FreeLayout?
    /// Set from the start of a drag until just after it ends, so the click that ends a drag doesn't
    /// also open the app.
    @State private var suppressesClick = false

    private static let gridSpace = "PopupGrid"

    /// Scroll target of a cell, for bringing the keyboard selection into view.
    private static func scrollAnchorID(_ id: PopupCell.ID) -> String { "keyboard-anchor-\(id)" }

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
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(summary(runningCount: runningCount))
                    .accessibilityIdentifier("popup-summary")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Open All", action: actions.openAll)
                .buttonStyle(PillButtonStyle(tint: PanelPalette.teal, filled: true))
                .fixedSize()
                .disabled(group.apps.isEmpty)
                .help(content.isMostUsed
                    ? "Open every app in this list; running apps come to the front."
                    : "Open every app in this group; running apps come to the front.")
            Button("Hide All", action: actions.hideAll)
                .buttonStyle(PillButtonStyle(tint: PanelPalette.indigo, filled: false))
                .fixedSize()
                .disabled(runningCount == 0)
                .help(content.isMostUsed
                    ? "Hide this list's running apps; apps that aren't running stay closed."
                    : "Hide this group's running apps; apps that aren't running stay closed.")
            Button(quitMode == .force ? "Force Quit" : "Close All") {
                // The keys held during the click decide, even if no flags change was seen.
                let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
                actions.closeAll(QuitMode(modifierFlags: flags))
            }
            .buttonStyle(PillButtonStyle(tint: quitMode == .force ? PanelPalette.warning : PanelPalette.indigo, filled: false))
            .fixedSize()
            .disabled(runningCount == 0)
            .help(content.isMostUsed
                ? "Quit this list's running apps. ⌘-click to force quit without saving."
                : "Quit this group's running apps. ⌘-click to force quit without saving.")
        }
        .padding(.horizontal, 14)
        .frame(height: PopupMetrics.headerHeight)
    }

    private func summary(runningCount: Int) -> String {
        let websiteCount = content.group.apps.filter(\.isWebsite).count
        let appCount = content.group.apps.count - websiteCount
        var apps = appCount == 1 ? "1 app" : "\(appCount) apps"
        if websiteCount > 0 {
            apps += websiteCount == 1 ? " · 1 website" : " · \(websiteCount) websites"
        }
        let counts = runningCount > 0 ? "\(apps) · \(runningCount) running" : apps
        return content.isMostUsed ? "\(counts) · by launches" : counts
    }

    // MARK: - Grid

    @ViewBuilder
    private func grid(_ palette: PanelPalette) -> some View {
        if content.cells.isEmpty {
            emptyState(palette)
                .frame(maxWidth: .infinity)
                .frame(height: content.gridHeight)
        } else if keyboard.isFiltering {
            filteredGrid(palette)
        } else {
            let metrics = content.metrics
            let layout = content.layout
            let slots = slotIndices()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    // Cells are placed explicitly rather than by a grid view, so the dragged cell can
                    // follow the pointer while the others make room.
                    ZStack(alignment: .topLeading) {
                        if content.freeLayout != nil, drag != nil {
                            emptyCellOutlines(occupied: occupiedCells(slots), palette: palette)
                        }
                        scrollAnchors(content.cells.compactMap { cell in slots[cell.id].map { (cell.id, $0) } })
                        ForEach(content.cells) { cell in
                            cellView(cell, slot: slots[cell.id], palette: palette)
                        }
                    }
                    .frame(
                        width: layout.visibleSize(metrics: metrics).width,
                        height: layout.contentHeight(metrics: metrics),
                        alignment: .topLeading
                    )
                    .coordinateSpace(name: Self.gridSpace)
                    .frame(maxWidth: .infinity)
                    .background(addWebsiteContextMenuArea)
                }
                .scrollDisabled(!content.scrolls)
                .scrollIndicators(content.scrolls ? .automatic : .hidden)
                .onChange(of: keyboard.selectedID) { scrollToSelection(proxy) }
            }
            .frame(height: content.gridHeight)
            .onChange(of: content.cells.map(\.id)) {
                droppedOrder = nil
                droppedLayout = nil
            }
            .onChange(of: content.freeLayout) {
                droppedLayout = nil
            }
            .onChange(of: content.group.id) {
                // A drag cut short (the popup closed under it) mustn't carry over to another group.
                drag = nil
                suppressesClick = false
            }
        }
    }

    /// The matches of the typed filter, best first and packed from the first cell; a "no match" line
    /// when there are none. They open on click as usual but can't be dragged.
    @ViewBuilder
    private func filteredGrid(_ palette: PanelPalette) -> some View {
        let matches = content.navigationItems(query: keyboard.query).cells
        if matches.isEmpty {
            VStack(spacing: 4) {
                Text("No apps match “\(keyboard.query)”")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Press Delete or Esc to clear the filter.")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.secondaryText)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .frame(height: content.gridHeight)
        } else {
            let metrics = content.metrics
            let layout = content.layout
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    ZStack(alignment: .topLeading) {
                        scrollAnchors(matches.enumerated().map { ($1.id, $0) })
                        ForEach(Array(matches.enumerated()), id: \.element.id) { index, cell in
                            filteredCellView(cell, origin: layout.cellOrigin(at: index, metrics: metrics), palette: palette)
                        }
                    }
                    .frame(
                        width: layout.visibleSize(metrics: metrics).width,
                        height: layout.contentHeight(packing: matches.count, metrics: metrics),
                        alignment: .topLeading
                    )
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(content.scrolls ? .automatic : .hidden)
                .onChange(of: keyboard.selectedID) { scrollToSelection(proxy) }
            }
            .frame(height: content.gridHeight)
        }
    }

    private func filteredCellView(_ cell: PopupCell, origin: CGPoint, palette: PanelPalette) -> some View {
        PopupAppCell(
            cell: cell,
            isRunning: runningApps.isRunning(cell.app),
            isEditable: false,
            isFreeLayout: false,
            showsTitle: content.showsTitles,
            metrics: content.metrics,
            palette: palette,
            isDragged: false,
            isInRemovalArea: false,
            highlightsOnHover: true,
            isSelected: keyboard.selectedID == cell.id
        ) {
            actions.open(cell.app)
        }
        .offset(x: origin.x, y: origin.y)
        .modifier(cellContextMenu(cell))
    }

    private func cellContextMenu(_ cell: PopupCell) -> PopupCellContextMenu {
        PopupCellContextMenu(
            cell: cell,
            moveTargets: content.moveTargets,
            isEditable: content.isEditable,
            actions: actions
        )
    }

    /// The empty part of the grid: right-clicking it offers "Add Website…".
    @ViewBuilder
    private var addWebsiteContextMenuArea: some View {
        if content.isEditable, let addWebsite = actions.addWebsite {
            Color.clear
                .contentShape(Rectangle())
                .contextMenu {
                    Button("Add Website…", action: addWebsite)
                }
        }
    }

    /// Invisible views in the cells' places for `ScrollViewProxy.scrollTo`: the cells themselves are
    /// moved with `offset`, which the scroll view doesn't see.
    private func scrollAnchors(_ placements: [(id: PopupCell.ID, slot: Int)]) -> some View {
        let metrics = content.metrics
        return ForEach(placements, id: \.id) { placement in
            let origin = content.layout.cellOrigin(at: placement.slot, metrics: metrics)
            Color.clear
                .frame(width: metrics.cellWidth, height: metrics.cellHeight)
                .id(Self.scrollAnchorID(placement.id))
                .padding(.leading, origin.x)
                .padding(.top, origin.y)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// Scrolls just enough to show the keyboard selection.
    private func scrollToSelection(_ proxy: ScrollViewProxy) {
        guard content.scrolls, let id = keyboard.selectedID else { return }
        withAnimation(.easeOut(duration: 0.12)) {
            proxy.scrollTo(Self.scrollAnchorID(id))
        }
    }

    /// Where each cell is shown: its slot in the grid, or `nil` while it's hidden (dropped outside
    /// the popup, until the store removes it).
    private func slotIndices() -> [PopupCell.ID: Int] {
        if let freeLayout = content.freeLayout {
            return freeSlotIndices(freeLayout)
        }
        let ids = content.cells.map(\.id)
        let order: [PopupCell.ID]
        if let drag {
            // Over the removal area the other apps close ranks, as they will once it's gone.
            order = PopupDrag.previewOrder(ids, moving: drag.id, to: drag.isInRemovalArea ? nil : drag.targetIndex)
        } else if let droppedOrder {
            order = droppedOrder.filter(ids.contains)
        } else {
            order = ids
        }
        return Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// `slotIndices()` in Free Layout: the cells with the dragged app dropped where it is now
    /// (the app it's over swaps to its cell), the others staying where they are.
    private func freeSlotIndices(_ freeLayout: FreeLayout) -> [PopupCell.ID: Int] {
        let shown: FreeLayout
        if let drag, let cell = content.cells.first(where: { $0.id == drag.id }) {
            shown = drag.isInRemovalArea ? freeLayout.removing(cell.app) : freeLayout.moving(cell.app, to: drag.targetIndex)
        } else {
            shown = droppedLayout ?? freeLayout
        }
        return Dictionary(
            content.cells.compactMap { cell in shown.slot(of: cell.app).map { (cell.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// The cells taken by apps other than the dragged one.
    private func occupiedCells(_ slots: [PopupCell.ID: Int]) -> Set<Int> {
        Set(slots.filter { $0.key != drag?.id }.values)
    }

    /// Faint outlines of the free cells while an app is dragged in Free Layout: where it can go.
    private func emptyCellOutlines(occupied: Set<Int>, palette: PanelPalette) -> some View {
        let metrics = content.metrics
        let cellCount = content.freeLayout?.slotCount ?? 0
        let free = (0..<cellCount).filter { !occupied.contains($0) }
        return ForEach(free, id: \.self) { slot in
            let origin = content.layout.cellOrigin(at: slot, metrics: metrics)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    slot == drag?.targetIndex ? PanelPalette.teal.opacity(0.7) : palette.secondaryText.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
                .frame(width: metrics.cellWidth, height: metrics.cellHeight)
                .offset(x: origin.x, y: origin.y)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// Where the app is before it's dragged: its index in the list, or in Free Layout its cell.
    private func sourceSlot(of cell: PopupCell) -> Int? {
        if let freeLayout = content.freeLayout {
            return freeLayout.slot(of: cell.app)
        }
        return content.cells.firstIndex(where: { $0.id == cell.id })
    }

    private func cellView(_ cell: PopupCell, slot: Int?, palette: PanelPalette) -> some View {
        let metrics = content.metrics
        let dragged = drag.flatMap { $0.id == cell.id ? $0 : nil }
        let origin = dragged?.origin ?? content.layout.cellOrigin(at: slot ?? 0, metrics: metrics)
        let isHidden = slot == nil && dragged == nil
        return PopupAppCell(
            cell: cell,
            isRunning: runningApps.isRunning(cell.app),
            isEditable: content.isEditable,
            isFreeLayout: content.freeLayout != nil,
            showsTitle: content.showsTitles,
            metrics: metrics,
            palette: palette,
            isDragged: dragged != nil,
            isInRemovalArea: dragged?.isInRemovalArea ?? false,
            highlightsOnHover: drag == nil,
            isSelected: drag == nil && keyboard.selectedID == cell.id
        ) {
            guard !suppressesClick else { return }
            actions.open(cell.app)
        }
        .offset(x: origin.x, y: origin.y)
        .opacity(isHidden ? 0 : 1)
        .allowsHitTesting(!isHidden)
        .zIndex(dragged != nil ? 1 : 0)
        // The others glide to their new slots; the dragged cell stays under the pointer.
        .animation(dragged != nil ? nil : .easeInOut(duration: 0.18), value: slot)
        .simultaneousGesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.gridSpace))
                .onChanged { value in dragChanged(cell, value) }
                .onEnded { _ in dragEnded(cell) },
            including: content.isEditable ? .all : .subviews
        )
        .modifier(EditingAccessibilityActions(isEnabled: content.isEditable) {
            move(cell, by: -1)
        } moveLater: {
            move(cell, by: 1)
        } remove: {
            actions.removeApp(cell.app)
        })
        .modifier(cellContextMenu(cell))
    }

    // MARK: - Dragging

    private func dragChanged(_ cell: PopupCell, _ value: DragGesture.Value) {
        let metrics = content.metrics
        let layout = content.layout
        var current: CellDrag
        if let drag, drag.id == cell.id {
            current = drag
        } else {
            guard let source = sourceSlot(of: cell) else { return }
            let start = layout.cellOrigin(at: slotIndices()[cell.id] ?? source, metrics: metrics)
            current = CellDrag(
                id: cell.id,
                grabOffset: CGSize(width: value.startLocation.x - start.x, height: value.startLocation.y - start.y),
                origin: start,
                targetIndex: source,
                isInRemovalArea: false
            )
            droppedOrder = nil
            droppedLayout = nil
            suppressesClick = true
        }
        current.origin = CGPoint(x: value.location.x - current.grabOffset.width, y: value.location.y - current.grabOffset.height)
        let center = CGPoint(x: current.origin.x + metrics.cellWidth / 2, y: current.origin.y + metrics.cellHeight / 2)
        let target = content.freeLayout != nil
            ? layout.freeSlotIndex(at: center, metrics: metrics)
            : layout.slotIndex(at: center, metrics: metrics)
        current.targetIndex = target ?? current.targetIndex
        let isInRemovalArea = actions.isPointerInRemovalArea()
        if isInRemovalArea != current.isInRemovalArea {
            // The dragged cell can't be drawn outside the panel; the cursor shows the removal.
            (isInRemovalArea ? NSCursor.disappearingItem : NSCursor.arrow).set()
        }
        current.isInRemovalArea = isInRemovalArea
        drag = current
    }

    private func dragEnded(_ cell: PopupCell) {
        defer {
            NSCursor.arrow.set()
            // The click ending the drag may still reach the cell's button; let it pass first.
            DispatchQueue.main.async { suppressesClick = false }
        }
        guard let current = drag, current.id == cell.id else { return }
        let ids = content.cells.map(\.id)
        guard let source = sourceSlot(of: cell) else {
            drag = nil
            return
        }
        let drop = PopupDrop(sourceIndex: source, targetIndex: current.targetIndex, isInRemovalArea: actions.isPointerInRemovalArea())
        if let freeLayout = content.freeLayout {
            freeDragEnded(cell, drop: drop, freeLayout: freeLayout)
            return
        }
        switch drop {
        case .none:
            withAnimation(.easeOut(duration: 0.18)) { drag = nil }
        case .move(let index):
            withAnimation(.easeOut(duration: 0.18)) {
                droppedOrder = PopupDrag.previewOrder(ids, moving: cell.id, to: index)
                drag = nil
            }
            actions.moveApp(cell.app, index)
        case .remove:
            droppedOrder = PopupDrag.previewOrder(ids, moving: cell.id, to: nil)
            drag = nil
            actions.removeApp(cell.app)
        }
    }

    private func freeDragEnded(_ cell: PopupCell, drop: PopupDrop, freeLayout: FreeLayout) {
        switch drop {
        case .none:
            withAnimation(.easeOut(duration: 0.18)) { drag = nil }
        case .move(let slot):
            let arranged = freeLayout.moving(cell.app, to: slot)
            withAnimation(.easeOut(duration: 0.18)) {
                droppedLayout = arranged
                drag = nil
            }
            actions.arrangeApps(arranged.slots)
        case .remove:
            droppedLayout = freeLayout.removing(cell.app)
            drag = nil
            actions.removeApp(cell.app)
        }
    }

    /// Moves an app one place, for VoiceOver's actions; in Free Layout one cell, swapping with the
    /// app there.
    private func move(_ cell: PopupCell, by offset: Int) {
        if let freeLayout = content.freeLayout {
            guard let slot = freeLayout.slot(of: cell.app), (0..<freeLayout.slotCount).contains(slot + offset) else { return }
            actions.arrangeApps(freeLayout.moving(cell.app, to: slot + offset).slots)
            return
        }
        guard let index = content.cells.firstIndex(where: { $0.id == cell.id }) else { return }
        let target = index + offset
        guard content.cells.indices.contains(target) else { return }
        actions.moveApp(cell.app, target)
    }

    @ViewBuilder
    private func emptyState(_ palette: PanelPalette) -> some View {
        if !content.isMostUsed {
            VStack(spacing: 6) {
                Text("No apps in this group yet")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
                HStack(spacing: 8) {
                    Button("Add Apps…", action: actions.manageGroups)
                        .buttonStyle(PillButtonStyle(tint: PanelPalette.teal, filled: false))
                    if content.isEditable, let addWebsite = actions.addWebsite {
                        Button("Add Website…", action: addWebsite)
                            .buttonStyle(PillButtonStyle(tint: PanelPalette.teal, filled: false))
                    }
                }
            }
        } else {
            VStack(spacing: 4) {
                Text("No launches tracked yet")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
                Text("Open apps as usual to start building your history.")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.secondaryText)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
        }
    }

    // MARK: - Footer

    private func footer(_ palette: PanelPalette) -> some View {
        HStack(spacing: 8) {
            Text(footerText)
                .font(.system(size: 10.5))
                .foregroundStyle(drag?.isInRemovalArea == true ? PanelPalette.warning : palette.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            // Per-group "Sort A→Z": a one-off sort of this group's apps by name, saved like a drag.
            if content.isEditable, content.cells.count > 1, drag == nil, !keyboard.isFiltering {
                Button(action: actions.sortApps) {
                    Label("A→Z", systemImage: "arrow.up.arrow.down")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .buttonStyle(FooterButtonStyle(tint: PanelPalette.teal))
                .fixedSize()
                .help("Sort the apps in this group by name, A to Z.")
                .accessibilityLabel("Sort A to Z")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: PopupMetrics.footerHeight)
    }

    private var footerText: String {
        if keyboard.isFiltering, drag == nil {
            let hasMatches = !content.navigationItems(query: keyboard.query).cells.isEmpty
            return hasMatches
                ? "Filter: “\(keyboard.query)”  ·  ↩ opens the selected app  ·  esc clears"
                : "Filter: “\(keyboard.query)”  ·  no match  ·  ⌫ or esc clears"
        }
        guard let drag, let cell = content.cells.first(where: { $0.id == drag.id }) else {
            return content.isMostUsed
                ? "Ranked by how often you open them  ·  ⌘-click Close All to force quit"
                : "Close All:  ⌥-click quits normally  ·  ⌘-click force quits"
        }
        if drag.isInRemovalArea {
            return "Release to remove \(cell.app.name) from this group"
        }
        return content.freeLayout != nil
            ? "Drop \(cell.app.name) on any cell; on another app to swap  ·  drag out to remove"
            : "Drop to place \(cell.app.name)  ·  drag out of the popup to remove it"
    }
}

/// An app in the grid: its icon with a running indicator and, optionally, its name.
private struct PopupAppCell: View {
    let cell: PopupCell
    let isRunning: Bool
    let isEditable: Bool
    let isFreeLayout: Bool
    let showsTitle: Bool
    let metrics: PopupGridMetrics
    let palette: PanelPalette
    let isDragged: Bool
    let isInRemovalArea: Bool
    /// Off while another cell is dragged over this one.
    let highlightsOnHover: Bool
    /// Selected with the keyboard: Return opens it.
    let isSelected: Bool
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
                    .fill(isDragged ? palette.pressed : ((isHovered && highlightsOnHover) || isSelected ? palette.hover : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? PanelPalette.teal.opacity(0.85) : Color.clear, lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(CellButtonStyle(pressedFill: palette.pressed))
        .scaleEffect(isDragged ? 1.1 : 1)
        .opacity(isInRemovalArea ? 0.4 : 1)
        .shadow(color: .black.opacity(isDragged ? 0.3 : 0), radius: 10, y: 4)
        .onHover { isHovered = $0 }
        .help(helpText)
        .accessibilityLabel(cell.app.isWebsite ? "Website \(cell.app.name)" : cell.app.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(cell.app.isWebsite ? "Opens the website in your browser" : (isRunning ? "Brings the app to the front" : "Opens the app"))
    }

    private var helpText: String {
        if cell.app.isWebsite {
            let action = "Open \(cell.app.websiteURL?.absoluteString ?? cell.app.name) in your browser"
            guard isEditable else { return "\(action)." }
            return isFreeLayout
                ? "\(action). Drag to any cell or onto another item to swap them, or out of the popup to remove it from the group."
                : "\(action). Drag to reorder, or out of the popup to remove it from the group."
        }
        guard cell.isInstalled else {
            return isEditable
                ? "\(cell.app.name) isn't on this Mac. Drag it out of the popup to remove it from the group."
                : "\(cell.app.name) isn't on this Mac."
        }
        let action = isRunning ? "Bring \(cell.app.name) to the front" : "Open \(cell.app.name)"
        guard isEditable else { return "\(action)." }
        return isFreeLayout
            ? "\(action). Drag to any cell or onto another app to swap them, or out of the popup to remove it from the group."
            : "\(action). Drag to reorder, or out of the popup to remove it from the group."
    }
}

/// The context menu of an item in the popup grid: Open; Copy URL for a website or Show in Finder
/// for an app; and in editable groups Move to (the other groups), Remove from Group and Add
/// Website….
private struct PopupCellContextMenu: ViewModifier {
    let cell: PopupCell
    let moveTargets: [GroupMoveTarget]
    let isEditable: Bool
    let actions: PopupActions

    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Open") { actions.open(cell.app) }
            if let url = cell.app.websiteURL {
                Button("Copy URL") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(url.absoluteString, forType: .string)
                    pasteboard.setString(url.absoluteString, forType: .URL)
                }
            } else if cell.isInstalled {
                Button("Show in Finder") { actions.showInFinder(cell.app) }
            }
            if isEditable {
                Divider()
                if !moveTargets.isEmpty {
                    Menu("Move to") {
                        ForEach(moveTargets) { target in
                            Button(target.title) { actions.moveAppToGroup(cell.app, target.id) }
                        }
                    }
                }
                Button("Remove from Group") { actions.removeApp(cell.app) }
                if let addWebsite = actions.addWebsite {
                    Divider()
                    Button("Add Website…", action: addWebsite)
                }
            }
        }
    }
}

/// VoiceOver's reorder and remove actions, for cells of editable groups only.
private struct EditingAccessibilityActions: ViewModifier {
    let isEnabled: Bool
    let moveEarlier: () -> Void
    let moveLater: () -> Void
    let remove: () -> Void

    init(isEnabled: Bool, moveEarlier: @escaping () -> Void, moveLater: @escaping () -> Void, remove: @escaping () -> Void) {
        self.isEnabled = isEnabled
        self.moveEarlier = moveEarlier
        self.moveLater = moveLater
        self.remove = remove
    }

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .accessibilityAction(named: "Move Earlier", moveEarlier)
                .accessibilityAction(named: "Move Later", moveLater)
                .accessibilityAction(named: "Remove from Group", remove)
        } else {
            content
        }
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

/// The small text button of the popup footer: accent-colored, with a faint capsule while pressed.
private struct FooterButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(configuration.isPressed ? 0.22 : 0.1))
            )
            .contentShape(Capsule(style: .continuous))
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
