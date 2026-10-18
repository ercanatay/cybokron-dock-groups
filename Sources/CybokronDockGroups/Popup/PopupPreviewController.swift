import AppKit
import Quartz

/// Quick Look for the popup: Space shows the selected app's Finder preview (name, version, size)
/// in the shared Quick Look panel, and the preview follows the keyboard selection.
///
/// The popup stays the key window while the preview shows, so its keys keep working: Space again
/// or Escape closes the preview, the arrow keys preview the next app. The popup panel
/// (`PopupPanel`) is Quick Look's controller; this object is the panel's data source.
@MainActor
final class PopupPreviewController: NSObject, QLPreviewPanelDataSource {
    private weak var host: NSPanel?
    /// The app bundle being previewed.
    private var item: URL?
    /// Set from `show` to `close`: the Quick Look panel, while visible, shows this popup's preview.
    private var isPresenting = false
    /// When the Quick Look panel was last ordered in.
    private var orderedInAt: Date?

    init(host: NSPanel) {
        self.host = host
        super.init()
    }

    /// Whether the Quick Look panel is showing this popup's preview.
    var isShown: Bool {
        isPresenting && QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    /// Whether the Quick Look panel came up moments ago. Ordering it in can take the key window from
    /// the popup for an instant; the popup takes it back instead of closing.
    var isSettling: Bool {
        guard isShown, let orderedInAt else { return false }
        return Date().timeIntervalSince(orderedInAt) < 1
    }

    /// Whether the Quick Look panel is the key window, as after a click into it.
    var isKey: Bool {
        isShown && QLPreviewPanel.shared().isKeyWindow
    }

    /// The window number of the Quick Look panel while it shows, so clicks into it don't count as
    /// clicks elsewhere.
    var windowNumber: Int? {
        isShown ? QLPreviewPanel.shared().windowNumber : nil
    }

    /// Shows `url` (an app bundle) in Quick Look, or switches the open preview to it.
    func show(_ url: URL) {
        item = url
        guard let panel = QLPreviewPanel.shared() else { return }
        if isShown {
            panel.reloadData()
            return
        }
        // Visible while another app is frontmost: the popup doesn't activate this app. Quick Look
        // puts its panel above the floating popup by itself.
        panel.hidesOnDeactivate = false
        isPresenting = true
        orderedInAt = Date()
        // `orderFront` (not `orderFrontRegardless`) is what makes Quick Look find its controller,
        // the key popup, and lay itself out; the popup stays key.
        panel.updateController()
        panel.orderFront(nil)
        panel.reloadData()
    }

    /// Closes the preview if it shows; the popup gets the keyboard back.
    func close() {
        item = nil
        defer {
            isPresenting = false
            orderedInAt = nil
        }
        guard isShown else { return }
        let hadKey = QLPreviewPanel.shared().isKeyWindow
        QLPreviewPanel.shared().orderOut(nil)
        if hadKey, let host, host.isVisible {
            host.makeKey()
        }
    }

    // MARK: - Panel control (called by `PopupPanel`)

    func begin(_ panel: QLPreviewPanel) {
        panel.dataSource = self
    }

    func end(_ panel: QLPreviewPanel) {
        if panel.dataSource === self { panel.dataSource = nil }
    }

    // MARK: - QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { item == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { item.map { $0 as NSURL } }
    }
}
