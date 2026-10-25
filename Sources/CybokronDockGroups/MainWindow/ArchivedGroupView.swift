import DockGroupsCore
import SwiftUI

/// What the group window shows for an archived group (spec §3.4): read-only, with Restore and
/// Delete…. Its name, emoji and when it was archived, its items' names and kinds, its shortcut (off),
/// how many triggers it has (they don't run while it's archived) and whether its Dock icon comes back.
///
/// Only what the groups file says is shown: no icon is looked up and no item's location is checked,
/// previewed or shown in Finder (spec A-2), so nothing of an archived group touches the disk.
struct ArchivedGroupView: View {
    let archived: ArchivedGroup
    /// Its triggers, which come back working when it's restored.
    let triggerCount: Int
    let onRestore: () -> Void
    let onDelete: () -> Void

    private typealias Texts = L10n.GroupWindow.Archive

    private var group: DockGroup { archived.group }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: group.emoji)
                        .font(.largeTitle)
                    Text(verbatim: group.name)
                        .font(.title2.weight(.semibold))
                        .lineLimit(2)
                    Spacer(minLength: 12)
                    Text(archivedDate)
                        .foregroundStyle(.secondary)
                }
                Text(Texts.explanation)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                if group.apps.isEmpty {
                    Text(Texts.noItems)
                        .foregroundStyle(.secondary)
                } else {
                    Text(verbatim: group.apps.map(Self.title(of:)).joined(separator: " · "))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            } header: {
                HStack {
                    Text(L10n.GroupWindow.itemsSection)
                    Spacer()
                    Text(L10n.Common.itemCount(group.apps.count))
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent(L10n.GroupWindow.Shortcut.label) {
                    Text(group.shortcut.map { Texts.shortcutOff(KeyNames.title(for: $0.keys)) } ?? Texts.noShortcut)
                }
                if triggerCount > 0 {
                    LabeledContent(L10n.Triggers.GroupWindow.section) {
                        Text(L10n.Triggers.GroupWindow.archivedCount(triggerCount))
                            .multilineTextAlignment(.trailing)
                    }
                }
                if archived.restoresStandalone {
                    LabeledContent(Texts.dockIcon) {
                        Text(Texts.dockIconReturns)
                    }
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button(L10n.GroupWindow.deleteMenu, role: .destructive, action: onDelete)
                    Button(Texts.restore, action: onRestore)
                        .buttonStyle(.borderedProminent)
                        .help(Texts.restoreHelp)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var archivedDate: String {
        archived.archivedAt.map { Texts.archivedOn($0.formatted(date: .long, time: .omitted)) } ?? Texts.archived
    }

    /// The item's name, with its kind for files and folders: "Report.pdf (file)".
    private static func title(of item: GroupItem) -> String {
        switch item.kind {
        case .file: return Texts.file(item.displayName)
        case .folder: return Texts.folder(item.displayName)
        case .application, .website: return item.displayName
        }
    }
}
