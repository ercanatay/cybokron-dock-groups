import AppKit
import DockGroupsCore
import SwiftUI

/// Settings of one group: name, emoji, member items (apps, files, folders and websites), what
/// Start and Finish do, its keyboard shortcut, Dock tile, standalone Dock icon and popup
/// preferences. Every change goes straight to the store, which saves it.
///
/// Where the items are is checked when the group shows, when its items change, when the window
/// comes to the front (`GroupWindowItems`) and when a volume is connected or ejected — never while
/// the rows draw.
///
/// An item's alias, tags, task notes and launch options (a delay; the app that opens a file,
/// folder or website) are edited in the details editor, opened from its row's ⓘ button or Edit
/// Details… (a popover) or from the popup's Edit Details… (a sheet). The editor saves once, when it
/// closes, so a standalone group's app is rebuilt once per edit at most. Its "Open with" → Other…
/// moves it to a sheet first: the open panel would close the row's popover. What
/// the popup asks the window to do — that, or the open panel of Add Apps… or Add Files or
/// Folders… — arrives as `GroupWindowSelection.request`.
struct GroupDetailView: View {
    @ObservedObject var store: GroupStore
    @ObservedObject var standalone: StandaloneController
    /// The current group, for the Start and Finish section.
    @ObservedObject var session: ContextSession
    /// The group shortcuts' statuses and recording, for the Keyboard Shortcut section.
    let shortcuts: GlobalShortcutMonitor
    let group: DockGroup
    let tiles: TileImageCache
    let actions: MainWindowView.Actions
    let items: GroupWindowItems
    @ObservedObject var selection: GroupWindowSelection
    @ObservedObject private var presence: ItemPresenceCache

    @State private var nameDraft: String
    @State private var emojiDraft: String
    @FocusState private var focusedField: Field?
    @State private var problem: ShownProblem?
    @State private var isAddingWebsite = false
    /// The item whose details editor is open, `nil` while none is.
    @State private var editing: DetailsEditing?

    private enum Field: Hashable {
        case name, emoji
    }

    /// An alert about items that couldn't be added or located.
    private struct ShownProblem {
        let title: String
        let message: String
    }

    /// An open details editor: whose, what's typed and chosen so far, and how it's shown.
    private struct DetailsEditing {
        /// The item as it was when the editor opened.
        let item: GroupItem
        var itemID: String { item.id }
        var itemName: String { item.name }
        var draft: ItemDetailsDraft
        /// In a sheet (opened from the popup, or for Other…) rather than the row's popover.
        var isSheet: Bool
        /// What opening the item opens, for checking the apps that may open it; `nil` for apps.
        let target: URL?
        /// The "Open with" menu, built once when the editor opened; `nil` for apps.
        let opening: ItemOpenerMenu?
        /// Why the app chosen with Other… wasn't taken.
        var openerRefusal: ItemOpenerRefusal?
    }

    init(
        store: GroupStore,
        standalone: StandaloneController,
        session: ContextSession,
        shortcuts: GlobalShortcutMonitor,
        group: DockGroup,
        tiles: TileImageCache,
        actions: MainWindowView.Actions,
        items: GroupWindowItems,
        selection: GroupWindowSelection
    ) {
        self.store = store
        self.standalone = standalone
        self.session = session
        self.shortcuts = shortcuts
        self.group = group
        self.tiles = tiles
        self.actions = actions
        self.items = items
        self.selection = selection
        presence = items.presence
        _nameDraft = State(initialValue: group.name)
        _emojiDraft = State(initialValue: group.emoji)
    }

    var body: some View {
        Form {
            identitySection
            itemsSection
            switchingSection
            GroupShortcutSection(store: store, shortcuts: shortcuts, group: group)
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
        .onAppear {
            presence.track(group.apps)
            handleRequest()
        }
        .onChange(of: group.apps) { _, newItems in presence.track(newItems) }
        .onChange(of: selection.request) { handleRequest() }
        // Another group selected, or the window closed, with an editor open: keep what was typed.
        .onDisappear { finishEditing(.dismissed) }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            presence.refresh()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            presence.refresh()
        }
        .alert(
            problem?.title ?? "",
            isPresented: Binding(
                get: { problem != nil },
                set: { isPresented in if !isPresented { problem = nil } }
            )
        ) {
            Button(L10n.Common.ok) { problem = nil }
        } message: {
            Text(problem?.message ?? "")
        }
        .sheet(isPresented: $isAddingWebsite) {
            AddWebsiteView(
                groupName: storedGroup.name,
                add: { website in store.addApps([website], toGroup: group.id) > 0 },
                dismiss: { isAddingWebsite = false }
            )
        }
        .sheet(isPresented: isEditingDetailsInSheet) {
            detailsEditor()
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

    private var itemsSection: some View {
        Section {
            if group.apps.isEmpty {
                Text(L10n.GroupWindow.noItems(add: L10n.GroupWindow.addMenu))
                    .foregroundStyle(.secondary)
            } else {
                let moveTargets = GroupMoveTarget.targets(in: store.groups, excluding: group.id)
                ForEach(group.apps) { item in
                    row(for: item, moveTargets: moveTargets)
                }
                .onMove { source, destination in
                    store.moveApps(inGroup: group.id, fromOffsets: source, toOffset: destination)
                }
            }
        } header: {
            HStack {
                Text(L10n.GroupWindow.itemsSection)
                Spacer()
                Menu(L10n.GroupWindow.addMenu) {
                    Button(L10n.Common.addApps, action: addApps)
                    Button(L10n.Capture.addMenuItem) { actions.capture(.group(group.id)) }
                        .help(L10n.Capture.addMenuHelp)
                    Button(L10n.AddItems.menu, action: addFilesAndFolders)
                    Button(L10n.Common.addWebsite) { isAddingWebsite = true }
                        .help(L10n.GroupWindow.addWebsiteHelp)
                }
                .fixedSize()
                .help(L10n.GroupWindow.addMenuHelp)
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

    /// One item's row: what it is, or what's wrong with it, as last checked.
    private func row(for item: GroupItem, moveTargets: [GroupMoveTarget]) -> some View {
        let checked = presence.presence(of: item)
        let canLocate = item.kind.isFileSystemItem && checked == .missing
        return AppRowView(
            app: item,
            status: ItemRowStatus(item: item, presence: checked),
            // Not checked yet: the icon of its kind (or the one found before), without a look at the disk.
            icon: items.icons.icon(for: item, presence: checked ?? (item.isWebsite ? .online : .unverified)),
            isDimmed: checked.map { !$0.isOpenable } ?? false,
            onRemove: { store.removeApp(bundleIdentifier: item.bundleIdentifier, fromGroup: group.id) },
            onLocate: canLocate ? { locate(item) } : nil,
            launchCaption: ItemLaunchCaption(item: item, isOpenerInstalled: presence.isOpenerInstalled(item)),
            isEditingDetails: isEditingDetailsInPopover(of: item),
            detailsEditor: { detailsEditor() }
        )
        .modifier(ItemRowContextMenu(
            item: item,
            presence: checked,
            moveTargets: moveTargets,
            showInFinder: { showInFinder(item) },
            quickLook: { quickLook(item) },
            editDetails: { editDetails(of: item, inSheet: false) },
            locate: { locate(item) },
            move: { destination in
                store.moveApp(bundleIdentifier: item.bundleIdentifier, fromGroup: group.id, toGroup: destination)
            }
        ))
        // Dropped on another group in the sidebar, the item moves there.
        .onDrag {
            GroupAppDrag(groupID: group.id, bundleIdentifier: item.bundleIdentifier).itemProvider()
        }
    }

    /// What Start and Finish do with this group (spec §4.3), and Start (Finish too while it's the
    /// current group). The warning shows only while a setting quits apps.
    private var switchingSection: some View {
        let isCurrent = session.current == group.id
        let current = session.current.flatMap(store.group(withID:))
        let previous = session.previous.flatMap(store.group(withID:))
        let start = SwitchingOffer.start(group, current: current)
        return Section {
            Picker(L10n.Switching.GroupWindow.onStart, selection: binding(\.switching.onStart)) {
                ForEach(GroupSwitching.OnStart.allCases, id: \.self) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            Picker(L10n.Switching.GroupWindow.onFinish, selection: binding(\.switching.onFinish)) {
                ForEach(GroupSwitching.OnFinish.allCases, id: \.self) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            Picker(L10n.Switching.GroupWindow.afterFinish, selection: binding(\.switching.afterFinish)) {
                ForEach([GroupSwitching.AfterFinish.showPreviousGroup, .nothing], id: \.self) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            if group.switching.quitsApps {
                Label(L10n.Switching.GroupWindow.quitWarning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent {
                HStack {
                    Button(L10n.Switching.GroupWindow.protectedApps, action: actions.showProtectedApps)
                        .help(L10n.Switching.GroupWindow.protectedAppsHelp)
                    if isCurrent {
                        let finish = SwitchingOffer.finish(group, previous: previous)
                        Button { actions.finish(group) } label: {
                            Label(finish.title, systemImage: finish.systemImage)
                        }
                        .help(finish.help)
                        .accessibilityLabel(finish.accessibilityLabel)
                    }
                    Button { actions.start(group) } label: {
                        Label(start.title, systemImage: start.systemImage)
                    }
                    .help(start.help)
                    .accessibilityLabel(start.accessibilityLabel)
                }
            } label: {
                Text(isCurrent ? L10n.Switching.GroupWindow.isCurrent : L10n.Switching.GroupWindow.isNotCurrent)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(L10n.Switching.GroupWindow.section)
        } footer: {
            Text(L10n.Switching.GroupWindow.footer)
                .font(.caption)
                .foregroundStyle(.secondary)
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

    // MARK: - Details

    /// Opens the details editor of the item: in its row's popover, or in a sheet.
    private func editDetails(of item: GroupItem, inSheet: Bool) {
        editDetails(ofItemWithID: item.id, inSheet: inSheet)
    }

    private func editDetails(ofItemWithID identity: String, inSheet: Bool) {
        // Another editor still open keeps what was typed in it.
        finishEditing(.dismissed)
        // The details as stored now, which that may just have changed.
        let target = identity.lowercased()
        guard let item = storedGroup.apps.first(where: { $0.normalizedBundleIdentifier == target }) else { return }
        let opened = openedLocation(of: item)
        editing = DetailsEditing(
            item: item,
            draft: ItemDetailsDraft(item),
            isSheet: inSheet,
            target: opened,
            // LaunchServices is asked for the item's apps once, now.
            opening: opened.map { ItemOpenerMenu(for: item, opener: item.launch.opener, target: $0, catalog: items.catalog) }
        )
    }

    /// What opening the item opens, as the apps that may open it are checked against: a file's or
    /// folder's checked location (its own when it couldn't be checked), a website's address; `nil`
    /// for an app.
    private func openedLocation(of item: GroupItem) -> URL? {
        switch item.kind {
        case .application: return nil
        case .website: return item.websiteURL
        case .file, .folder: return presence.presence(of: item)?.location ?? item.fileURL
        }
    }

    /// Closes the open details editor and saves it once (`GroupStore.saveItemEdits`: its details
    /// and its launch options in one change): nothing after Cancel, or when nothing changed.
    /// Closing it again does nothing.
    private func finishEditing(_ ending: ItemDetailsDraft.Ending) {
        guard let closed = editing else { return }
        editing = nil
        store.saveItemEdits(of: closed.draft, endingWith: ending, ofItem: closed.itemID, inGroup: group.id)
    }

    private func detailsEditor() -> some View {
        ItemDetailsEditor(
            itemName: editing?.itemName ?? "",
            draft: Binding(
                get: { editing?.draft ?? ItemDetailsDraft(ItemDetails()) },
                set: { draft in editing?.draft = draft }
            ),
            opening: editing?.opening,
            openerRefusal: editing?.openerRefusal,
            chooseOtherOpener: chooseOtherOpener,
            finish: finishEditing
        )
    }

    /// "Open with" → Other…: an open panel for one app, checked as it will be when the item opens
    /// (`ItemOpenerMenu.check`); a refused app isn't set, and the editor says why. The row's
    /// popover would close under the panel, so the editor moves to a sheet first, keeping what was
    /// typed.
    private func chooseOtherOpener() {
        guard var current = editing, let target = current.target else { return }
        current.isSheet = true
        current.openerRefusal = nil
        editing = current
        let item = current.item
        DispatchQueue.main.async {
            AppPicker.chooseApps(
                title: L10n.Launch.pickerTitle,
                message: L10n.Launch.pickerMessage(item.displayName),
                prompt: L10n.Launch.pickerPrompt,
                allowsMultipleSelection: false,
                attachedTo: nil
            ) { urls in
                guard let url = urls.first, editing?.itemID == item.id else { return }
                switch ItemOpenerMenu.check(url, for: item, target: target, catalog: items.catalog) {
                case .success(let opener):
                    editing?.draft.opener = opener
                    editing?.openerRefusal = nil
                case .failure(let refusal):
                    editing?.openerRefusal = refusal
                }
            }
        }
    }

    /// Whether `item`'s row shows the editor in its popover; closing the popover another way than
    /// with Done or Cancel (a click elsewhere) keeps what was typed.
    private func isEditingDetailsInPopover(of item: GroupItem) -> Binding<Bool> {
        Binding(
            get: { editing.map { !$0.isSheet && $0.itemID == item.id } ?? false },
            set: { isShown in
                if isShown {
                    editDetails(of: item, inSheet: false)
                } else if let current = editing, !current.isSheet, current.itemID == item.id {
                    finishEditing(.dismissed)
                }
            }
        )
    }

    private var isEditingDetailsInSheet: Binding<Bool> {
        Binding(
            get: { editing?.isSheet ?? false },
            set: { isShown in
                if !isShown, editing?.isSheet == true { finishEditing(.dismissed) }
            }
        )
    }

    /// Does what the popup asked the window to do in this group, once.
    private func handleRequest() {
        guard let request = selection.request, request.groupID == group.id else { return }
        selection.request = nil
        switch request.action {
        case .editDetails(let itemID):
            editDetails(ofItemWithID: itemID, inSheet: true)
        case .addApps:
            // Once the window that was just asked to come forward is there for the sheet.
            DispatchQueue.main.async { addApps() }
        case .addFilesAndFolders:
            DispatchQueue.main.async { addFilesAndFolders() }
        }
    }

    // MARK: - Actions

    /// The window open panels attach to as sheets: the group window.
    private var parentWindow: NSWindow? {
        items.window ?? NSApp.keyWindow
    }

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
        AppPicker.chooseApps(forGroupNamed: group.name, attachedTo: parentWindow) { urls in
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
            problem = ShownProblem(title: L10n.GroupWindow.addAppsProblemTitle, message: failures.joined(separator: "\n"))
        }
    }

    /// Add Files or Folders…: what can't be added (programs, scripts, …) is listed in one alert.
    private func addFilesAndFolders() {
        let id = group.id
        ItemPicker.chooseFilesAndFolders(forGroupNamed: group.name, attachedTo: parentWindow) { urls in
            ItemAddition.add(urls, toGroup: id, in: store, locator: presence.itemLocator) { problems in
                problem = ShownProblem(title: L10n.AddItems.problemTitle, message: problems.joined(separator: "\n"))
            }
        }
    }

    /// Locate…: points a missing file or folder at where it is now, keeping its details and its
    /// place in the group (and in Free Layout its cell).
    private func locate(_ item: GroupItem) {
        let id = group.id
        ItemPicker.locate(item, attachedTo: parentWindow) { url in
            guard let url else { return }
            let name = FileLocation.defaultName(for: url)
            if let reason = ItemAddition.relinkProblem(for: item, to: url, locator: presence.itemLocator) {
                problem = ShownProblem(title: L10n.Item.locateProblemTitle(name), message: reason)
            } else if !store.relinkItem(item.bundleIdentifier, inGroup: id, to: url) {
                problem = ShownProblem(title: L10n.Item.locateProblemTitle(name), message: L10n.Item.locateDuplicate(name))
            }
        }
    }

    /// Where Show in Finder and Quick Look find the item: checked again now.
    private func shownLocation(of item: GroupItem) -> URL? {
        PopupQuickLook.target(for: item, presence: presence.check(item))
    }

    private func showInFinder(_ item: GroupItem) {
        guard let location = shownLocation(of: item) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([location])
    }

    private func quickLook(_ item: GroupItem) {
        guard let location = shownLocation(of: item) else { return }
        items.showPreview(location)
    }
}
