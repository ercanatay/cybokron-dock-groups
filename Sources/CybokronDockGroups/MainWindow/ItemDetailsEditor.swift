import DockGroupsCore
import SwiftUI

/// The details editor of a group item: its alias, tags and task notes (spec §4.2, option B), and
/// how it opens (context switching spec §4.3): a delay that Open All and Start wait, and for a
/// file, folder or website the app that opens it.
///
/// It edits an `ItemDetailsDraft` only; whoever shows it saves the draft once, when it's closed
/// (`GroupStore.saveItemEdits`): Done (or Return in the alias and tags fields) and closing the
/// popover with a click elsewhere keep what was typed and chosen, Cancel (or Escape) keeps the item
/// as it was. The tags typed are shown as they'll be kept, and the task notes count their
/// characters against the limit.
///
/// "Open with" lists the default app, then the apps that may open the item (`ItemOpenerMenu`, built
/// once when the editor opened), then Other…, whose choice is checked as when the item opens; an
/// app that isn't taken, isn't on this Mac or may no longer open the item is explained under the
/// menu.
///
/// A website can open in a browser profile (launch-action-ui-slice.md): a browser on this Mac
/// (the others are shown but can't be chosen) and the profile's name, with where to read it. A name
/// the grammar refuses is explained under the field and Done stays off. Done (or Turn On, for an
/// action that came in with a backup or can't be used) first asks to confirm the action, showing
/// the browser, the profile and the full address; Cancel there changes nothing. While a browser
/// profile is chosen, "Open with" isn't offered: the profile's browser opens the website.
/// "Open in a private window" (launch-action-private-window.md) opens it in the chosen browser's
/// private window instead: the profile field is hidden, and the confirmation names the private
/// window instead of a profile.
///
/// The group window shows it in a popover from a row's ⓘ button and its Edit Details… menu item,
/// and as a sheet when the popup's Edit Details… opens the window on the item.
struct ItemDetailsEditor: View {
    /// The item's own name, for the title.
    let itemName: String
    @Binding var draft: ItemDetailsDraft
    /// The "Open with" menu; `nil` for apps, which only have a delay.
    let opening: ItemOpenerMenu?
    /// Why the app chosen with Other… wasn't taken.
    let openerRefusal: ItemOpenerRefusal?
    /// Other…: an open panel for an app; `nil` where there's none.
    let chooseOtherOpener: (() -> Void)?
    /// The item being edited, for the confirmation's summary.
    let item: GroupItem?
    let finish: (ItemDetailsDraft.Ending) -> Void

    @FocusState private var focusedField: Field?
    /// The action the confirmation asks about, `nil` while it isn't shown.
    @State private var confirming: LaunchActionSummary?

    private enum Field: Hashable {
        case alias, tags, notes, profile
    }

    /// The choices of the "Open with" menu.
    private enum OpenerTag: Hashable {
        case defaultApp
        case app(String)
        case other
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.Details.title(itemName))
                .font(.headline)
                .lineLimit(2)
                .truncationMode(.middle)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 12) {
                GridRow {
                    label(L10n.Details.alias)
                    TextField(L10n.Details.alias, text: $draft.alias, prompt: Text(L10n.Details.aliasPlaceholder))
                        .labelsHidden()
                        .focused($focusedField, equals: .alias)
                        .onSubmit(done)
                }
                GridRow {
                    label(L10n.Details.tags)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(L10n.Details.tags, text: $draft.tagsText, prompt: Text(L10n.Details.tagsPlaceholder))
                            .labelsHidden()
                            .focused($focusedField, equals: .tags)
                            .onSubmit(done)
                        tagsPreview
                        Text(draft.leftOutTagCount > 0 ? L10n.Details.tagsLimit(ItemDetails.maximumTagCount) : L10n.Details.tagsHint)
                            .font(.caption)
                            .foregroundStyle(draft.leftOutTagCount > 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    }
                }
                GridRow(alignment: .top) {
                    label(L10n.Details.notes)
                        .padding(.top, 4)
                    VStack(alignment: .trailing, spacing: 4) {
                        notesEditor
                        Text(L10n.Details.notesCount(draft.notesLength, maximum: ItemDetails.maximumNotesLength))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text(L10n.Details.searchHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .gridCellColumns(2)
                }
                Divider()
                // In the same grid, so its labels line up with the ones above.
                openingRows
            }
            HStack {
                Spacer()
                Button(L10n.Common.cancel) { finish(.cancel) }
                    .keyboardShortcut(.cancelAction)
                // Return in the task notes starts a new line; in the other fields it means Done.
                Button(L10n.Common.done, action: done)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.canFinish)
            }
        }
        .padding(16)
        .frame(width: 400)
        .onAppear { focusedField = .alias }
        .alert(
            confirming?.title ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            presenting: confirming
        ) { summary in
            Button(L10n.BrowserProfile.turnOn) { turnOn(summary) }
            Button(L10n.Common.cancel, role: .cancel) { confirming = nil }
        } message: { summary in
            Text(verbatim: summary.details)
        }
    }

    /// Done: asks first when a browser profile would be set or changed; otherwise closes.
    private func done() {
        guard draft.canFinish else { return }
        if let action = draft.launchActionAwaitingConfirmation {
            confirm(action)
        } else {
            finish(.done)
        }
    }

    /// Shows the confirmation of `action`.
    private func confirm(_ action: LaunchAction) {
        guard let item, let summary = LaunchActionSummary(action, for: item) else { return }
        confirming = summary
    }

    /// The confirmation's Turn On: the action is set and on, and the editor closes, saving.
    private func turnOn(_ summary: LaunchActionSummary) {
        confirming = nil
        guard let action = draft.chosenLaunchAction, action == summary.action else { return }
        draft.confirmLaunchAction(action)
        finish(.done)
    }

    // MARK: - Opening

    /// "Opening": the app that opens a file, folder or website, and the delay of every item.
    @ViewBuilder
    private var openingRows: some View {
        GridRow {
            Text(L10n.Launch.section)
                .font(.subheadline.weight(.semibold))
                .gridCellColumns(2)
        }
        if draft.offersOpener, draft.browser == nil, let opening {
            GridRow {
                label(L10n.Launch.openWith)
                VStack(alignment: .leading, spacing: 4) {
                    openerPicker(opening)
                    if let note = openerNote(opening) {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        if draft.offersBrowserProfile {
            browserProfileRows
        }
        GridRow {
            label(L10n.Launch.delay)
            VStack(alignment: .leading, spacing: 4) {
                Picker(L10n.Launch.delay, selection: $draft.delay) {
                    ForEach(draft.delayChoices, id: \.self) { seconds in
                        Text(L10n.Launch.delayTitle(seconds)).tag(seconds)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Text(L10n.Launch.delayHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Browser profile

    /// A website's browser profile: on or off, the browser, a private window or the profile's name,
    /// where to find the name, why a name can't be used, and Turn On for an action that needs review.
    @ViewBuilder
    private var browserProfileRows: some View {
        GridRow {
            Toggle(L10n.BrowserProfile.toggle, isOn: Binding(
                get: { draft.browser != nil },
                set: { draft.setBrowserProfileOn($0) }
            ))
            .disabled(!draft.canTurnOnBrowserProfile)
            .gridCellColumns(2)
        }
        if draft.launchActionNeedsReview {
            GridRow {
                VStack(alignment: .leading, spacing: 6) {
                    Label(draft.isApprovalMissing ? L10n.BrowserProfile.approvalMissing : L10n.BrowserProfile.review, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    if let action = draft.launchActionToTurnOn {
                        Button(L10n.BrowserProfile.turnOn) { confirm(action) }
                            .controlSize(.small)
                    }
                }
                .gridCellColumns(2)
            }
        }
        if let browser = draft.browser {
            GridRow {
                browserPicker(browser)
                    .gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(L10n.BrowserProfile.privateWindow, isOn: $draft.isPrivateWindow)
                    if draft.isPrivateWindow {
                        Text(L10n.BrowserProfile.privateWindowHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        TextField(L10n.BrowserProfile.toggle, text: $draft.profileName, prompt: Text(verbatim: browser.profileNameExample))
                            .labelsHidden()
                            .focused($focusedField, equals: .profile)
                            .onSubmit(done)
                        Text(draft.isProfileNameAccepted ? L10n.BrowserProfile.hint : L10n.BrowserProfile.invalidName)
                            .font(.caption)
                            .foregroundStyle(draft.isProfileNameAccepted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// Chrome, Edge, Brave and Firefox; one that isn't on this Mac is shown but can't be chosen.
    private func browserPicker(_ browser: BrowserFamily) -> some View {
        Picker(L10n.BrowserProfile.toggle, selection: Binding(
            get: { browser },
            set: { draft.chooseBrowser($0) }
        )) {
            ForEach(BrowserFamily.allCases, id: \.self) { family in
                Text(draft.canChoose(family) ? family.name : L10n.Launch.notOnThisMac(family.name))
                    .tag(family)
                    .selectionDisabled(!draft.canChoose(family))
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    private func openerPicker(_ opening: ItemOpenerMenu) -> some View {
        let selection = Binding<OpenerTag>(
            get: { draft.opener.map { .app($0.normalizedBundleIdentifier) } ?? .defaultApp },
            set: { tag in
                switch tag {
                case .defaultApp:
                    draft.opener = nil
                case .app(let identifier):
                    if let choice = opening.choices.first(where: { $0.id == identifier }) {
                        draft.opener = choice.opener
                    }
                case .other:
                    chooseOtherOpener?()
                }
            }
        )
        return Picker(L10n.Launch.openWith, selection: selection) {
            Text(opening.defaultAppName.map(L10n.Launch.defaultApp(named:)) ?? L10n.Launch.defaultApp).tag(OpenerTag.defaultApp)
            if !opening.choices.isEmpty {
                Divider()
                ForEach(opening.choices) { choice in
                    Text(choice.opener.name).tag(OpenerTag.app(choice.id))
                }
            }
            // The app chosen before, when the menu doesn't offer it (not on this Mac, or refused).
            if let chosen = draft.opener, opening.choice(for: chosen) == nil {
                Divider()
                Text(title(ofUnofferedOpener: chosen, in: opening)).tag(OpenerTag.app(chosen.normalizedBundleIdentifier))
            }
            if chooseOtherOpener != nil {
                Divider()
                Text(L10n.Launch.other).tag(OpenerTag.other)
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    private func title(ofUnofferedOpener opener: ItemOpener, in opening: ItemOpenerMenu) -> String {
        guard opener == opening.current else { return opener.name }
        switch opening.currentStatus {
        case .notOnThisMac: return L10n.Launch.notOnThisMac(opener.name)
        case .refused: return L10n.Launch.refusedChoice(opener.name)
        case .available, .defaultApp: return opener.name
        }
    }

    /// Why Other…'s app wasn't taken, or what's wrong with the app chosen before.
    private func openerNote(_ opening: ItemOpenerMenu) -> String? {
        if let openerRefusal { return openerRefusal.message }
        guard let chosen = draft.opener, chosen == opening.current else { return nil }
        return opening.currentStatus.message(openerName: chosen.name)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    /// The tags as they'll be kept, while they're typed.
    @ViewBuilder
    private var tagsPreview: some View {
        let tags = draft.tags
        if !tags.isEmpty {
            Text(verbatim: tags.map { "#\($0)" }.joined(separator: "  "))
                .font(.caption)
                .foregroundStyle(.tint)
                .lineLimit(2)
                .accessibilityLabel(L10n.Details.tagsList(tags.joined(separator: ", ")))
        }
    }

    /// Several lines of notes, with the placeholder shown while it's empty.
    private var notesEditor: some View {
        TextEditor(text: $draft.notes)
            .font(.body)
            .scrollContentBackground(.hidden)
            .focused($focusedField, equals: .notes)
            .frame(height: 84)
            .padding(4)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color(nsColor: .separatorColor))
            )
            .overlay(alignment: .topLeading) {
                if draft.notes.isEmpty {
                    Text(L10n.Details.notesPlaceholder)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel(L10n.Details.notes)
    }
}
