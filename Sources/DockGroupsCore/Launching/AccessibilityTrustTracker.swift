import Foundation

/// Follows whether this app has Accessibility access (Privacy & Security → Accessibility).
///
/// Access is granted or revoked in System Settings, which doesn't tell the app, so the current
/// value has to be read again: whenever `refresh()` is called (a window shows, the app becomes
/// active) and, while access is missing and anyone is watching, every `pollInterval` seconds. Once
/// access is granted the polling stops; it resumes when a later refresh finds access revoked.
///
/// The tracker only decides; its owner runs the timer (`onPollingChange`) and publishes the value
/// (`onChange`).
@MainActor
public final class AccessibilityTrustTracker {
    /// How often access is read again while it's missing and watched.
    public static let pollInterval: TimeInterval = 1

    /// Whether access was granted when last read.
    public private(set) var isTrusted: Bool
    /// Whether the owner should read access every `pollInterval` seconds.
    public private(set) var isPolling = false
    /// Called with the new value when a refresh finds it changed.
    public var onChange: ((Bool) -> Void)?
    /// Called when polling should start (`true`) or stop (`false`).
    public var onPollingChange: ((Bool) -> Void)?

    private let check: () -> Bool
    private var observerCount = 0

    /// - Parameter check: reads the current access, e.g. `AXIsProcessTrusted()`. Never cached.
    public init(check: @escaping () -> Bool) {
        self.check = check
        isTrusted = check()
    }

    /// Someone shows or needs the access status (a settings pane appears, shortcuts are on): reads
    /// it now and polls while it's missing.
    public func beginObserving() {
        observerCount += 1
        refresh()
    }

    /// Balances `beginObserving()`; polling stops with the last observer.
    public func endObserving() {
        observerCount = max(0, observerCount - 1)
        updatePolling()
    }

    /// Reads access again. Returns whether it changed.
    @discardableResult
    public func refresh() -> Bool {
        let trusted = check()
        let changed = trusted != isTrusted
        isTrusted = trusted
        if changed {
            onChange?(trusted)
        }
        updatePolling()
        return changed
    }

    private func updatePolling() {
        let shouldPoll = !isTrusted && observerCount > 0
        guard shouldPoll != isPolling else { return }
        isPolling = shouldPoll
        onPollingChange?(shouldPoll)
    }
}
