import AppKit
import DockGroupsCore
import SwiftUI

/// New Trigger / Edit Trigger (triggers spec §3.2): when — a time on chosen days, at login, when
/// the app opens, when the screens wake or sleep —, what to do — only the actions that event
/// allows —, how — a notice, Ask First, Run Right Away; Show the Popup runs right away — and At
/// most once a day. It says what a Start or Finish does (never quitting), how late a missed time
/// still runs, and when an At Login trigger needs Open at Login. Return saves, Escape cancels.
struct TriggerEditorSheet: View {
    let group: DockGroup
    let existing: GroupTrigger?
    let store: TriggerStore
    @ObservedObject var loginItem: LoginItem
    let dismiss: () -> Void

    @State private var draft: TriggerDraft
    @State private var problem: String?

    private typealias Texts = L10n.Triggers.Editor
    private let calendar = Calendar.autoupdatingCurrent

    init(group: DockGroup, existing: GroupTrigger?, store: TriggerStore, loginItem: LoginItem, dismiss: @escaping () -> Void) {
        self.group = group
        self.existing = existing
        self.store = store
        self.loginItem = loginItem
        self.dismiss = dismiss
        let calendar = Calendar.autoupdatingCurrent
        _draft = State(initialValue: existing.flatMap { TriggerDraft(editing: $0, calendar: calendar) } ?? TriggerDraft(calendar: calendar))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? Texts.newTitle(group.name) : Texts.editTitle)
                .font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 12) {
                whenRows
                doRow
                howRow
            }
            notes
            HStack {
                Spacer()
                Button(L10n.Common.cancel, role: .cancel, action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button(existing == nil ? Texts.add : Texts.save, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isValid)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    // MARK: - When

    @ViewBuilder
    private var whenRows: some View {
        GridRow {
            Text(Texts.when)
                .gridColumnAlignment(.trailing)
            Picker(Texts.when, selection: Binding(get: { draft.kind }, set: { draft.setKind($0) })) {
                ForEach(TriggerDraft.Kind.allCases, id: \.self) { kind in
                    Text(Self.title(of: kind)).tag(kind)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        if draft.kind == .time {
            GridRow {
                Text(Texts.time)
                DatePicker(Texts.time, selection: timeBinding, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .fixedSize()
                    .environment(\.timeZone, Self.utc)
            }
            GridRow {
                Text(Texts.days)
                VStack(alignment: .leading, spacing: 8) {
                    dayButtons
                    dayPresets
                }
            }
        }
    }

    private var dayPresets: some View {
        HStack {
            Button(Texts.weekdays) { draft.weekdays = TriggerSchedule.workingDays(in: calendar) }
            Button(Texts.weekends) { draft.weekdays = TriggerSchedule.weekendDays(in: calendar) }
            Button(Texts.everyDay) { draft.weekdays = TriggerSchedule.everyDay }
        }
        .controlSize(.small)
    }

    // MARK: - Do and How

    private var doRow: some View {
        GridRow {
            Text(Texts.action)
            VStack(alignment: .leading, spacing: 6) {
                Picker(Texts.action, selection: Binding(get: { draft.action }, set: { draft.setAction($0) })) {
                    ForEach(draft.allowedActions, id: \.self) { action in
                        Text(Self.title(of: action)).tag(action)
                    }
                }
                .labelsHidden()
                .fixedSize()
                if let hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var howRow: some View {
        GridRow {
            Text(Texts.how)
            VStack(alignment: .leading, spacing: 8) {
                Picker(Texts.how, selection: Binding(get: { draft.runMode }, set: { draft.setRunMode($0) })) {
                    ForEach(draft.allowedRunModes, id: \.self) { mode in
                        Text(Self.title(of: mode)).tag(mode)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(draft.allowedRunModes.count < 2)
                Toggle(Texts.oncePerDay, isOn: $draft.oncePerDay)
            }
        }
    }

    // MARK: - Notes

    /// No day chosen; how late a missed time runs; Open at Login for At Login; why it wasn't saved.
    @ViewBuilder
    private var notes: some View {
        if draft.kind == .time {
            if draft.weekdays.isEmpty {
                Label(Texts.noDays, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text(Texts.catchUp(TriggerDescriptions.time(draft.minuteOfDay, locale: .autoupdatingCurrent)))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if draft.kind == .login, !loginItem.isOn {
            loginItemNote
        }
        if let problem {
            Text(problem)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var loginItemNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Label(Texts.loginNeedsLoginItem(AppInfo.name), systemImage: "info.circle")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(Texts.turnOnLoginItem) { loginItem.set(true) }
            }
            if let failure = loginItem.problem {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var dayButtons: some View {
        let symbols = calendar.veryShortWeekdaySymbols
        let names = calendar.weekdaySymbols
        return HStack(spacing: 4) {
            ForEach(TriggerDescriptions.weekOrder(calendar), id: \.self) { day in
                let isOn = draft.weekdays.contains(day)
                let name = names.indices.contains(day - 1) ? names[day - 1] : "\(day)"
                Button {
                    if isOn { draft.weekdays.remove(day) } else { draft.weekdays.insert(day) }
                } label: {
                    Text(verbatim: symbols.indices.contains(day - 1) ? symbols[day - 1] : "\(day)")
                        .frame(width: 22, height: 22)
                        .background(isOn ? Color.accentColor : Color.secondary.opacity(0.15), in: Circle())
                        .foregroundStyle(isOn ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isOn ? Texts.dayOn(name) : Texts.dayOff(name))
            }
        }
    }

    /// The time picker works in UTC, where every minute of the day exists: no clock change of
    /// today's can shift what it shows or what it sets.
    private static let utc = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!

    private var timeBinding: Binding<Date> {
        Binding(
            get: { Date(timeIntervalSince1970: TimeInterval(draft.minuteOfDay * 60)) },
            set: { date in
                var utcCalendar = Calendar(identifier: .gregorian)
                utcCalendar.timeZone = Self.utc
                let parts = utcCalendar.dateComponents([.hour, .minute], from: date)
                draft.minuteOfDay = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }

    private var hint: String? {
        if draft.kind == .screensSleep { return Texts.sleepHint }
        switch draft.action {
        case .start: return Texts.startHint(group.name)
        case .finish: return Texts.finishHint(group.name)
        case .openAll, .showPopup: return nil
        }
    }

    // MARK: - Saving

    private func save() {
        guard draft.isValid else { return }
        let trigger = draft.trigger(groupID: group.id, replacing: existing)
        if existing != nil {
            if store.update(trigger) {
                dismiss()
            } else {
                problem = TriggerAddResult.groupLimitReached.message
            }
            return
        }
        let result = store.add(trigger)
        if let message = result.message {
            problem = message
        } else {
            dismiss()
        }
    }

    // MARK: - Titles

    static func title(of kind: TriggerDraft.Kind) -> String {
        switch kind {
        case .time: return Texts.atATime
        case .login: return Texts.atLogin
        case .appOpens: return Texts.whenAppOpens(AppInfo.name)
        case .screensWake: return Texts.whenScreensWake
        case .screensSleep: return Texts.whenScreensSleep
        }
    }

    static func title(of action: TriggerAction) -> String {
        switch action {
        case .showPopup: return Texts.showPopup
        case .openAll: return Texts.openAll
        case .start: return Texts.start
        case .finish: return Texts.finish
        }
    }

    static func title(of mode: TriggerRunMode) -> String {
        switch mode {
        case .notice: return Texts.notice
        case .askFirst: return Texts.askFirst
        case .immediately: return Texts.rightAway
        }
    }
}
