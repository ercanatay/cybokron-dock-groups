import AppKit
import Combine
import DockGroupsCore
import OSLog
import QuartzCore
import SwiftUI

/// Shows a group's popup: positions the panel over the Dock, keeps it in sync with the group and
/// the popup preferences while it's open, and closes it on Escape, an outside click or focus loss.
@MainActor
final class PopupPanelController: NSObject, NSWindowDelegate {
    struct Actions {
        let open: (AppReference, DockGroup) -> Void
        let openAll: (DockGroup) -> Void
        let closeAll: (DockGroup, QuitMode) -> Void
        let manageGroups: () -> Void
    }

    /// Why the popup closed; logged at debug level to diagnose unexpected closes.
    enum CloseReason: String {
        case requested, toggled, escape, outsideClick, appWindowClick, lostFocus, groupDeleted, appAction
    }

    private static let escapeKeyCode: UInt16 = 53
    private let logger = Logger(subsystem: "com.cybokron.dockgroups", category: "Popup")

    private let store: GroupStore
    private let preferences: PreferencesStore
    private let tiles: TileImageCache
    private let icons: AppIconProviding
    private let runningApps: RunningAppsMonitor
    private let actions: Actions
    private let modifierKeys = ModifierKeyState()

    private let panel = PopupPanel()
    private var hostingView: FirstMouseHostingView<PopupContentView>?
    private var containerView: PopupContainerView?
    private var eventMonitors: [Any] = []
    private var subscriptions: Set<AnyCancellable> = []
    /// Bumped by every show and close, so a finished fade-out doesn't hide a popup shown since.
    private var transition = 0

    /// The group whose popup is open, `nil` while closed.
    private(set) var groupID: DockGroup.ID?
    /// The group whose popup was shown last, even if it's closed now.
    private(set) var lastGroupID: DockGroup.ID?

    var isShown: Bool { groupID != nil }

    init(
        store: GroupStore,
        preferences: PreferencesStore,
        tiles: TileImageCache,
        icons: AppIconProviding,
        runningApps: RunningAppsMonitor,
        actions: Actions
    ) {
        self.store = store
        self.preferences = preferences
        self.tiles = tiles
        self.icons = icons
        self.runningApps = runningApps
        self.actions = actions
        super.init()

        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close(reason: .escape) }
        // @Published fires before the value changes; the main-queue hop reads the new value.
        store.$groups.map { _ in () }
            .merge(with: preferences.$preferences.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &subscriptions)
    }

    // MARK: - Showing and closing

    func toggle(groupID id: DockGroup.ID) {
        if groupID == id {
            close(reason: .toggled)
        } else {
            show(groupID: id)
        }
    }

    func show(groupID id: DockGroup.ID) {
        guard let group = store.group(withID: id), let frame = update(for: group) else { return }
        let wasShown = groupID != nil && panel.isVisible
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
    }

    func windowDidResignKey(_ notification: Notification) {
        close(reason: .lostFocus)
    }

    // MARK: - Content

    /// Re-renders the open popup after its group or the preferences changed.
    private func refresh() {
        guard let id = groupID else { return }
        guard let group = store.group(withID: id) else {
            close(reason: .groupDeleted)
            return
        }
        if let frame = update(for: group) {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
    }

    /// Puts `group`'s content into the panel and returns the panel's frame.
    private func update(for group: DockGroup) -> CGRect? {
        guard let dock = DockScreenReader.current() else { return nil }
        let popupPreferences = preferences.preferences
        let settings = popupPreferences.resolved(with: group.popup)
        let metrics = PopupMetrics.grid(showsTitles: settings.showsTitles)
        let layout = PopupGridLayout(itemCount: group.apps.count, columns: settings.columns, maxRows: settings.maxRows)

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
            cells: group.apps.map { PopupCell(app: $0, icon: icons.icon(for: $0), isInstalled: icons.isInstalled($0)) },
            layout: layout,
            metrics: metrics,
            showsTitles: settings.showsTitles,
            size: size,
            gridHeight: gridHeight,
            scrolls: layout.contentHeight(metrics: metrics) > gridHeight + 0.5,
            usesFrostedGlass: popupPreferences.usesFrostedGlass
        )

        panel.appearance = popupPreferences.theme.appearance
        let rootView = PopupContentView(
            content: content,
            runningApps: runningApps,
            modifierKeys: modifierKeys,
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

        // Until Dock tiles exist the clicked tile's location is unknown, so "above the clicked
        // icon" centers over the Dock as well.
        return PopupPlacement.frame(size: size, anchor: settings.anchor, dockEdge: dock.edge, screen: dock.screen)
    }

    /// Actions look the group up when they run, so they always act on its current state.
    private func popupActions(for id: DockGroup.ID) -> PopupActions {
        PopupActions(
            open: { [weak self] app in
                guard let self, let group = self.store.group(withID: id) else { return }
                self.close(reason: .appAction)
                self.actions.open(app, group)
            },
            openAll: { [weak self] in
                guard let self, let group = self.store.group(withID: id) else { return }
                self.close(reason: .appAction)
                self.actions.openAll(group)
            },
            closeAll: { [weak self] mode in
                guard let self, let group = self.store.group(withID: id) else { return }
                self.close(reason: .appAction)
                self.actions.closeAll(group, mode)
            },
            manageGroups: { [weak self] in
                self?.close(reason: .appAction)
                self?.actions.manageGroups()
            },
            moveApp: { [weak self] app, index in
                guard let self else { return }
                self.logger.notice("Moving \(app.bundleIdentifier, privacy: .public) to \(index) in group \(id, privacy: .public)")
                self.store.moveApp(bundleIdentifier: app.bundleIdentifier, inGroup: id, to: index)
            },
            removeApp: { [weak self] app in
                guard let self else { return }
                self.logger.notice("Removing \(app.bundleIdentifier, privacy: .public) from group \(id, privacy: .public)")
                self.store.removeApp(bundleIdentifier: app.bundleIdentifier, fromGroup: id)
            },
            isPointerInRemovalArea: { [weak self] in
                guard let self else { return false }
                return PopupDrag.isRemovalLocation(NSEvent.mouseLocation, panelFrame: self.panel.frame)
            }
        )
    }

    // MARK: - Event monitoring

    private func installEventMonitors() {
        guard eventMonitors.isEmpty else { return }
        // Monitors run on the main thread; only Sendable values cross into the isolated blocks.
        let local: [(NSEvent.EventTypeMask, (NSEvent) -> NSEvent?)] = [
            (.keyDown, { [weak self] event in
                guard event.keyCode == Self.escapeKeyCode else { return event }
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self, self.groupID != nil else { return false }
                    self.close(reason: .escape)
                    return true
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
                    guard let self, windowNumber != self.panel.windowNumber else { return }
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

    private func removeEventMonitors() {
        for monitor in eventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        eventMonitors.removeAll()
    }
}

/// Reads where the Dock is: its screen and edge.
@MainActor
enum DockScreenReader {
    static func current() -> (edge: DockEdge, screen: ScreenGeometry)? {
        let screens = NSScreen.screens.map { ScreenGeometry(frame: $0.frame, visibleFrame: $0.visibleFrame) }
        guard let primary = screens.first else { return nil }
        // The Dock stores its edge as "bottom", "left" or "right"; the key is absent until the user
        // moves the Dock away from the bottom.
        let orientation = UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") ?? "bottom"
        let edge = DockEdge(orientation: orientation, screen: primary)
        let index = PopupPlacement.dockScreenIndex(edge: edge, screens: screens, mouseLocation: NSEvent.mouseLocation) ?? 0
        return (edge, screens[index])
    }
}
