import AppKit
import DockGroupsCore
import SwiftUI

/// The notice before a trigger runs (triggers spec §1.7, §3.4): a small panel at the top right of
/// the screen with the menu bar, under it. It never takes the keyboard (non-activating, never key),
/// so the app the user is typing in keeps every key press; its buttons take the first click.
///
/// - **Show a 5-Second Notice**: "Starting “Work”" with the rule under it and a countdown; Not Now
///   skips this time, Start Now runs at once, the end of the countdown runs it.
/// - **Ask First**: "Start “Work”?" with Not Now and Start; after 2 minutes without an answer it
///   closes, and the occurrence is skipped.
///
/// VoiceOver announces it. One at a time (the coordinator shows them in turn); `dismiss()` ends the
/// one showing, when a newer Start takes its place.
@MainActor
final class TriggerNoticePanel: TriggerNoticePresenting {
    /// What a notice's trigger waits for ("At 9:00 on weekdays"), shown under its title.
    var describe: (TriggerNotice) -> String = { _ in "" }

    private let model = TriggerNoticeModel()
    private var panel: TriggerNoticeWindow?
    private var waiting: CheckedContinuation<TriggerNoticeAnswer, Never>?
    private var timer: Task<Void, Never>?

    func present(_ notice: TriggerNotice) async -> TriggerNoticeAnswer {
        // A notice still showing (there shouldn't be one) ends as replaced.
        finish(.replaced)
        model.configure(for: notice, detail: describe(notice))
        model.answer = { [weak self] answer in self?.finish(answer) }
        show()
        announce()
        return await withCheckedContinuation { continuation in
            waiting = continuation
            startTimer(for: notice)
        }
    }

    func dismiss() {
        finish(.replaced)
    }

    private func finish(_ answer: TriggerNoticeAnswer) {
        timer?.cancel()
        timer = nil
        panel?.orderOut(nil)
        let continuation = waiting
        waiting = nil
        continuation?.resume(returning: answer)
    }

    private func startTimer(for notice: TriggerNotice) {
        let seconds = Int(notice.waits.components.seconds)
        timer = Task { @MainActor [weak self] in
            if notice.runMode == .askFirst {
                try? await Task.sleep(for: notice.waits)
                guard !Task.isCancelled else { return }
                self?.finish(.timedOut)
                return
            }
            for remaining in stride(from: seconds, to: 0, by: -1) {
                self?.model.secondsLeft = remaining
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
            }
            self?.finish(.run)
        }
    }

    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        // The screen with the menu bar, at its top right, under the menu bar.
        let screen = NSScreen.screens.first ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: visible.maxX - size.width - 12, y: visible.maxY - size.height - 8)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> TriggerNoticeWindow {
        let panel = TriggerNoticeWindow()
        let hosting = FirstMouseHostingView(rootView: TriggerNoticeView(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        return panel
    }

    private func announce() {
        let text = L10n.Triggers.Notice.announcement(model.title, model.detail)
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }
}

/// The panel: floating, on every Space and over full-screen apps, never key or main.
private final class TriggerNoticeWindow: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// What the notice shows.
@MainActor
private final class TriggerNoticeModel: ObservableObject {
    @Published var title = ""
    @Published var detail = ""
    @Published var symbol = "clock"
    @Published var primary = ""
    /// The countdown; `nil` for Ask First.
    @Published var secondsLeft: Int?
    var answer: (TriggerNoticeAnswer) -> Void = { _ in }

    func configure(for notice: TriggerNotice, detail: String) {
        typealias Texts = L10n.Triggers.Notice
        let name = notice.groupName
        let asks = notice.runMode == .askFirst
        switch notice.action {
        case .start:
            title = asks ? Texts.askStart(name) : Texts.starting(name)
            primary = asks ? L10n.Triggers.Editor.start : Texts.startNow
            symbol = "play.circle"
        case .openAll:
            title = asks ? Texts.askOpen(name) : Texts.opening(name)
            primary = asks ? L10n.Common.openAll : Texts.openNow
            symbol = "arrow.up.forward.app"
        case .finish:
            title = asks ? Texts.askFinish(name) : Texts.finishing(name)
            primary = asks ? L10n.Triggers.Editor.finish : Texts.finishNow
            symbol = "stop.circle"
        case .showPopup:
            title = asks ? Texts.askShow(name) : Texts.showing(name)
            primary = Texts.showNow
            symbol = "square.grid.2x2"
        }
        self.detail = detail
        secondsLeft = asks ? nil : Int(notice.waits.components.seconds)
    }
}

private struct TriggerNoticeView: View {
    @ObservedObject var model: TriggerNoticeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: model.symbol)
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: model.title)
                        .font(.headline)
                        .lineLimit(2)
                    if !model.detail.isEmpty {
                        Text(verbatim: model.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                if let seconds = model.secondsLeft {
                    Text(verbatim: "\(seconds)")
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(L10n.Triggers.Notice.seconds(seconds))
                }
            }
            HStack {
                Spacer()
                Button(L10n.Triggers.Notice.notNow) { model.answer(.notNow) }
                Button(model.primary) { model.answer(.run) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator))
        .accessibilityElement(children: .contain)
    }
}
