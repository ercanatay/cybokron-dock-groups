import AppKit
import DockGroupsCore
import SwiftUI

/// Settings of one group: name, emoji, member apps, Dock tile, standalone Dock icon and popup
/// preferences. Every change goes straight to the store, which saves it.
struct GroupDetailView: View {
    @ObservedObject var store: GroupStore
    @ObservedObject var standalone: StandaloneController
    let group: DockGroup
    let tiles: TileImageCache
    let actions: MainWindowView.Actions

    @State private var nameDraft: String
    @State private var emojiDraft: String
    @FocusState private var focusedField: Field?
    @State private var addAppsProblem: String?
    @State private var isAddingWebsite = false

    private enum Field: Hashable {
        case name, emoji
    }

    init(store: GroupStore, standalone: StandaloneController, group: DockGroup, tiles: TileImageCache, actions: MainWindowView.Actions) {
        self.store = store
        self.standalone = standalone
        self.group = group
        self.tiles = tiles
        self.actions = actions
        _nameDraft = State(initialValue: group.name)
        _emojiDraft = State(initialValue: group.emoji)
    }

    var body: some View {
        Form {
            identitySection
            appsSection
            tileSection
            standaloneSection
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
        .sheet(isPresented: $isAddingWebsite) {
            AddWebsiteView(
                groupName: storedGroup.name,
                add: { website in store.addApps([website], toGroup: group.id) > 0 },
                dismiss: { isAddingWebsite = false }
            )
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
                Text("No apps yet. Use “Add Apps…” to choose apps for this group, or “Add Website…” for a web link.")
                    .foregroundStyle(.secondary)
            } else {
                let moveTargets = GroupMoveTarget.targets(in: store.groups, excluding: group.id)
                ForEach(group.apps) { app in
                    AppRowView(app: app) {
                        store.removeApp(bundleIdentifier: app.bundleIdentifier, fromGroup: group.id)
                    }
                    .modifier(MoveToGroupContextMenu(targets: moveTargets) { destination in
                        store.moveApp(bundleIdentifier: app.bundleIdentifier, fromGroup: group.id, toGroup: destination)
                    })
                    // Dropped on another group in the sidebar, the app moves there.
                    .onDrag {
                        GroupAppDrag(groupID: group.id, bundleIdentifier: app.bundleIdentifier).itemProvider()
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
                Button("Add Website…") { isAddingWebsite = true }
                    .help("Add a web link to this group. It opens in your default browser.")
                Button("Sort A→Z") { store.sortAppsByName(inGroup: group.id) }
                    .disabled(group.apps.count < 2)
                    .help("Sort the apps in this group by name, A to Z. Drag them to reorder by hand.")
                Button("Show Popup") { actions.showPopup(group) }
                    .help("Show this group's popup over the Dock.")
                Button("Open All") { actions.openAll(group) }
                    .disabled(group.apps.isEmpty)
                Button("Hide All") { actions.hideAll(group) }
                    .disabled(group.apps.isEmpty)
                    .help("Hide this group's running apps. Apps that aren't running stay closed.")
            }
        } footer: {
            if !group.apps.isEmpty, store.groups.count > 1 {
                Text("To move an app to another group, drag it onto that group in the sidebar, or use Move to in its context menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var tileSection: some View {
        Section("Dock Tile") {
            LabeledContent("Preview") {
                HStack(alignment: .bottom, spacing: 14) {
                    tilePreview(pointSize: 64)
                    tilePreview(pointSize: 32)
                    tilePreview(pointSize: StatusBarController.menuTileSize)
                }
            }
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

    private var standaloneSection: some View {
        let status = standalone.status(for: group.id)
        return Section {
            Toggle("Standalone Dock icon", isOn: standaloneBinding)
                .disabled(status == .working)
                .help("Give this group its own app, with its own icon in the Dock.")
            switch status {
            case .working:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(group.isStandalone ? "Setting up the Dock icon…" : "Removing the Dock icon…")
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            case nil:
                if group.isStandalone, standalone.agentURL(for: group.id) != nil {
                    LabeledContent("Group App") {
                        Button("Show in Finder") { standalone.revealAgent(for: group.id) }
                    }
                    if standalone.staleDockIcons.contains(group.id) {
                        LabeledContent {
                            Button("Update Dock Icon") { standalone.refreshDockIcons() }
                                .help("Restart the Dock with a fresh icon cache, so the tile shows the group's current icon.")
                        } label: {
                            Text("The Dock still shows the previous icon.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Standalone")
        } footer: {
            Text("Gives the group its own small app, with the tile above as its icon, at the end of the Dock. Clicking it shows the group's popup (⌥-click opens all of its apps), even while Cybokron Dock Groups isn't running; right-clicking it lists the group's apps (Settings → Popup). Turning this off, deleting the group or dragging the icon out of the Dock removes that app. Adding or removing the icon restarts the Dock for a moment.")
                .font(.caption)
                .foregroundStyle(.secondary)
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

    private func tilePreview(pointSize: CGFloat) -> some View {
        Image(nsImage: tiles.image(for: group, pointSize: pointSize))
            .resizable()
            .interpolation(.high)
            .frame(width: pointSize, height: pointSize)
            .accessibilityLabel("Tile preview, \(Int(pointSize)) points")
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

    private var standaloneBinding: Binding<Bool> {
        let id = group.id
        return Binding(
            get: { store.group(withID: id)?.isStandalone ?? false },
            set: { isOn in standalone.setStandalone(isOn, for: id) }
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
