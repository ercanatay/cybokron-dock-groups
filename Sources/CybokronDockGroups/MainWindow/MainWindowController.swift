import AppKit
import DockGroupsCore
import Quartz
import SwiftUI

/// What the group window's item rows need besides the store: where the items are and whether the
/// apps chosen to open them are here (checked when something happened, `ItemPresenceCache`), their
/// icons, Quick Look, and LaunchServices for the details editor's "Open with" menu.
@MainActor
final class GroupWindowItems {
    let presence: ItemPresenceCache
    let icons: AppIconProviding
    let catalog: ApplicationCatalog
    /// Shows a location in Quick Look over the group window; set once the window exists.
    var showPreview: (URL) -> Void = { _ in }
    /// The group window, which open panels attach to as sheets; set once it exists.
    weak var window: NSWindow?

    init(presence: ItemPresenceCache, icons: AppIconProviding, catalog: ApplicationCatalog) {
        self.presence = presence
        self.icons = icons
        self.catalog = catalog
    }
}

/// The group management window: an AppKit window hosting the SwiftUI `MainWindowView`, so it can
/// be opened from the menu bar item and on reopen. Each time it comes to the front, the items of
/// the group it shows are checked again (they may have been moved or deleted meanwhile).
@MainActor
final class MainWindowController: NSWindowController {
    private static let frameAutosaveName = "MainWindow"

    /// Called each time the window is about to show.
    var willShow: (() -> Void)?

    private let store: GroupStore
    private let selection = GroupWindowSelection()
    private let items: GroupWindowItems
    private var preview: PopupPreviewController?
    private var keyObserver: NSObjectProtocol?

    init(
        store: GroupStore,
        templates: TemplateStore,
        tiles: TileImageCache,
        icons: AppIconProviding,
        standalone: StandaloneController,
        session: ContextSession,
        shortcuts: GlobalShortcutMonitor,
        actions: MainWindowView.Actions
    ) {
        self.store = store
        let catalog = SystemApplicationCatalog()
        let items = GroupWindowItems(
            presence: ItemPresenceCache(locator: WorkspaceItemLocator(), catalog: catalog),
            icons: icons,
            catalog: catalog
        )
        self.items = items
        let hostingController = NSHostingController(
            rootView: MainWindowView(
                store: store,
                templates: templates,
                tiles: tiles,
                standalone: standalone,
                session: session,
                shortcuts: shortcuts,
                actions: actions,
                selection: selection,
                items: items
            )
        )
        hostingController.sizingOptions = [.minSize]

        let window = GroupWindow(contentViewController: hostingController)
        window.title = AppInfo.name
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 860, height: 580))
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)
        super.init(window: window)

        items.window = window
        let preview = PopupPreviewController(host: window)
        window.preview = preview
        self.preview = preview
        items.showPreview = { [weak preview] url in preview?.show(url) }
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak items] _ in
            MainActor.assumeIsolated { items?.presence.refresh() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows the window and brings the app to the front.
    func show() {
        willShow?()
        NSApp.activate()
        if let window, window.isMiniaturized {
            window.deminiaturize(nil)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Group Settings: shows the window on the settings of the group `token` names (an identifier
    /// or a name), brought to the front if it's open already. When no group matches it opens on
    /// the group it showed before (`GroupSettingsDestination`).
    @discardableResult
    func showSettings(ofGroup token: String) -> GroupSettingsDestination {
        let destination = GroupSettingsDestination(request: token, current: selection.groupID, in: store.groups)
        selection.groupID = destination.selection
        show()
        return destination
    }

    /// What the popup can't do itself: shows the window on the group and does `action` there —
    /// opens an item's details editor (Edit Details…), or the open panel of Add Apps… or Add Files
    /// or Folders….
    func perform(_ action: GroupWindowRequest.Action, inGroup id: DockGroup.ID) {
        selection.request = GroupWindowRequest(groupID: id, action: action)
        showSettings(ofGroup: id.uuidString)
    }
}

/// The group window. It controls the Quick Look panel while Quick Look shows one of its items:
/// Quick Look looks for its controller in the key window's responder chain.
final class GroupWindow: NSWindow {
    /// Supplies what Quick Look shows.
    weak var preview: PopupPreviewController?

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        preview != nil
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        preview?.begin(panel)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        preview?.end(panel)
    }
}
