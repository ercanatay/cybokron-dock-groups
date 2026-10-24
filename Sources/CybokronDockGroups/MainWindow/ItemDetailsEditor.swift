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
    let finish: (ItemDetailsDraft.Ending) -> Void

    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case alias, tags, notes
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
                        .onSubmit { finish(.done) }
                }
                GridRow {
                    label(L10n.Details.tags)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(L10n.Details.tags, text: $draft.tagsText, prompt: Text(L10n.Details.tagsPlaceholder))
                            .labelsHidden()
                            .focused($focusedField, equals: .tags)
                            .onSubmit { finish(.done) }
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
                Button(L10n.Common.done) { finish(.done) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 400)
        .onAppear { focusedField = .alias }
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
        if draft.offersOpener, let opening {
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
