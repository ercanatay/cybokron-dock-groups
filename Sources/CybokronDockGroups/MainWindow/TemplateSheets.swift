import DockGroupsCore
import SwiftUI

/// Save as Template… (spec §1.9): names the template — the group's name to start with — and saves
/// it. A name a template has already asks whether to replace that template; at
/// `GroupTemplate.maximumCount` templates a new one can't be saved, but one can still be replaced.
struct SaveTemplateSheet: View {
    @ObservedObject var templates: TemplateStore
    let store: GroupStore
    let group: DockGroup
    let dismiss: () -> Void

    @State private var name: String
    /// The template of the same name, while the Replace question shows.
    @State private var replacing: GroupTemplate?
    /// The store said the limit was reached (saving raced another change).
    @State private var reachedLimit = false

    private typealias Texts = L10n.Templates

    init(templates: TemplateStore, store: GroupStore, group: DockGroup, dismiss: @escaping () -> Void) {
        self.templates = templates
        self.store = store
        self.group = group
        self.dismiss = dismiss
        _name = State(initialValue: group.name)
    }

    /// A new template can't be saved: replacing one still can.
    private var isAtLimit: Bool {
        (reachedLimit || templates.templates.count >= GroupTemplate.maximumCount) && templates.template(named: name) == nil
    }

    private var canSave: Bool {
        DockGroup.sanitizedName(name) != nil && !isAtLimit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Texts.saveTitle(group.name))
                .font(.headline)
            LabeledContent(Texts.name) {
                TextField(Texts.name, text: $name)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if canSave { save(replacing: false) } }
            }
            Text(Texts.saveMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if isAtLimit {
                Label(Texts.limit(GroupTemplate.maximumCount), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(L10n.Common.cancel, role: .cancel, action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button(Texts.save) { save(replacing: false) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 460)
        .alert(
            Texts.replaceTitle(replacing?.name ?? ""),
            isPresented: Binding(
                get: { replacing != nil },
                set: { isPresented in if !isPresented { replacing = nil } }
            ),
            presenting: replacing
        ) { _ in
            Button(L10n.Common.cancel, role: .cancel) {}
            Button(Texts.replace) { save(replacing: true) }
        } message: { _ in
            Text(Texts.replaceMessage)
        }
    }

    private func save(replacing: Bool) {
        // The group as it is now: the popup may have changed it while the sheet showed.
        let source = store.group(withID: group.id) ?? group
        switch templates.save(source, named: name, replacing: replacing) {
        case .saved:
            dismiss()
        case .nameTaken(let existing):
            self.replacing = existing
        case .limitReached:
            reachedLimit = true
        }
    }
}

/// Manage Templates… (spec §3.5): every template with its emoji, item count and save date, a new
/// group from one, Rename… and Delete…. Only the templates' stored names and counts are shown:
/// nothing of a template's items touches the disk (spec A-2).
struct ManageTemplatesSheet: View {
    @ObservedObject var templates: TemplateStore
    /// Adds a group made from the template; the sheet closes so it shows.
    let onNewGroup: (GroupTemplate) -> Void
    let dismiss: () -> Void

    @State private var selection: GroupTemplate.ID?
    @State private var renameTarget: GroupTemplate?
    @State private var renameText = ""
    @State private var deletionCandidate: GroupTemplate?
    /// Why the last rename didn't happen, shown above the buttons.
    @State private var problem: String?

    private typealias Texts = L10n.Templates

    private var selected: GroupTemplate? {
        selection.flatMap(templates.template(withID:))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Texts.manageTitle)
                .font(.headline)
            if templates.templates.isEmpty {
                Text(Texts.empty)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                List(selection: $selection) {
                    ForEach(templates.templates) { template in
                        row(template)
                            .tag(template.id)
                            .contextMenu {
                                Button(Texts.newGroup) { onNewGroup(template) }
                                Button(L10n.GroupWindow.renameMenu) { beginRename(template) }
                                Divider()
                                Button(L10n.GroupWindow.deleteMenu, role: .destructive) { deletionCandidate = template }
                            }
                    }
                }
                .frame(minHeight: 240)
                .onDeleteCommand {
                    if let selected { deletionCandidate = selected }
                }
            }
            Text(Texts.footer)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(L10n.GroupWindow.renameMenu) {
                    if let selected { beginRename(selected) }
                }
                .disabled(selected == nil)
                Button(L10n.GroupWindow.deleteMenu) {
                    deletionCandidate = selected
                }
                .disabled(selected == nil)
                Spacer()
                Button(L10n.Common.done, action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
        // Escape closes the sheet, as Done does.
        .onExitCommand(perform: dismiss)
        .alert(
            Texts.renameTitle,
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { isPresented in if !isPresented { renameTarget = nil } }
            )
        ) {
            TextField(L10n.GroupWindow.name, text: $renameText)
            Button(L10n.GroupWindow.rename, action: commitRename)
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(Texts.renameMessage)
        }
        .confirmationDialog(
            Texts.deleteTitle(deletionCandidate?.name ?? ""),
            isPresented: Binding(
                get: { deletionCandidate != nil },
                set: { isPresented in if !isPresented { deletionCandidate = nil } }
            ),
            titleVisibility: .visible,
            presenting: deletionCandidate
        ) { template in
            Button(Texts.deleteTemplate, role: .destructive) {
                templates.delete(template.id)
                if selection == template.id { selection = nil }
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: { _ in
            Text(Texts.deleteMessage)
        }
    }

    private func row(_ template: GroupTemplate) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: template.group.emoji)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: template.name)
                    .lineLimit(1)
                Text(summary(of: template))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(Texts.newGroup) { onNewGroup(template) }
                .help(Texts.newGroupHelp(template.name))
        }
        .padding(.vertical, 3)
    }

    private func summary(of template: GroupTemplate) -> String {
        let items = L10n.Common.itemCount(template.group.apps.count)
        guard let savedAt = template.savedAt else { return items }
        return Texts.summary(items: items, saved: savedAt.formatted(date: .long, time: .omitted))
    }

    private func beginRename(_ template: GroupTemplate) {
        problem = nil
        renameText = template.name
        renameTarget = template
    }

    private func commitRename() {
        guard let target = renameTarget else { return }
        renameTarget = nil
        // A blank name changes nothing, as for groups; a name another template has is refused.
        guard let name = DockGroup.sanitizedName(renameText) else { return }
        if !templates.rename(target.id, to: name), let other = templates.template(named: name), other.id != target.id {
            problem = Texts.nameTaken(other.name)
        }
    }
}
