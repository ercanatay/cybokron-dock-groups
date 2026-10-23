import DockGroupsCore
import SwiftUI

/// The details editor of a group item: its alias, tags and task notes (spec §4.2, option B).
///
/// It edits an `ItemDetailsDraft` only; whoever shows it saves the draft once, when it's closed
/// (`GroupStore.saveDetails`): Done (or Return in the alias and tags fields) and closing the
/// popover with a click elsewhere keep what was typed, Cancel (or Escape) keeps the item as it was.
/// The tags typed are shown as they'll be kept, and the task notes count their characters against
/// the limit.
///
/// The group window shows it in a popover from a row's ⓘ button and its Edit Details… menu item,
/// and as a sheet when the popup's Edit Details… opens the window on the item.
struct ItemDetailsEditor: View {
    /// The item's own name, for the title.
    let itemName: String
    @Binding var draft: ItemDetailsDraft
    let finish: (ItemDetailsDraft.Ending) -> Void

    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case alias, tags, notes
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
