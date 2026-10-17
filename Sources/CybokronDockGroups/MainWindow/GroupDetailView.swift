import AppKit
import DockGroupsCore
import SwiftUI

/// Settings of one group: name, emoji, member apps, Dock tile and popup preferences.
/// Every change goes straight to the store, which saves it.
struct GroupDetailView: View {
    @ObservedObject var store: GroupStore
    let group: DockGroup
    let openAll: (DockGroup) -> Void

    @State private var nameDraft: String
    @State private var emojiDraft: String
    @FocusState private var focusedField: Field?
    @State private var addAppsProblem: String?

    private enum Field: Hashable {
        case name, emoji
    }

    init(store: GroupStore, group: DockGroup, openAll: @escaping (DockGroup) -> Void) {
        self.store = store
        self.group = group
        self.openAll = openAll
        _nameDraft = State(initialValue: group.name)
        _emojiDraft = State(initialValue: group.emoji)
    }

    var body: some View {
        Form {
            identitySection
            appsSection
            tileSection
            popupSection
        }
        .formStyle(.grouped)
        // Edits apply as you type, so the sidebar and the menu update immediately. A blank name is
        // ignored by the store, and the field shows the stored values again once it loses focus.
        .onChange(of: nameDraft) { _, newValue in
            store.renameGroup(group.id, to: newValue)
        }
        .onChange(of: emojiDraft) { _, newValue in
            commitEmoji(newValue)
        }
        .onChange(of: focusedField) { previous, _ in
            if previous == .name { nameDraft = storedGroup.name }
            if previous == .emoji { emojiDraft = storedGroup.emoji }
        }
        .onChange(of: group.name) { _, newName in
            if focusedField != .name { nameDraft = newName }
        }
        .onChange(of: group.emoji) { _, newEmoji in
            if focusedField != .emoji { emojiDraft = newEmoji }
        }
        .alert(
            "Some apps couldn't be added",
            isPresented: Binding(
                get: { addAppsProblem != nil },
                set: { isPresented in if !isPresented { addAppsProblem = nil } }
            )
        ) {
            Button("OK") { addAppsProblem = nil }
        } message: {
            Text(addAppsProblem ?? "")
        }
    }

    // MARK: - Sections

    private var identitySection: some View {
        Section("Group") {
            TextField("Name", text: $nameDraft)
                .focused($focusedField, equals: .name)
                .onSubmit { nameDraft = storedGroup.name }
            LabeledContent("Emoji") {
                HStack {
                    TextField("Emoji", text: $emojiDraft)
                        .labelsHidden()
                        .multilineTextAlignment(.center)
                        .frame(width: 56)
                        .focused($focusedField, equals: .emoji)
                    Button("Choose…", action: showCharacterPalette)
                }
            }
        }
    }

    private var appsSection: some View {
        Section {
            if group.apps.isEmpty {
                Text("No apps yet. Use “Add Apps…” to choose apps for this group.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(group.apps) { app in
                    AppRowView(app: app) {
                        store.removeApp(bundleIdentifier: app.bundleIdentifier, fromGroup: group.id)
                    }
                }
                .onMove { source, destination in
                    store.moveApps(inGroup: group.id, fromOffsets: source, toOffset: destination)
                }
            }
        } header: {
            HStack {
                Text("Apps")
                Spacer()
                Button("Add Apps…", action: addApps)
                Button("Open All") { openAll(group) }
                    .disabled(group.apps.isEmpty)
            }
        }
    }

    private var tileSection: some View {
        Section("Dock Tile") {
            Picker("Shows", selection: binding(\.tile.kind)) {
                Text("Emoji").tag(TileKind.emoji)
                Text("App Icon Grid").tag(TileKind.grid)
            }
            .pickerStyle(.segmented)
            Picker("Background", selection: binding(\.tile.backgroundStyle)) {
                ForEach(TileBackgroundStyle.allCases, id: \.self) { style in
                    Text(style.title).tag(style)
                }
            }
            ColorPicker("Background Color", selection: backgroundColorBinding, supportsOpacity: false)
            Toggle("Keep the tile pinned in the Dock", isOn: binding(\.isPinned))
        }
    }

    private var popupSection: some View {
        Section {
            Picker("Columns", selection: binding(\.popup.columns)) {
                Text("Default").tag(PopupColumns?.none)
                Text("Auto").tag(PopupColumns?.some(.auto))
                ForEach(Array(PopupOverrides.allowedCountRange), id: \.self) { count in
                    Text("\(count)").tag(PopupColumns?.some(.fixed(count)))
                }
            }
            Picker("Maximum Rows", selection: binding(\.popup.maxRows)) {
                Text("Default").tag(Int?.none)
                ForEach(Array(PopupOverrides.allowedCountRange), id: \.self) { count in
                    Text("\(count)").tag(Int?.some(count))
                }
            }
            Picker("App Names", selection: binding(\.popup.showsTitles)) {
                Text("Default").tag(Bool?.none)
                Text("Show").tag(Bool?.some(true))
                Text("Hide").tag(Bool?.some(false))
            }
            Picker("Position", selection: binding(\.popup.anchor)) {
                Text("Default").tag(PopupAnchor?.none)
                ForEach(PopupAnchor.allCases, id: \.self) { anchor in
                    Text(anchor.title).tag(PopupAnchor?.some(anchor))
                }
            }
        } header: {
            Text("Popup")
        } footer: {
            Text("“Default” follows the app-wide popup settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Bindings

    private func binding<Value>(_ keyPath: WritableKeyPath<DockGroup, Value>) -> Binding<Value> {
        let id = group.id
        let fallback = group[keyPath: keyPath]
        return Binding(
            get: { store.group(withID: id)?[keyPath: keyPath] ?? fallback },
            set: { newValue in store.updateGroup(id) { $0[keyPath: keyPath] = newValue } }
        )
    }

    private var backgroundColorBinding: Binding<Color> {
        let id = group.id
        return Binding(
            get: { (store.group(withID: id)?.tile.backgroundColor ?? group.tile.backgroundColor).color },
            set: { newColor in
                guard let rgb = TileColor(newColor) else { return }
                store.updateGroup(id) { $0.tile.backgroundColor = rgb }
            }
        )
    }

    // MARK: - Actions

    /// The group as currently stored (the `group` snapshot can lag behind within an update).
    private var storedGroup: DockGroup {
        store.group(withID: group.id) ?? group
    }

    /// Keeps the field to a single character: the one typed last replaces the previous emoji.
    private func commitEmoji(_ value: String) {
        guard let emoji = DockGroup.sanitizedEmoji(value) else { return }
        if emoji != value {
            emojiDraft = emoji
        }
        store.updateGroup(group.id) { $0.emoji = emoji }
    }

    private func showCharacterPalette() {
        focusedField = .emoji
        DispatchQueue.main.async {
            NSApp.orderFrontCharacterPalette(nil)
        }
    }

    private func addApps() {
        AppPicker.chooseApps(forGroupNamed: group.name, attachedTo: NSApp.keyWindow) { urls in
            addApps(from: urls)
        }
    }

    private func addApps(from urls: [URL]) {
        guard !urls.isEmpty else { return }

        var apps: [AppReference] = []
        var failures: [String] = []
        for url in urls {
            do {
                apps.append(try AppReference(applicationURL: url))
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        store.addApps(apps, toGroup: group.id)
        if !failures.isEmpty {
            addAppsProblem = failures.joined(separator: "\n")
        }
    }
}
