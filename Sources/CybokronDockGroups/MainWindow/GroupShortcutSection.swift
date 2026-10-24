import AppKit
import DockGroupsCore
import SwiftUI

/// Records and saves one group's keyboard shortcut (spec §1.2).
///
/// While it records, every hot key and the number shortcuts' monitors are let go
/// (`GlobalShortcutMonitor.beginRecording`), so the keys reach it even when they're a shortcut
/// already, and a local event monitor takes the next key press. Recording ends on that key press,
/// on Escape (nothing changes), on Delete (the shortcut is removed), on a click anywhere but the
/// field, when a window resigns key or the app resigns active, and when the section goes away —
/// and every end brings the hot keys back (`endRecording`), so they can't stay off.
@MainActor
final class GroupShortcutEditor: ObservableObject {
    @Published private(set) var isRecording = false
    /// The modifiers held while recording, shown in the field.
    @Published private(set) var heldModifiers: KeyModifiers = []
    /// Why the keys pressed last weren't taken; cleared by the next recording.
    @Published private(set) var refusal: String?

    /// The field, so a click on it toggles recording instead of cancelling it.
    weak var field: NSView?

    private let shortcuts: GlobalShortcutMonitor
    private let store: GroupStore
    private let groupID: DockGroup.ID
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []

    init(shortcuts: GlobalShortcutMonitor, store: GroupStore, groupID: DockGroup.ID) {
        self.shortcuts = shortcuts
        self.store = store
        self.groupID = groupID
    }

    func toggle() {
        if isRecording {
            end()
        } else {
            begin()
        }
    }

    func begin() {
        guard !isRecording else { return }
        isRecording = true
        heldModifiers = []
        refusal = nil
        shortcuts.beginRecording()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            // Only Sendable values cross into the isolated block.
            let type = event.type
            let isKey = type == .keyDown || type == .flagsChanged
            let keyCode = isKey ? event.keyCode : 0
            let flags = event.modifierFlags
            let isRepeat = type == .keyDown && event.isARepeat
            let windowNumber = event.windowNumber
            let location = event.locationInWindow
            let swallow = MainActor.assumeIsolated {
                self?.handle(type: type, keyCode: keyCode, flags: flags, isRepeat: isRepeat, windowNumber: windowNumber, location: location) ?? false
            }
            return swallow ? nil : event
        }
        observers = [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.end() }
            }
        }
    }

    /// Ends a recording, if one is under way, and brings the hot keys back.
    func end() {
        guard isRecording else { return }
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        isRecording = false
        heldModifiers = []
        shortcuts.endRecording()
    }

    /// Removes the group's shortcut.
    func remove() {
        refusal = nil
        store.setShortcut(nil, forGroup: groupID)
    }

    /// Keeps the keys and changes what they do.
    func setAction(_ action: GroupShortcutAction) {
        guard let keys = store.group(withID: groupID)?.shortcut?.keys, let shortcut = GroupShortcut(keys: keys, action: action) else { return }
        store.setShortcut(shortcut, forGroup: groupID)
    }

    /// Returns whether the event is taken (not passed on).
    private func handle(type: NSEvent.EventType, keyCode: UInt16, flags: NSEvent.ModifierFlags, isRepeat: Bool, windowNumber: Int, location: NSPoint) -> Bool {
        switch type {
        case .keyDown:
            guard !isRepeat else { return true }
            let input = ShortcutRecorderInput.interpret(keyCode: keyCode, modifierFlags: flags)
            end()
            apply(input)
            return true
        case .flagsChanged:
            heldModifiers = KeyModifiers(eventFlags: flags)
            return false
        default:
            // A click on the field toggles (its own action); anywhere else cancels.
            if let field, field.window?.windowNumber == windowNumber, field.bounds.contains(field.convert(location, from: nil)) {
                return false
            }
            end()
            return false
        }
    }

    private func apply(_ input: ShortcutRecorderInput) {
        switch input {
        case .cancel:
            break
        case .clear:
            remove()
        case .keys(let keys):
            if let refused = shortcuts.refusal(for: keys, group: groupID) {
                refusal = message(for: refused, keys: keys)
                return
            }
            let action = store.group(withID: groupID)?.shortcut?.action ?? .showPopup
            guard let shortcut = GroupShortcut(keys: keys, action: action) else { return }
            if case .refused(let refused) = store.setShortcut(shortcut, forGroup: groupID) {
                refusal = message(for: refused, keys: keys)
            }
        }
    }

    private func message(for refusal: GroupShortcutRefusal, keys: KeyCombination) -> String {
        var owner: String?
        if case .takenByGroup(let id) = refusal {
            owner = store.group(withID: id)?.name
        }
        return refusal.message(keyTitle: KeyNames.title(for: keys), otherGroupName: owner)
    }
}

/// The group window's Keyboard Shortcut section (spec §3.1): the recorder, what pressing the
/// shortcut does, and whether it works — or why the keys pressed last weren't taken.
struct GroupShortcutSection: View {
    @ObservedObject var store: GroupStore
    @ObservedObject var shortcuts: GlobalShortcutMonitor
    let group: DockGroup
    @StateObject private var editor: GroupShortcutEditor

    init(store: GroupStore, shortcuts: GlobalShortcutMonitor, group: DockGroup) {
        self.store = store
        self.shortcuts = shortcuts
        self.group = group
        _editor = StateObject(wrappedValue: GroupShortcutEditor(shortcuts: shortcuts, store: store, groupID: group.id))
    }

    private typealias Texts = L10n.GroupWindow.Shortcut

    var body: some View {
        Section {
            LabeledContent(Texts.label) {
                HStack(spacing: 6) {
                    ShortcutRecorderField(editor: editor, title: fieldTitle, accessibilityLabel: accessibilityLabel, help: Texts.fieldHelp)
                        .frame(minWidth: 170, idealWidth: 200)
                        .fixedSize()
                    if group.shortcut != nil, !editor.isRecording {
                        Button(action: editor.remove) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(Texts.remove)
                        .accessibilityLabel(Texts.remove)
                    }
                }
            }
            Picker(Texts.whenPressed, selection: actionBinding) {
                ForEach(GroupShortcutAction.allCases, id: \.self) { action in
                    Text(action.title).tag(action)
                }
            }
            .disabled(group.shortcut == nil)
            statusLine
            if group.shortcut?.action == .startOrFinish {
                Label(Texts.startNote, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text(Texts.section)
        }
        .onAppear { shortcuts.refreshSystemShortcuts() }
        .onDisappear { editor.end() }
    }

    @ViewBuilder
    private var statusLine: some View {
        if editor.isRecording {
            Text(Texts.recordingHelp)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if let refusal = editor.refusal {
            Label(refusal, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if let shortcut = group.shortcut {
            let status = shortcuts.groupStatuses[group.id] ?? .paused
            Label(statusMessage(status, keys: shortcut.keys), systemImage: status.isOn ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(status.isOn ? Color.green : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(Texts.none)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func statusMessage(_ status: GroupShortcutStatus, keys: KeyCombination) -> String {
        var owner: String?
        if case .off(.takenByGroup(let id)) = status {
            owner = store.group(withID: id)?.name
        }
        return status.message(keyTitle: KeyNames.title(for: keys), otherGroupName: owner)
    }

    private var fieldTitle: String {
        if editor.isRecording {
            let held = editor.heldModifiers.symbols
            return held.isEmpty ? Texts.recording : "\(held) \(Texts.recording)"
        }
        return group.shortcut.map { KeyNames.title(for: $0.keys) } ?? Texts.record
    }

    private var accessibilityLabel: String {
        group.shortcut.map { Texts.accessibility(KeyNames.title(for: $0.keys)) } ?? Texts.accessibilityNone
    }

    private var actionBinding: Binding<GroupShortcutAction> {
        Binding(
            get: { group.shortcut?.action ?? .showPopup },
            set: { editor.setAction($0) }
        )
    }
}

/// The recorder's field: a button showing the shortcut (or "Record Shortcut"); clicking it starts
/// or ends recording. An AppKit button, so the editor can tell a click on it from a click elsewhere.
private struct ShortcutRecorderField: NSViewRepresentable {
    @ObservedObject var editor: GroupShortcutEditor
    let title: String
    let accessibilityLabel: String
    let help: String

    func makeCoordinator() -> Coordinator {
        Coordinator(editor: editor)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.clicked))
        button.bezelStyle = .push
        button.lineBreakMode = .byTruncatingTail
        editor.field = button
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.editor = editor
        editor.field = button
        button.title = title
        button.toolTip = help
        button.setAccessibilityLabel(accessibilityLabel)
        button.bezelColor = editor.isRecording ? .controlAccentColor : nil
        button.contentTintColor = editor.isRecording ? .white : nil
    }

    @MainActor
    final class Coordinator: NSObject {
        var editor: GroupShortcutEditor

        init(editor: GroupShortcutEditor) {
            self.editor = editor
        }

        @objc func clicked() {
            editor.toggle()
        }
    }
}
