import AppKit
import DockGroupsCore
import SwiftUI

/// What the capture sheet shows and keeps while it's open: the plan of one snapshot, the selection,
/// the order and window option, and the name. Changing the order or the window option saves it
/// and plans the same snapshot again — the open apps aren't read again (capture spec §2.6).
@MainActor
final class CaptureSheetModel: ObservableObject {
    let request: CaptureRequest
    private let capture: CaptureController

    @Published private(set) var plan: CapturePlan
    @Published private(set) var selection: CaptureSelection
    @Published private(set) var settings: CaptureSettings
    /// The name field: the suggestion until the user types (spec §1.6).
    @Published private(set) var name: String
    private(set) var nameWasEdited = false

    init(request: CaptureRequest, capture: CaptureController) {
        self.request = request
        self.capture = capture
        let settings = capture.settings
        let plan = capture.plan(for: request, settings: settings)
        let selection = CaptureSelection(plan: plan)
        self.settings = settings
        self.plan = plan
        self.selection = selection
        name = capture.suggestedName(for: selection.items(in: plan))
    }

    var isNewGroup: Bool { request.target == .newGroup }

    /// The group apps are added to; `nil` for a new group, or when it's no longer an active group.
    var groupName: String? { capture.groupName(of: request.target) }

    /// The name a new group gets now: the suggestion for the selected apps.
    var suggestion: String { capture.suggestedName(for: selection.items(in: plan)) }

    func setName(_ typed: String) {
        name = typed
        nameWasEdited = true
    }

    func setOrder(_ order: CaptureSettings.Order) {
        var changed = settings
        changed.order = order
        apply(changed)
    }

    func setSelectsOnlyAppsWithWindows(_ isOn: Bool) {
        var changed = settings
        changed.selectsOnlyAppsWithWindows = isOn
        apply(changed)
    }

    /// Saves the settings and plans the same snapshot again; the selection starts over (spec §1.5).
    private func apply(_ changed: CaptureSettings) {
        guard changed != settings else { return }
        settings = changed
        capture.settings = changed
        plan = capture.plan(for: request, settings: changed)
        selection = CaptureSelection(plan: plan)
        followSuggestion()
    }

    func isSelected(_ candidate: CaptureCandidate) -> Bool {
        selection.isSelected(candidate) || !candidate.isSelectable
    }

    func canToggle(_ candidate: CaptureCandidate) -> Bool {
        selection.canToggle(candidate)
    }

    func set(_ candidate: CaptureCandidate, selected: Bool) {
        guard selection.set(candidate, selected: selected) else { return }
        followSuggestion()
    }

    func selectAll() {
        selection.selectAll(in: plan)
        followSuggestion()
    }

    func selectNone() {
        selection.selectNone()
        followSuggestion()
    }

    /// The name follows the selection until the user edits it.
    private func followSuggestion() {
        if !nameWasEdited {
            name = suggestion
        }
    }

    var selectableCount: Int { plan.candidates.filter(\.isSelectable).count }

    /// Whether the limit holds apps back: as many are selected as one capture adds, and there are more.
    var showsLimit: Bool { selection.isAtLimit && selectableCount > CapturePlan.maximumItems }

    var canCommit: Bool { !selection.isEmpty }

    /// Adds the selected apps; the name typed counts only once the user edited the field.
    func commit() -> CaptureResult {
        capture.commit(selection.items(in: plan), into: request.target, typedName: nameWasEdited ? name : "")
    }
}

/// New Group from Open Apps and Add Open Apps (capture spec §1.2–§1.8, §3.1–§3.2): the open apps
/// as they were when the user asked, which ones to add, and — for a new group — its name. Nothing
/// is opened, hidden or quit; the user's click adds the apps.
struct CaptureSheet: View {
    @StateObject private var model: CaptureSheetModel
    let icons: AppIconProviding
    /// A new group was made: the group window selects it.
    let onCreated: (DockGroup.ID) -> Void
    let dismiss: () -> Void

    @FocusState private var isNameFocused: Bool
    private typealias Texts = L10n.Capture.Sheet

    init(request: CaptureRequest, capture: CaptureController, icons: AppIconProviding, onCreated: @escaping (DockGroup.ID) -> Void, dismiss: @escaping () -> Void) {
        _model = StateObject(wrappedValue: CaptureSheetModel(request: request, capture: capture))
        self.icons = icons
        self.onCreated = onCreated
        self.dismiss = dismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            if model.plan.candidates.isEmpty {
                emptyState(Texts.noOpenApps)
            } else if !model.plan.hasSelectableCandidates {
                emptyState(Texts.allInGroup(model.groupName ?? ""))
            } else {
                content
            }
        }
        .padding(20)
        .frame(width: 520)
        // Escape closes the sheet in every state, Done's included.
        .onExitCommand(perform: dismiss)
        .onChange(of: model.showsLimit) { _, isShown in
            if isShown {
                AccessibilityNotification.Announcement(CapturePlan.limitNote).post()
            }
        }
    }

    private var title: String {
        model.isNewGroup ? Texts.newGroupTitle : Texts.addTitle(model.groupName ?? "")
    }

    /// Nothing to choose: the reason and Done.
    private func emptyState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L10n.Common.done, action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isNewGroup {
            LabeledContent(Texts.name) {
                TextField(Texts.name, text: Binding(get: { model.name }, set: model.setName), prompt: Text(model.suggestion))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .focused($isNameFocused)
                    .onSubmit(commit)
            }
            .onAppear { isNameFocused = true }
        }

        HStack {
            Text(Texts.header(model.plan.candidates.count))
                .font(.subheadline.weight(.semibold))
            Spacer()
            Picker(Texts.order, selection: Binding(get: { model.settings.order }, set: model.setOrder)) {
                Text(Texts.orderRecentlyUsed).tag(CaptureSettings.Order.recentlyUsed)
                Text(Texts.orderName).tag(CaptureSettings.Order.name)
            }
            .fixedSize()
        }

        List {
            ForEach(model.plan.candidates) { candidate in
                row(candidate)
            }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: true))
        .frame(height: 280)

        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Toggle(Texts.windowsOnly, isOn: Binding(get: { model.settings.selectsOnlyAppsWithWindows }, set: model.setSelectsOnlyAppsWithWindows))
                    .toggleStyle(.checkbox)
                    .disabled(!model.plan.hasWindowInformation)
                if !model.plan.hasWindowInformation {
                    Text(Texts.windowsOnlyUnavailable)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(Texts.selectAll, action: model.selectAll)
            Button(Texts.selectNone, action: model.selectNone)
                .disabled(model.selection.isEmpty)
        }

        VStack(alignment: .leading, spacing: 4) {
            if model.showsLimit {
                Label(CapturePlan.limitNote, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if let note = model.plan.unavailableNote {
                Text(note)
            }
            Text(Texts.footer(AppInfo.name))
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        HStack {
            Spacer()
            Button(L10n.Common.cancel, role: .cancel, action: dismiss)
                .keyboardShortcut(.cancelAction)
            Button(model.isNewGroup ? Texts.create : Texts.add(model.selection.count), action: commit)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canCommit)
        }
    }

    /// One open app: its checkbox (checked and dimmed when the group has it), icon, name and what
    /// to know about it.
    private func row(_ candidate: CaptureCandidate) -> some View {
        let caption = Self.caption(for: candidate.notes)
        return HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { model.isSelected(candidate) }, set: { model.set(candidate, selected: $0) })) {
                HStack(spacing: 8) {
                    Image(nsImage: icons.icon(for: candidate.item))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 20, height: 20)
                        .accessibilityHidden(true)
                    Text(candidate.item.displayName)
                        .lineLimit(1)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(!model.canToggle(candidate))
            Spacer(minLength: 8)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .opacity(candidate.isSelectable ? 1 : 0.6)
        .accessibilityElement(children: .combine)
        .accessibilityValue(caption ?? "")
    }

    /// "In this group", "Protected · No open windows", …; `nil` without notes.
    static func caption(for notes: Set<CaptureCandidate.Note>) -> String? {
        let ordered: [(CaptureCandidate.Note, String)] = [
            (.inGroup, Texts.inGroup), (.protected, Texts.protected), (.hidden, Texts.hidden), (.noWindows, Texts.noWindows),
        ]
        let texts = ordered.filter { notes.contains($0.0) }.map(\.1)
        return texts.isEmpty ? nil : texts.joined(separator: " · ")
    }

    private func commit() {
        guard model.canCommit else { return }
        switch model.commit() {
        case .created(let group):
            onCreated(group.id)
        case .added:
            break
        case .unavailableGroup:
            NSSound.beep()
        }
        dismiss()
    }
}
