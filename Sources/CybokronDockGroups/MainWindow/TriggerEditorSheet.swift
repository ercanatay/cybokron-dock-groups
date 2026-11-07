import AppKit
import DockGroupsCore
import SwiftUI

/// New Trigger / Edit Trigger (triggers spec §3.2): when — a time on chosen days, at login, when
/// the app opens, when the screens wake or sleep, when the screen locks or unlocks (best effort:
/// macOS doesn't document its lock signal, TS-11), when a display (any external one, or a chosen
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
///
/// An application trigger matched by bundle identifier only (unverified: a new one, or one whose
/// app was changed) can only Show the Popup: the other actions are shown disabled with the reason,
/// choosing such an app switches to Show the Popup, and an older trigger with another action can't
/// be saved until Show the Popup is chosen. A trigger waiting for re-approval or with an unreadable
/// approval says so.
///
/// A saved application trigger that is unverified or waits for re-approval, with its app unchanged
/// in the editor, offers Approve This App / Approve the New Version
/// (`TriggerController.approveApplication`): the app's running code is checked (Cancel stops it)
/// and, only when verified, saved as the trigger's approved code right away; the editor then
/// offers every action. A new trigger, or one whose app was changed, is saved first. Approving
/// doesn't turn the trigger on.
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
    /// Approves a saved application trigger's app (`TriggerController.approveApplication`).
    /// An ad-hoc signed app is approved only when the second confirmation it is given answers `true`.
    let approveApplication: (GroupTrigger.ID, @escaping TriggerApplicationApprover.AdHocConfirmation) async -> TriggerApplicationApprovalOutcome
    let dismiss: () -> Void

    @State private var draft: TriggerDraft
    @State private var problem: String?
    @State private var connected: [DisplayIdentity] = []
    @State private var currentNetwork: String?
    /// The trigger being edited as saved now: `existing`, then as an approval saved it.
    @State private var current: GroupTrigger?
    @State private var approval: Task<Void, Never>?
    @State private var isApproving = false
    /// The answer the ad-hoc confirmation waits for; `nil` when none is asked.
    @State private var adHocAnswer: CheckedContinuation<Bool, Never>?
    /// What the last approval said when it didn't approve.
    @State private var approvalMessage: String?

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
        approveApplication: @escaping (GroupTrigger.ID, @escaping TriggerApplicationApprover.AdHocConfirmation) async -> TriggerApplicationApprovalOutcome,
        dismiss: @escaping () -> Void
    ) {
        self.group = group
        self.existing = existing
        self.store = store
        self.loginItem = loginItem
        self.locationAccess = locationAccess
        self.readDisplays = readDisplays
        self.readNetworkName = readNetworkName
        self.approveApplication = approveApplication
        self.dismiss = dismiss
        _current = State(initialValue: existing)
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
                    .disabled(isApproving || !draft.canBeSaved(replacing: current))
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            connected = readDisplays()
            lookAtNetwork()
        }
        .onDisappear {
            approval?.cancel()
            answerAdHoc(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            connected = readDisplays()
        }
        // Allowed (or taken back) meanwhile: Use Current Network follows.
        // The verifier (or an approval) can change the rule while the editor is open: the approval
        // shown follows the stored rule, not the copy the editor opened with. `$triggers` emits
        // before the change lands, so the emitted array (not `store.triggers`) is read.
        .onReceive(store.$triggers) { triggers in
            let refreshed = Self.refreshed(current, from: triggers)
            if refreshed != current { current = refreshed }
        }
        .onChange(of: locationAccess.status) {
            currentNetwork = readNetworkName()
        }
        // Why the last approval didn't approve was about the app chosen then.
        .onChange(of: draft.applicationBundleIdentifier) {
            approvalMessage = nil
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
        if case .application = draft.when {
            appRow
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
        keepActionPermitted()
        if case .change(let change) = when, change == .displaysConnected || change == .displaysDisconnected, draft.displays.isEmpty {
            draft.useDisplays(connected)
        }
        lookAtNetwork()
    }

    /// What the saved trigger's application approval would be (`nil` for other events).
    private var identityState: TriggerApplicationIdentityState? {
        draft.applicationIdentityState(replacing: current)
    }

    /// After a change the user made (another event or app): an unverified application trigger
    /// switches to Show the Popup, the only action it can run.
    private func keepActionPermitted() {
        if !draft.permitsAction(draft.action, replacing: current), draft.permitsAction(.showPopup, replacing: current) {
            draft.setAction(.showPopup)
        }
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

    private var appRow: some View {
        GridRow {
            Text(Texts.applicationLabel)
            HStack {
                Text(draft.applicationBundleIdentifier.isEmpty ? Texts.applicationNone : draft.applicationBundleIdentifier)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(draft.applicationBundleIdentifier.isEmpty ? .secondary : .primary)
                Button(Texts.applicationChoose) {
                    AppPicker.chooseApps(
                        title: Texts.applicationTitle,
                        message: Texts.applicationMessage,
                        prompt: Texts.applicationChoose,
                        allowsMultipleSelection: false,
                        attachedTo: NSApp.keyWindow
                    ) { urls in
                        guard let url = urls.first else { return }
                        if let app = AppPicker.triggerApplication(at: url) {
                            if draft.selectApplication(app) {
                                problem = nil
                                keepActionPermitted()
                            } else {
                                problem = Texts.applicationInvalid
                            }
                        } else {
                            problem = Texts.applicationInvalid
                        }
                    }
                }
                .disabled(isApproving)
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
                Picker(Texts.action, selection: Binding(
                    get: { draft.action },
                    set: { if draft.permitsAction($0, replacing: current) { draft.setAction($0) } }
                )) {
                    ForEach(draft.allowedActions, id: \.self) { action in
                        let permitted = draft.permitsAction(action, replacing: current)
                        Text(permitted ? Self.title(of: action) : L10n.Triggers.Identity.actionNeedsVerifiedApp(Self.title(of: action)))
                            .tag(action)
                            .disabled(!permitted)
                    }
                }
                .labelsHidden()
                .fixedSize()
                identityNote
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

    /// Under the action pop-up of an application trigger: why only Show the Popup can be chosen,
    /// or why the trigger doesn't run and how to use it now.
    @ViewBuilder
    private var identityNote: some View {
        if let state = identityState {
            if state == .unverified {
                Label(L10n.Triggers.Identity.editorOnlyShowPopup, systemImage: TriggerIdentityLabel.symbol(for: state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !state.permits(draft.action) {
                    Text(L10n.Triggers.Identity.editorChooseShowPopup)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                approvalControls(for: state)
            } else if state == .verificationUnavailable {
                // Authorized: approved for an exact version, run while the verifier confirms it.
                Label(L10n.Triggers.Identity.Approve.approved, systemImage: "checkmark.seal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // How the approved code was signed; an ad-hoc signature is a weaker approval.
                let signature = current?.approvedApplicationSignature
                if let text = L10n.Triggers.Identity.Approve.signature(signature) {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(signature?.verifiesDeveloper == false ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Label(L10n.Triggers.Identity.badge(state), systemImage: TriggerIdentityLabel.symbol(for: state))
                        .foregroundStyle(.orange)
                    Text(L10n.Triggers.Identity.detail(state))
                    if approvalTarget == nil {
                        Text(L10n.Triggers.Identity.howToReapprove)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                approvalControls(for: state)
            }
        }
    }

    /// `current` as the stored triggers now have it; kept as it is when the trigger isn't stored
    /// (a new one, or one removed meanwhile).
    static func refreshed(_ current: GroupTrigger?, from triggers: [GroupTrigger]) -> GroupTrigger? {
        guard let current else { return nil }
        return triggers.first { $0.id == current.id } ?? current
    }

    // MARK: - Approving the app

    /// The saved trigger whose app the editor may approve: unverified or waiting for re-approval,
    /// with the app chosen in the editor still its app. `nil` for a new trigger or a changed app.
    private var approvalTarget: GroupTrigger? {
        guard let current, current.canApproveApplication,
              case .applicationPresence(let bundleIdentifier, _) = current.event,
              case .application = draft.when, draft.applicationBundleIdentifier == bundleIdentifier
        else { return nil }
        return current
    }

    /// Approve This App (Approve the New Version for one waiting for re-approval), its hint, the
    /// check under way with Cancel, and why the last approval didn't approve; "save first" for a
    /// new trigger or a changed app.
    @ViewBuilder
    private func approvalControls(for state: TriggerApplicationIdentityState) -> some View {
        if let target = approvalTarget {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Button(state == .needsReapproval ? L10n.Triggers.Identity.Approve.newVersionButton : L10n.Triggers.Identity.Approve.button) {
                        startApproval(of: target)
                    }
                    .disabled(isApproving)
                    if isApproving {
                        ProgressView()
                            .controlSize(.small)
                        Text(L10n.Triggers.Identity.Approve.checking)
                            .foregroundStyle(.secondary)
                        Button(L10n.Common.cancel) { approval?.cancel() }
                    }
                }
                Text(L10n.Triggers.Identity.Approve.hint)
                    .alert(L10n.Triggers.Identity.Approve.adHocTitle, isPresented: adHocPresented) {
                        Button(L10n.Triggers.Identity.Approve.adHocConfirm) { answerAdHoc(true) }
                        Button(L10n.Common.cancel, role: .cancel) { answerAdHoc(false) }
                    } message: {
                        Text(L10n.Triggers.Identity.Approve.adHocMessage)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let approvalMessage {
                    Text(approvalMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if state == .unverified || state == .needsReapproval {
            Text(L10n.Triggers.Identity.Approve.saveFirst)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Checks the app's running code; only a verified one is saved (by the controller). Nothing is
    /// saved when it fails, is cancelled or the app doesn't run.
    private func startApproval(of trigger: GroupTrigger) {
        approval?.cancel()
        approvalMessage = nil
        isApproving = true
        approval = Task { @MainActor in
            let outcome = await approveApplication(trigger.id) { await askAdHoc() }
            isApproving = false
            approval = nil
            switch outcome {
            case .approved:
                current = store.trigger(withID: trigger.id) ?? current
            case .declined:
                break // The user declined the second confirmation: nothing saved, nothing to explain.
            case .notRunning:
                approvalMessage = L10n.Triggers.Identity.Approve.notRunning
            case .failed(let failure):
                approvalMessage = L10n.Triggers.Identity.Approve.failure(failure)
            }
        }
    }

    private var adHocPresented: Binding<Bool> {
        Binding(get: { adHocAnswer != nil }, set: { if !$0 { answerAdHoc(false) } })
    }

    /// Shows the ad-hoc confirmation and waits for the user's answer.
    private func askAdHoc() async -> Bool {
        answerAdHoc(false)
        return await withCheckedContinuation { adHocAnswer = $0 }
    }

    private func answerAdHoc(_ approved: Bool) {
        let waiting = adHocAnswer
        adHocAnswer = nil
        waiting?.resume(returning: approved)
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
        if draft.kind == .screenLocks || draft.kind == .screenUnlocks {
            Text(Texts.screenLockNote)
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
        if draft.kind == .screenLocks { return Texts.lockHint }
        switch draft.action {
        case .start: return Texts.startHint(group.name)
        case .finish: return Texts.finishHint(group.name)
        case .openAll, .showPopup: return nil
        }
    }

    // MARK: - Saving

    private func save() {
        guard !isApproving else { return }
        // As saved now: an approval or a re-approval the verifier saved meanwhile is kept as it is.
        let saved = current.flatMap { store.trigger(withID: $0.id) } ?? current
        guard draft.canBeSaved(replacing: saved) else { return }
        let trigger = draft.trigger(groupID: group.id, replacing: saved)
        if saved != nil {
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
        case .application(.starts): return Texts.applicationOpens
        case .application(.ends): return Texts.applicationCloses
        }
    }

    static func title(of kind: TriggerDraft.Kind) -> String {
        switch kind {
        case .time: return Texts.atATime
        case .login: return Texts.atLogin
        case .appOpens: return Texts.whenAppOpens(AppInfo.name)
        case .screensWake: return Texts.whenScreensWake
        case .screensSleep: return Texts.whenScreensSleep
        case .screenLocks: return Texts.whenScreenLocks
        case .screenUnlocks: return Texts.whenScreenUnlocks
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
