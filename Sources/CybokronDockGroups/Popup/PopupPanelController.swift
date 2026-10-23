import AppKit
import Combine
import DockGroupsCore
import OSLog
import QuartzCore
import SwiftUI

/// Shows a group's popup: positions the panel over the Dock — or, with the group's position set to
/// "above the clicked icon", at the icon it was opened from (`PopupSource`) — keeps it in sync with
/// the group and the popup preferences while it's open, and closes it on Escape, an outside click
/// or focus loss.
///
/// While it's open the keyboard works the popup: the arrow keys select an item, Return opens it,
/// typing filters the items by name and alias, then by tags and task notes (`PopupSearch`; Return
/// then opens the selected, by default the best, match),
/// Delete and Escape clear the filter, Tab and ⇧Tab go to the next and previous group, and Escape
/// without a filter closes the popup. Space without a filter shows the selected app, file or
/// folder in Quick Look (`PopupQuickLook`), as Quick Look in its context menu does; Escape then
/// closes Quick Look first, and closing the popup closes it too.
///
/// Where each item is (`ItemPresence`) is checked once per build of the popup's content — when it
/// opens and when its group, the preferences or the Most Used list change — and again for the one
/// item Show in Finder or Quick Look is asked for.
///
/// The Most Used list (`MostUsedGroup.id`) opens like a group, read-only: its apps can be opened
/// but not reordered or removed. A standalone agent shows its group read-only too
/// (`allowsEditing: false`): the group belongs to the main app.
@MainActor
final class PopupPanelController: NSObject, NSWindowDelegate {
    struct Actions {
        let open: (AppReference, DockGroup) -> Void
        let openAll: (DockGroup) -> Void
        let closeAll: (DockGroup, QuitMode) -> Void
        let hideAll: (DockGroup) -> Void
        let manageGroups: () -> Void
        /// Opens the group window on the group's settings (the popup's gear and the group's
        /// "Group Settings…" menu item); never asked for the Most Used list.
        let showGroupSettings: (DockGroup) -> Void
        /// Asks for a website to add to the group; `nil` where groups can't be edited.
        var addWebsite: ((DockGroup) -> Void)?
        /// Does in the group window what the popup can't: an item's Edit Details…, the open panels of
        /// Add Apps… and Add Files or Folders…; `nil` where groups can't be edited.
        var inGroupWindow: ((GroupWindowRequest.Action, DockGroup) -> Void)?
    }

    /// Why the popup closed; logged at debug level to diagnose unexpected closes.
    enum CloseReason: String {
        case requested, toggled, escape, outsideClick, appWindowClick, lostFocus, groupDeleted, appAction
    }

    /// Virtual key codes of the keys the popup handles.
    private enum KeyCode {
        static let escape: UInt16 = 53
        static let returnKey: UInt16 = 36
        static let keypadEnter: UInt16 = 76
        static let tab: UInt16 = 48
        static let space: UInt16 = 49
        static let delete: UInt16 = 51
        static let left: UInt16 = 123
        static let right: UInt16 = 124
        static let down: UInt16 = 125
        static let up: UInt16 = 126
    }

    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "Popup")

    private let store: GroupStore
    private let preferences: PreferencesStore
    private let tiles: TileImageCache
    private let icons: AppIconProviding
    private let runningApps: RunningAppsMonitor
    private let mostUsed: MostUsedProvider?
    private let allowsEditing: Bool
    private let actions: Actions
    private let modifierKeys = ModifierKeyState()
    private let keyboard = PopupKeyboardState()
    /// Quick Look for the selected app.
    private lazy var preview = PopupPreviewController(host: panel)
    /// What the open popup shows, for the keyboard.
    private var content: PopupContent?

    private let panel = PopupPanel()
    private var hostingView: FirstMouseHostingView<PopupContentView>?
    private var containerView: PopupContainerView?
    private var eventMonitors: [Any] = []
    private var subscriptions: Set<AnyCancellable> = []
    /// Bumped by every show and close, so a finished fade-out doesn't hide a popup shown since.
    private var transition = 0
    /// What the open popup was opened from; it stays in place while its content changes.
    private var source: PopupSource = .unspecified

    /// The group whose popup is open, `nil` while closed.
    private(set) var groupID: DockGroup.ID?
    /// The group whose popup was shown last, even if it's closed now.
    private(set) var lastGroupID: DockGroup.ID?
    /// Why and when the popup closed last.
    private(set) var lastClose: (reason: CloseReason, date: Date)?
    /// Called whenever the popup closes.
    var onClose: ((CloseReason) -> Void)?

    var isShown: Bool { groupID != nil }

    init(
        store: GroupStore,
        preferences: PreferencesStore,
        tiles: TileImageCache,
        icons: AppIconProviding,
        runningApps: RunningAppsMonitor,
        mostUsed: MostUsedProvider?,
        allowsEditing: Bool = true,
        actions: Actions
    ) {
        self.store = store
        self.preferences = preferences
        self.tiles = tiles
        self.icons = icons
        self.runningApps = runningApps
        self.mostUsed = mostUsed
        self.allowsEditing = allowsEditing
        self.actions = actions
        super.init()

        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close(reason: .escape) }
        panel.preview = preview
        // @Published fires before the value changes; the main-queue hop reads the new value.
        store.$groups.map { _ in () }
            .merge(with: preferences.$preferences.map { _ in () }, mostUsed?.changes ?? Empty().eraseToAnyPublisher())
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &subscriptions)
        // The preview follows the keyboard selection.
        keyboard.$selectedID
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncPreview() }
            .store(in: &subscriptions)
    }

    // MARK: - Showing and closing

    func toggle(groupID id: DockGroup.ID, source: PopupSource = .unspecified) {
        if groupID == id {
            close(reason: .toggled)
        } else {
            show(groupID: id, source: source)
        }
    }

    /// The group with this ID, or the Most Used list while it's turned on.
    func group(withID id: DockGroup.ID) -> DockGroup? {
        id == MostUsedGroup.id ? mostUsed?.group() : store.group(withID: id)
    }

    /// Shows the group's popup. `source` is the icon it was opened from, if any: the group's
    /// "above the clicked icon" position opens it there, and without one over the Dock's center.
    func show(groupID id: DockGroup.ID, source: PopupSource = .unspecified) {
        guard let group = group(withID: id) else { return }
        self.source = source
        guard let frame = update(for: group) else { return }
        let wasShown = groupID != nil && panel.isVisible
        if !wasShown || groupID != id {
            keyboard.reset()
        }
        groupID = id
        lastGroupID = id
        transition += 1

        panel.setFrame(frame, display: true)
        if !wasShown {
            panel.alphaValue = 0
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.invalidateShadow()
        modifierKeys.update(NSEvent.modifierFlags)
        installEventMonitors()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func close(reason: CloseReason = .requested) {
        guard groupID != nil else { return }
        logger.debug("Closing popup: \(reason.rawValue, privacy: .public)")
        groupID = nil
        lastClose = (reason, Date())
        preview.close()
        removeEventMonitors()
        transition += 1
        let closingTransition = transition
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.transition == closingTransition else { return }
                self.panel.orderOut(nil)
            }
        })
        onClose?(reason)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard preview.isShown else {
            close(reason: .lostFocus)
            return
        }
        if preview.isSettling {
            // Quick Look coming up took the keyboard for an instant: take it back.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isShown, self.preview.isShown, !self.preview.isKey else { return }
                self.panel.makeKey()
            }
            return
        }
        // A click into the Quick Look panel makes it key; the popup stays open for it.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isShown, !self.panel.isKeyWindow, !self.preview.isKey else { return }
            self.close(reason: .lostFocus)
        }
    }

    // MARK: - Content

    /// Re-renders the open popup after its group or the preferences changed.
    private func refresh() {
        guard let id = groupID else { return }
        guard let group = group(withID: id) else {
            close(reason: .groupDeleted)
            return
        }
        if let frame = update(for: group) {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
        syncPreview()
    }

    /// Puts `group`'s content into the panel and returns the panel's frame.
    private func update(for group: DockGroup) -> CGRect? {
        let popupPreferences = preferences.preferences
        let settings = popupPreferences.resolved(with: group.popup)
        guard let dock = DockScreenReader.current(anchor: settings.anchor, source: source) else { return nil }
        let metrics = PopupMetrics.grid(showsTitles: settings.showsTitles)
        let layout = PopupGridLayout(itemCount: group.apps.count, columns: settings.columns, maxRows: settings.maxRows)
        // Free Layout arranges the user's groups; the Most Used list stays ranked.
        let freeLayout = popupPreferences.usesFreeLayout && group.id != MostUsedGroup.id
            ? FreeLayout(apps: group.apps, savedSlots: group.freeLayoutSlots, slotCount: layout.slotCount)
            : nil
        let isEditable = allowsEditing && group.id != MostUsedGroup.id

        // Keep the popup on screen: a grid taller than the screen allows scrolls instead.
        let maximum = PopupPlacement.maximumSize(on: dock.screen)
        let gridSize = layout.visibleSize(metrics: metrics)
        let minimumGridHeight = metrics.cellHeight + 2 * metrics.padding
        let gridHeight = min(gridSize.height, max(maximum.height - PopupMetrics.chromeHeight, minimumGridHeight))
        let size = CGSize(
            width: min(max(gridSize.width, PopupMetrics.minimumWidth), maximum.width),
            height: PopupMetrics.chromeHeight + gridHeight
        )

        let content = PopupContent(
            group: group,
            tileImage: tiles.image(for: group, pointSize: PopupMetrics.headerTileSize),
            cells: group.apps.map { item in
                let presence = icons.presence(of: item)
                return PopupCell(app: item, icon: icons.icon(for: item, presence: presence), presence: presence)
            },
            // Built once per build, with the cells: typing only searches it.
            search: PopupSearch(items: group.apps),
            layout: layout,
            freeLayout: freeLayout,
            metrics: metrics,
            showsTitles: settings.showsTitles,
            size: size,
            gridHeight: gridHeight,
            scrolls: layout.contentHeight(metrics: metrics) > gridHeight + 0.5,
            usesFrostedGlass: popupPreferences.usesFrostedGlass,
            isEditable: isEditable,
            moveTargets: isEditable ? GroupMoveTarget.targets(in: store.groups, excluding: group.id) : [],
            isMostUsed: group.id == MostUsedGroup.id
        )

        self.content = content
        panel.appearance = popupPreferences.theme.appearance
        let rootView = PopupContentView(
            content: content,
            runningApps: runningApps,
            modifierKeys: modifierKeys,
            keyboard: keyboard,
            actions: popupActions(for: group.id)
        )
        if let hostingView {
            hostingView.rootView = rootView
        } else {
            let hostingView = FirstMouseHostingView(rootView: rootView)
            hostingView.sizingOptions = []
            let containerView = PopupContainerView(content: hostingView)
            panel.contentView = containerView
            self.hostingView = hostingView
            self.containerView = containerView
        }
        let isDark = panel.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        containerView?.apply(
            usesFrostedGlass: popupPreferences.usesFrostedGlass,
            border: (isDark ? PanelPalette.dark : PanelPalette.light).border
        )

        return PopupPlacement.frame(size: size, anchor: settings.anchor, dockEdge: dock.edge, screen: dock.screen, source: source)
    }

    /// Actions look the group up when they run, so they always act on its current state.
    private func popupActions(for id: DockGroup.ID) -> PopupActions {
        PopupActions(
            open: { [weak self] app in
                guard let self, let group = self.group(withID: id) else { return }
                self.close(reason: .appAction)
                self.actions.open(app, group)
            },
            openAll: { [weak self] in
                guard let self, let group = self.group(withID: id) else { return }
                self.close(reason: .appAction)
                self.actions.openAll(group)
            },
            closeAll: { [weak self] mode in
                guard let self, let group = self.group(withID: id) else { return }
                self.close(reason: .appAction)
                self.actions.closeAll(group, mode)
            },
            hideAll: { [weak self] in
                guard let self, let group = self.group(withID: id) else { return }
                self.close(reason: .appAction)
                self.actions.hideAll(group)
            },
            manageGroups: { [weak self] in
                self?.close(reason: .appAction)
                self?.actions.manageGroups()
            },
            // The Most Used list has no group settings: it's set up in Settings → Most Used.
            showGroupSettings: id == MostUsedGroup.id
                ? nil
                : { [weak self] in
                    guard let self, let group = self.group(withID: id) else { return }
                    self.close(reason: .appAction)
                    self.actions.showGroupSettings(group)
                },
            addWebsite: allowsEditing && id != MostUsedGroup.id && actions.addWebsite != nil
                ? { [weak self] in
                    guard let self, let group = self.group(withID: id) else { return }
                    self.close(reason: .appAction)
                    self.actions.addWebsite?(group)
                }
                : nil,
            showInFinder: { [weak self] app in
                guard let self, let location = PopupQuickLook.target(for: app, presence: self.icons.presence(of: app)) else { return }
                self.close(reason: .appAction)
                NSWorkspace.shared.activateFileViewerSelecting([location])
            },
            quickLook: { [weak self] app in
                self?.showPreview(of: app)
            },
            // Locate… needs an open panel, which the popup can't host: the group window has it.
            locate: allowsEditing && id != MostUsedGroup.id
                ? { [weak self] _ in
                    guard let self, let group = self.group(withID: id) else { return }
                    self.close(reason: .appAction)
                    self.actions.showGroupSettings(group)
                }
                : nil,
            // The details editor and the open panels are in the group window: the popup can't host them.
            editDetails: inGroupWindow(id).map { perform -> (AppReference) -> Void in
                { app in perform(.editDetails(itemID: app.bundleIdentifier)) }
            },
            addApps: inGroupWindow(id).map { perform -> () -> Void in { perform(.addApps) } },
            addFilesAndFolders: inGroupWindow(id).map { perform -> () -> Void in { perform(.addFilesAndFolders) } },
            moveApp: { [weak self] app, index in
                guard let self, self.allowsEditing, id != MostUsedGroup.id else { return }
                self.logger.notice("Moving \(app.logIdentity, privacy: .public) to \(index) in group \(id, privacy: .public)")
                self.store.moveApp(bundleIdentifier: app.bundleIdentifier, inGroup: id, to: index)
            },
            arrangeApps: { [weak self] slots in
                guard let self, self.allowsEditing, id != MostUsedGroup.id else { return }
                self.logger.notice("Arranging the apps of group \(id, privacy: .public) in Free Layout")
                self.store.arrangeApps(inGroup: id, freeLayoutSlots: slots)
            },
            removeApp: { [weak self] app in
                guard let self, self.allowsEditing, id != MostUsedGroup.id else { return }
                self.logger.notice("Removing \(app.logIdentity, privacy: .public) from group \(id, privacy: .public)")
                self.store.removeApp(bundleIdentifier: app.bundleIdentifier, fromGroup: id)
            },
            moveAppToGroup: { [weak self] app, destination in
                guard let self, self.allowsEditing, id != MostUsedGroup.id else { return }
                self.logger.notice("Moving \(app.logIdentity, privacy: .public) from group \(id, privacy: .public) to group \(destination, privacy: .public)")
                self.store.moveApp(bundleIdentifier: app.bundleIdentifier, fromGroup: id, toGroup: destination)
            },
            sortApps: { [weak self] in
                guard let self, self.allowsEditing, id != MostUsedGroup.id else { return }
                self.logger.notice("Sorting the apps of group \(id, privacy: .public) by name")
                self.store.sortAppsByName(inGroup: id)
            },
            isPointerInRemovalArea: { [weak self] in
                guard let self else { return false }
                return PopupDrag.isRemovalLocation(NSEvent.mouseLocation, panelFrame: self.panel.frame)
            }
        )
    }

    /// Closes the popup and does `action` in the group window on the group; `nil` where groups can't
    /// be edited (the Most Used list, a standalone group's own app).
    private func inGroupWindow(_ id: DockGroup.ID) -> ((GroupWindowRequest.Action) -> Void)? {
        guard allowsEditing, id != MostUsedGroup.id, actions.inGroupWindow != nil else { return nil }
        return { [weak self] action in
            guard let self, let group = self.group(withID: id) else { return }
            self.close(reason: .appAction)
            self.actions.inGroupWindow?(action, group)
        }
    }

    // MARK: - Event monitoring

    private func installEventMonitors() {
        guard eventMonitors.isEmpty else { return }
        // Monitors run on the main thread; only Sendable values cross into the isolated blocks.
        let local: [(NSEvent.EventTypeMask, (NSEvent) -> NSEvent?)] = [
            (.keyDown, { [weak self] event in
                let key = PopupKeyPress(
                    keyCode: event.keyCode,
                    characters: event.characters ?? "",
                    modifierFlags: event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                )
                let handled = MainActor.assumeIsolated { () -> Bool in
                    self?.handle(key) ?? false
                }
                return handled ? nil : event
            }),
            (.flagsChanged, { [weak self] event in
                let flags = event.modifierFlags
                MainActor.assumeIsolated { self?.modifierKeys.update(flags) }
                return event
            }),
            ([.leftMouseDown, .rightMouseDown, .otherMouseDown], { [weak self] event in
                // Clicks in the app's other windows (the menu bar item, the group window).
                let windowNumber = event.windowNumber
                MainActor.assumeIsolated {
                    guard let self, windowNumber != self.panel.windowNumber, windowNumber != self.preview.windowNumber else { return }
                    self.close(reason: .appWindowClick)
                }
                return event
            }),
        ]
        for (mask, handler) in local {
            if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler) {
                eventMonitors.append(monitor)
            }
        }
        // Clicks in other apps, including the Desktop and the Dock.
        if let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
            handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.close(reason: .outsideClick) }
            }
        ) {
            eventMonitors.append(monitor)
        }
    }

    // MARK: - Keyboard

    /// Handles a key pressed while the popup is open; returns whether it was used.
    private func handle(_ key: PopupKeyPress) -> Bool {
        guard groupID != nil else { return false }
        if key.keyCode == KeyCode.escape {
            switch PopupQuickLook.escapeAction(query: keyboard.query, isPreviewShown: preview.isShown) {
            case .closePreview: preview.close()
            case .clearFilter: setQuery("")
            case .closePopup: close(reason: .escape)
            }
            return true
        }
        // Everything else only while the popup (or its Quick Look preview) has the keyboard; ⌘ and ⌃
        // shortcuts (⌘Q, ⌘,) pass.
        guard panel.isKeyWindow || preview.isKey, key.modifierFlags.isDisjoint(with: [.command, .control]) else { return false }
        switch key.keyCode {
        case KeyCode.left: return moveSelection(.left)
        case KeyCode.right: return moveSelection(.right)
        case KeyCode.up: return moveSelection(.up)
        case KeyCode.down: return moveSelection(.down)
        case KeyCode.returnKey, KeyCode.keypadEnter:
            openSelection()
            return true
        case KeyCode.tab:
            showNextGroup(backward: key.modifierFlags.contains(.shift))
            return true
        case KeyCode.delete:
            if !keyboard.query.isEmpty {
                setQuery(String(keyboard.query.dropLast()))
            }
            return true
        case KeyCode.space where !key.modifierFlags.contains(.option):
            return handleSpace()
        default:
            break
        }
        guard !key.modifierFlags.contains(.option), key.characters.count == 1, let character = key.characters.first,
              PopupFilter.acceptsCharacter(character, currentQuery: keyboard.query)
        else { return false }
        setQuery(keyboard.query + String(character))
        return true
    }

    /// Space: a space in the filter while typing, else Quick Look for the selected item.
    private func handleSpace() -> Bool {
        let cell = selectedCell()
        let location = cell.flatMap { PopupQuickLook.target(for: $0.app, presence: icons.presence(of: $0.app)) }
        let selection: PopupQuickLook.Selection = cell == nil ? .none : (location == nil ? .notPreviewable : .previewable)
        switch PopupQuickLook.spaceAction(query: keyboard.query, isPreviewShown: preview.isShown, selection: selection) {
        case .typeSpace:
            setQuery(keyboard.query + " ")
        case .showPreview:
            if let location { preview.show(location) }
        case .closePreview:
            preview.close()
        case .ignore:
            break
        case .pass:
            return false
        }
        return true
    }

    /// The cell the keyboard selected, if it's shown.
    private func selectedCell() -> PopupCell? {
        guard let content, let id = keyboard.selectedID else { return nil }
        return content.navigationItems(query: keyboard.query).cells.first { $0.id == id }
    }

    /// Keeps an open preview on the selected item; closes it once the selection is gone or has
    /// nothing to preview.
    private func syncPreview() {
        guard preview.isShown else { return }
        if let cell = selectedCell(), let location = PopupQuickLook.target(for: cell.app, presence: icons.presence(of: cell.app)) {
            preview.show(location)
        } else {
            preview.close()
        }
    }

    /// Quick Look from an item's context menu: selects the item first — the preview follows the
    /// selection and would close without one — then shows it.
    private func showPreview(of app: AppReference) {
        guard let content, groupID != nil,
              let cell = content.navigationItems(query: keyboard.query).cells.first(where: { $0.id == app.id }),
              let location = PopupQuickLook.target(for: cell.app, presence: icons.presence(of: cell.app))
        else { return }
        keyboard.selectedID = cell.id
        preview.show(location)
    }

    /// Changes the filter and selects its best match (nothing once the filter is cleared).
    private func setQuery(_ query: String) {
        keyboard.query = query
        keyboard.selectedID = keyboard.isFiltering ? content?.navigationItems(query: query).cells.first?.id : nil
    }

    private func moveSelection(_ direction: PopupKeyboardNavigation.Direction) -> Bool {
        guard let content else { return false }
        let items = content.navigationItems(query: keyboard.query)
        let current = keyboard.selectedID.flatMap { id in items.cells.firstIndex { $0.id == id } }
        if let target = PopupKeyboardNavigation.target(from: current, direction: direction, slots: items.slots, columns: content.layout.columns) {
            keyboard.selectedID = items.cells[target].id
        }
        return true
    }

    /// Opens the selected app the way clicking it does; with a filter and nothing selected, the best
    /// match.
    private func openSelection() {
        guard let content, let id = groupID else { return }
        let items = content.navigationItems(query: keyboard.query)
        let selected = keyboard.selectedID.flatMap { selectedID in items.cells.first { $0.id == selectedID } }
        guard let cell = selected ?? (keyboard.isFiltering ? items.cells.first : nil) else { return }
        popupActions(for: id).open(cell.app)
    }

    /// Tab: the next group's popup, in the menu bar menu's order (the groups, then Most Used).
    private func showNextGroup(backward: Bool) {
        guard let id = groupID else { return }
        var order = store.groups.map(\.id)
        if mostUsed?.group() != nil {
            order.append(MostUsedGroup.id)
        }
        guard let next = PopupKeyboardNavigation.nextGroup(after: id, in: order, backward: backward) else { return }
        show(groupID: next, source: source)
    }

    private func removeEventMonitors() {
        for monitor in eventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        eventMonitors.removeAll()
    }
}

/// Reads where the Dock is: its edge, and the screen a popup opens on.
@MainActor
enum DockScreenReader {
    /// The Dock's edge and the popup's screen: the one with the clicked icon for `.dockIcon`
    /// (`PopupPlacement.screenIndex`), else the Dock's.
    static func current(anchor: PopupAnchor, source: PopupSource) -> (edge: DockEdge, screen: ScreenGeometry)? {
        let screens = self.screens()
        guard let edge = edge(on: screens) else { return nil }
        let index = PopupPlacement.screenIndex(
            anchor: anchor,
            source: source,
            edge: edge,
            screens: screens,
            mouseLocation: NSEvent.mouseLocation
        ) ?? 0
        return (edge, screens[index])
    }

    /// Every screen, the primary one (with the menu bar) first.
    static func screens() -> [ScreenGeometry] {
        NSScreen.screens.map { ScreenGeometry(frame: $0.frame, visibleFrame: $0.visibleFrame) }
    }

    /// The Dock's edge; `nil` without screens.
    static func edge(on screens: [ScreenGeometry]) -> DockEdge? {
        guard let primary = screens.first else { return nil }
        // The Dock stores its edge as "bottom", "left" or "right"; the key is absent until the user
        // moves the Dock away from the bottom.
        let orientation = UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") ?? "bottom"
        return DockEdge(orientation: orientation, screen: primary)
    }
}

/// The parts of a key press the popup needs, copied out of the `NSEvent`.
private struct PopupKeyPress: Sendable {
    let keyCode: UInt16
    let characters: String
    let modifierFlags: NSEvent.ModifierFlags
}
