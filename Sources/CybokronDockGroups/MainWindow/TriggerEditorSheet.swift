import AppKit
import DockGroupsCore
import SwiftUI

/// New Trigger / Edit Trigger (triggers spec §3.2): when — a time on chosen days, at login, when
/// the app opens, when the screens wake or sleep, when a display (any external one, or a chosen
/// one) connects or disconnects, when these displays are connected or no longer, when the Mac joins
/// or leaves a Wi-Fi network, when Ethernet connects or disconnects —, what to do — only the
/// actions that event allows, with Finish when it ends for a Start on a change's start —, how — a
/// notice, Ask First, Run Right Away; Show the Popup runs right away — and At most once a day. It
/// says what a Start or Finish does (never quitting), how late a missed time still runs, and when an
/// At Login trigger needs Open at Login. Return saves, Escape cancels.
///
/// The display chooser lists the displays connected now, read again when they change, and a saved
/// display that isn't connected by its name, "not connected".
///
/// A Wi-Fi network is typed, or filled in with Use Current Network once macOS lets the app see
/// network names. That takes Location access, which is asked for only here, only when the user
/// clicks Allow… (`LocationAccess.request`); refused, Open Privacy Settings… goes to the list. The
/// trigger can be added either way: it waits for the access. VPNs aren't offered (TS-8).
struct TriggerEditorSheet: View {
    let group: DockGroup
    let existing: GroupTrigger?
    let store: TriggerStore
    @ObservedObject var loginItem: LoginItem
    @ObservedObject var locationAccess: LocationAccess
    /// The displays connected now (`DisplaySource.connectedDisplays`).
    let readDisplays: () -> [DisplayIdentity]
    /// The Wi-Fi network the Mac is on, when macOS shows its name
    /// (`TriggerController.currentWiFiNetworkName`).
    let readNetworkName: () -> String?
    let dismiss: () -> Void

    @State private var draft: TriggerDraft
    @State private var problem: String?
    @State private var connected: [DisplayIdentity] = []
    @State private var currentNetwork: String?

    private typealias Texts = L10n.Triggers.Editor
    private let calendar = Calendar.autoupdatingCurrent

    init(
        group: DockGroup,
        existing: GroupTrigger?,
        store: TriggerStore,
        loginItem: LoginItem,
        locationAccess: LocationAccess,
        readDisplays: @escaping () -> [DisplayIdentity],
        readNetworkName: @escaping () -> String?,
        dismiss: @escaping () -> Void
    ) {
        self.group = group
        self.existing = existing
        self.store = store
        self.loginItem = loginItem
        self.locationAccess = locationAccess
        self.readDisplays = readDisplays
        self.readNetworkName = readNetworkName
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
        .onAppear {
            connected = readDisplays()
            lookAtNetwork()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            connected = readDisplays()
        }
        // Allowed (or taken back) meanwhile: Use Current Network follows.
        .onChange(of: locationAccess.status) {
            currentNetwork = readNetworkName()
        }
    }

    // MARK: - When

    @ViewBuilder
    private var whenRows: some View {
        GridRow {
            Text(Texts.when)
                .gridColumnAlignment(.trailing)
            Picker(Texts.when, selection: Binding(get: { draft.when }, set: { choose($0) })) {
                whenOptions(Self.moments)
                Divider()
                whenOptions(Self.displayChanges)
                Divider()
                whenOptions(Self.networkChanges)
            }
            .labelsHidden()
            .fixedSize()
        }
        switch draft.change {
        case .displayConnects?, .displayDisconnects?:
            displayRow
        case .displaysConnected?, .displaysDisconnected?:
            displaysRow
        case .wifiJoins?, .wifiLeaves?:
            wifiRow
        case .ethernetConnects?, .ethernetDisconnects?, nil:
            EmptyView()
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

    /// The When pop-up's three parts, in `TriggerDraft.When.offered`'s order.
    private static let moments = TriggerDraft.When.offered.filter { $0.change == nil }
    private static let displayChanges = TriggerDraft.When.offered.filter { $0.change?.isAboutDisplays == true }
    private static let networkChanges = TriggerDraft.When.offered.filter { $0.change?.isAboutDisplays == false }

    private func whenOptions(_ options: [TriggerDraft.When]) -> some View {
        ForEach(options, id: \.self) { when in
            Text(Self.title(of: when)).tag(when)
        }
    }

    /// Picks an event; These Displays starts with the displays connected now, a Wi-Fi network looks
    /// at Location access (it never asks: only Allow… does).
    private func choose(_ when: TriggerDraft.When) {
        draft.setWhen(when)
        if case .change(let change) = when, change == .displaysConnected || change == .displaysDisconnected, draft.displays.isEmpty {
            draft.useDisplays(connected)
        }
        lookAtNetwork()
    }

    private func lookAtNetwork() {
        guard draft.change?.needsLocation == true else { return }
        locationAccess.refresh()
        currentNetwork = readNetworkName()
    }

    // MARK: - Wi-Fi

    private var wifiRow: some View {
        GridRow {
            Text(Texts.networkName)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField(Texts.networkName, text: $draft.wifiName, prompt: Text(Texts.networkName))
                        .labelsHidden()
                        .frame(width: 220)
                    Button(Texts.useCurrentNetwork) {
                        if let currentNetwork { draft.wifiName = currentNetwork }
                    }
                    .disabled(currentNetwork == nil)
                }
                if !draft.wifiName.isEmpty, !draft.isWiFiNameValid {
                    Text(Texts.invalidNetworkName)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(Texts.networkNameHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if draft.change == .wifiLeaves {
                    Text(Texts.leavesHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Whether the app may see network names, with the way to change it: Allow… (the only place
    /// the app asks), or Open Privacy Settings… after a refusal.
    @ViewBuilder
    private var locationNote: some View {
        switch locationAccess.status {
        case .allowed:
            Label(Texts.locationAllowed, systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .notDetermined:
            locationPrompt(Texts.locationNeeded, button: Texts.allowLocation, action: locationAccess.request)
        case .denied:
            locationPrompt(Texts.locationDenied(AppInfo.name), button: Texts.openPrivacySettings, action: locationAccess.openPrivacySettings)
        case .servicesOff:
            locationPrompt(Texts.locationServicesOff, button: Texts.openPrivacySettings, action: locationAccess.openPrivacySettings)
        case .restricted:
            locationPrompt(Texts.locationRestricted, button: nil, action: nil)
        }
    }

    private func locationPrompt(_ text: String, button: String?, action: (() -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Label(text, systemImage: "location.circle")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if let button, let action {
                    Button(button, action: action)
                }
            }
            Text(Texts.waitsForLocation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Displays

    private var displayOptions: [DisplayChoices.Option] {
        DisplayChoices.options(connected: connected, saved: draft.display)
    }

    private var displayRow: some View {
        GridRow {
            Text(Texts.display)
            Picker(Texts.display, selection: Binding(
                get: { DisplayChoices.selection(for: draft.display, in: displayOptions) },
                set: { draft.display = $0 }
            )) {
                ForEach(displayOptions, id: \.self) { option in
                    Text(Self.title(of: option)).tag(option.match)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private var displaysRow: some View {
        GridRow {
            Text(Texts.displays)
            VStack(alignment: .leading, spacing: 6) {
                if draft.displays.isEmpty {
                    Text(Texts.noDisplays)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(draft.displays.enumerated()), id: \.offset) { _, display in
                    Label(Self.displayTitle(display, isConnected: DisplayChoices.isConnected(display, in: connected)), systemImage: display.isBuiltIn ? "laptopcomputer" : "display")
                }
                Button(Texts.useCurrentDisplays) { draft.useDisplays(connected) }
                    .disabled(connected.isEmpty)
                Text(Texts.displaysHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func title(of option: DisplayChoices.Option) -> String {
        switch option.match {
        case .anyExternal: return Texts.anyExternalDisplay
        case .display(let identity): return displayTitle(identity, isConnected: option.isConnected)
        }
    }

    static func displayTitle(_ display: DisplayIdentity, isConnected: Bool) -> String {
        let name = display.name.isEmpty ? Texts.unnamedDisplay : display.name
        return isConnected ? name : Texts.notConnected(name)
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
                if draft.canFinishWhenEventEnds {
                    Toggle(Texts.finishWhenEnds, isOn: $draft.finishesWhenEventEnds)
                    if draft.finishesWhenEventEnds {
                        Text(Texts.finishWhenEndsHint(group.name))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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

    /// No day chosen; how late a missed time runs; Open at Login for At Login; Location access for a
    /// Wi-Fi network; what counts as Ethernet; why it wasn't saved.
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
        if draft.change?.needsLocation == true {
            locationNote
        }
        if draft.change == .ethernetConnects || draft.change == .ethernetDisconnects {
            Text(Texts.ethernetHint)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

    static func title(of when: TriggerDraft.When) -> String {
        switch when {
        case .moment(let kind): return title(of: kind)
        case .change(.displayConnects): return Texts.whenDisplayConnects
        case .change(.displayDisconnects): return Texts.whenDisplayDisconnects
        case .change(.displaysConnected): return Texts.whenDisplaysConnected
        case .change(.displaysDisconnected): return Texts.whenDisplaysDisconnected
        case .change(.wifiJoins): return Texts.whenWiFiJoins
        case .change(.wifiLeaves): return Texts.whenWiFiLeaves
        case .change(.ethernetConnects): return Texts.whenEthernetConnects
        case .change(.ethernetDisconnects): return Texts.whenEthernetDisconnects
        }
    }

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
