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
            L10n.GroupWindow.addAppsProblemTitle,
            isPresented: Binding(
                get: { addAppsProblem != nil },
                set: { isPresented in if !isPresented { addAppsProblem = nil } }
            )
        ) {
            Button(L10n.Common.ok) { addAppsProblem = nil }
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
        Section(L10n.GroupWindow.groupSection) {
            TextField(L10n.GroupWindow.name, text: $nameDraft)
                .focused($focusedField, equals: .name)
                .onSubmit { nameDraft = storedGroup.name }
            LabeledContent(L10n.GroupWindow.emoji) {
                HStack {
                    TextField(L10n.GroupWindow.emoji, text: $emojiDraft)
                        .labelsHidden()
                        .multilineTextAlignment(.center)
                        .frame(width: 56)
                        .focused($focusedField, equals: .emoji)
                    Button(L10n.GroupWindow.chooseEmoji, action: showCharacterPalette)
                }
            }
        }
    }

    private var appsSection: some View {
        Section {
            if group.apps.isEmpty {
                Text(L10n.GroupWindow.noApps(addApps: L10n.Common.addApps, addWebsite: L10n.Common.addWebsite))
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
                Text(L10n.GroupWindow.appsSection)
                Spacer()
                Button(L10n.Common.addApps, action: addApps)
                Button(L10n.Common.addWebsite) { isAddingWebsite = true }
                    .help(L10n.GroupWindow.addWebsiteHelp)
                Button(L10n.GroupWindow.sortAZ) { store.sortAppsByName(inGroup: group.id) }
                    .disabled(group.apps.count < 2)
                    .help(L10n.GroupWindow.sortAZHelp)
                Button(L10n.GroupWindow.showPopup) { actions.showPopup(group) }
                    .help(L10n.GroupWindow.showPopupHelp)
                Button(L10n.Common.openAll) { actions.openAll(group) }
                    .disabled(group.apps.isEmpty)
                Button(L10n.Common.hideAll) { actions.hideAll(group) }
                    .disabled(group.apps.isEmpty)
                    .help(L10n.GroupWindow.hideAllHelp)
            }
        } footer: {
            if !group.apps.isEmpty, store.groups.count > 1 {
                Text(L10n.GroupWindow.moveHint(moveTo: L10n.Common.moveTo))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var tileSection: some View {
        Section(L10n.GroupWindow.dockTileSection) {
            LabeledContent(L10n.GroupWindow.preview) {
                HStack(alignment: .bottom, spacing: 14) {
                    tilePreview(pointSize: 64)
                    tilePreview(pointSize: 32)
                    tilePreview(pointSize: StatusBarController.menuTileSize)
                }
            }
            Picker(L10n.GroupWindow.shows, selection: binding(\.tile.kind)) {
                Text(L10n.GroupWindow.emoji).tag(TileKind.emoji)
                Text(L10n.GroupWindow.appIconGrid).tag(TileKind.grid)
            }
            .pickerStyle(.segmented)
            Picker(L10n.GroupWindow.background, selection: binding(\.tile.backgroundStyle)) {
                ForEach(TileBackgroundStyle.allCases, id: \.self) { style in
                    Text(style.title).tag(style)
                }
            }
            ColorPicker(L10n.GroupWindow.backgroundColor, selection: backgroundColorBinding, supportsOpacity: false)
            Toggle(L10n.GroupWindow.keepPinned, isOn: binding(\.isPinned))
        }
    }

    private var standaloneSection: some View {
        let status = standalone.status(for: group.id)
        return Section {
            Toggle(L10n.GroupWindow.standaloneToggle, isOn: standaloneBinding)
                .disabled(status == .working)
                .help(L10n.GroupWindow.standaloneHelp)
            switch status {
            case .working:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(group.isStandalone ? L10n.GroupWindow.settingUpDockIcon : L10n.GroupWindow.removingDockIcon)
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            case nil:
                if group.isStandalone, standalone.agentURL(for: group.id) != nil {
                    LabeledContent(L10n.GroupWindow.groupApp) {
                        Button(L10n.Common.showInFinder) { standalone.revealAgent(for: group.id) }
                    }
                    if standalone.staleDockIcons.contains(group.id) {
                        LabeledContent {
                            Button(L10n.GroupWindow.updateDockIcon) { standalone.refreshDockIcons() }
                                .help(L10n.GroupWindow.updateDockIconHelp)
                        } label: {
                            Text(L10n.GroupWindow.staleDockIcon)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text(L10n.GroupWindow.standaloneSection)
        } footer: {
            Text(L10n.GroupWindow.standaloneFooter(AppInfo.name))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var popupSection: some View {
        Section {
            Picker(L10n.GroupWindow.columns, selection: binding(\.popup.columns)) {
                Text(L10n.Common.defaultOption).tag(PopupColumns?.none)
                Text(L10n.Common.auto).tag(PopupColumns?.some(.auto))
                ForEach(Array(PopupOverrides.allowedCountRange), id: \.self) { count in
                    Text(verbatim: "\(count)").tag(PopupColumns?.some(.fixed(count)))
                }
            }
            Picker(L10n.GroupWindow.maximumRows, selection: binding(\.popup.maxRows)) {
                Text(L10n.Common.defaultOption).tag(Int?.none)
                ForEach(Array(PopupOverrides.allowedCountRange), id: \.self) { count in
                    Text(verbatim: "\(count)").tag(Int?.some(count))
                }
            }
            Picker(L10n.GroupWindow.appNames, selection: binding(\.popup.showsTitles)) {
                Text(L10n.Common.defaultOption).tag(Bool?.none)
                Text(L10n.GroupWindow.show).tag(Bool?.some(true))
                Text(L10n.GroupWindow.hide).tag(Bool?.some(false))
            }
            Picker(L10n.GroupWindow.position, selection: binding(\.popup.anchor)) {
                Text(L10n.Common.defaultOption).tag(PopupAnchor?.none)
                ForEach(PopupAnchor.allCases, id: \.self) { anchor in
                    Text(anchor.title).tag(PopupAnchor?.some(anchor))
                }
            }
        } header: {
            Text(L10n.GroupWindow.popupSection)
        } footer: {
            Text(L10n.GroupWindow.popupFooter(defaultOption: L10n.Common.defaultOption))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func tilePreview(pointSize: CGFloat) -> some View {
        Image(nsImage: tiles.image(for: group, pointSize: pointSize))
            .resizable()
            .interpolation(.high)
            .frame(width: pointSize, height: pointSize)
            .accessibilityLabel(L10n.GroupWindow.tilePreviewAccessibility(points: Int(pointSize)))
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
