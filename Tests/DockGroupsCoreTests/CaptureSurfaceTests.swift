import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Capture: the sheet's selection")
struct CaptureSelectionTests {
    private func plan(_ apps: [OpenApp], targetItems: [GroupItem] = [], protectedApps: ProtectedApps = ProtectedApps()) -> CapturePlan {
        CapturePlanner.plan(
            OpenAppsSnapshot(apps: apps, windows: nil),
            settings: CaptureSettings(order: .name),
            target: targetItems.isEmpty ? .newGroup : .group(UUID()),
            targetItems: targetItems,
            protectedApps: protectedApps
        )
    }

    @Test func itStartsAsThePlansFirstSelection() {
        let protected = ProtectedApps([AppReference(bundleIdentifier: "com.apple.mail", name: "Mail")])
        let plan = plan([CaptureApps.xcode, CaptureApps.mail, CaptureApps.safari], protectedApps: protected)
        let selection = CaptureSelection(plan: plan)
        #expect(selection.ids == Set(plan.defaultSelection))
        #expect(selection.ids == ["com.apple.dt.xcode", "com.apple.safari"])
        #expect(selection.items(in: plan).map(\.name) == ["Safari", "Xcode"])
    }

    @Test func aProtectedAppCanBeChosenAndAnAppInTheGroupCant() throws {
        let plan = plan(
            [CaptureApps.xcode, CaptureApps.mail, CaptureApps.safari],
            targetItems: [AppReference(bundleIdentifier: "com.apple.Safari", name: "Safari")],
            protectedApps: ProtectedApps([AppReference(bundleIdentifier: "com.apple.mail", name: "Mail")])
        )
        var selection = CaptureSelection(plan: plan)
        let mail = try #require(plan.candidates.first { $0.id == "com.apple.mail" })
        let safari = try #require(plan.candidates.first { $0.id == "com.apple.safari" })

        #expect(selection.canToggle(mail))
        let selectedMail = selection.set(mail, selected: true)
        #expect(selectedMail && selection.isSelected(mail))
        #expect(!selection.canToggle(safari))
        let selectedSafari = selection.set(safari, selected: true)
        #expect(!selectedSafari && !selection.isSelected(safari))
        let selectedAgain = selection.set(mail, selected: true)
        #expect(!selectedAgain, "already selected")
        let deselected = selection.set(mail, selected: false)
        #expect(deselected)
        #expect(selection.items(in: plan).map(\.name) == ["Xcode"])
    }

    @Test func noMoreThanFiftyCanBeSelected() throws {
        let apps = (0..<55).map { CaptureApps.app("com.example.app\($0)", String(format: "App %02d", $0), pid: pid_t(3_000 + $0)) }
        let plan = plan(apps)
        var selection = CaptureSelection(plan: plan)
        #expect(selection.count == 50 && selection.isAtLimit)
        let fiftyFirst = plan.candidates[50]
        #expect(!selection.canToggle(fiftyFirst))
        let pastTheLimit = selection.set(fiftyFirst, selected: true)
        #expect(!pastTheLimit)

        selection.set(plan.candidates[0], selected: false)
        #expect(!selection.isAtLimit && selection.canToggle(fiftyFirst))
        let belowTheLimit = selection.set(fiftyFirst, selected: true)
        #expect(belowTheLimit)
        #expect(selection.items(in: plan).count == 50)
    }

    @Test func selectAllTakesTheFirstFiftySelectableAndSelectNoneClears() {
        let apps = (0..<55).map { CaptureApps.app("com.example.app\($0)", String(format: "App %02d", $0), pid: pid_t(4_000 + $0)) }
        let inGroup = [AppReference(bundleIdentifier: "com.example.app0", name: "App 00")]
        let plan = plan(apps, targetItems: inGroup)
        var selection = CaptureSelection(plan: plan)

        selection.selectNone()
        #expect(selection.isEmpty)
        selection.selectAll(in: plan)
        #expect(selection.count == 50)
        #expect(!selection.ids.contains("com.example.app0"))
        #expect(selection.ids == Set(plan.candidates.filter(\.isSelectable).prefix(50).map(\.id)))
    }

    @Test func aTypedNameIsKeptAndABlankOneIsTheSuggestion() {
        let items = [AppReference(bundleIdentifier: "com.apple.dt.Xcode", name: "Xcode"), AppReference(bundleIdentifier: "com.apple.Safari", name: "Safari")]
        #expect(CapturePlanner.groupName(typed: "  Web Work ", items: items, taken: []) == "Web Work")
        #expect(CapturePlanner.groupName(typed: "Xcode +1", items: items, taken: ["Xcode +1"]) == "Xcode +1", "as typed, as renaming keeps it")
        #expect(CapturePlanner.groupName(typed: " ", items: items, taken: ["xcode +1"]) == "Xcode +1 2")
        #expect(CapturePlanner.groupName(typed: "", items: [], taken: []) == "Open Apps")
    }
}

@Suite("Capture: adding what was chosen")
@MainActor
struct GroupStoreCaptureResultTests {
    private static let xcode = AppReference(bundleIdentifier: "com.apple.dt.Xcode", name: "Xcode", path: "/Applications/Xcode.app")
    private static let safari = AppReference(bundleIdentifier: "com.apple.Safari", name: "Safari", path: "/Applications/Safari.app")

    @Test func aNewGroupIsMadeWithTheItems() throws {
        let store = GroupStore(persistence: CountingGroupPersistence(), saveDelay: .zero)
        let result = store.capture([Self.xcode, Self.safari], into: .newGroup, named: "Xcode +1")
        guard case .created(let group) = result else {
            Issue.record("Expected a new group, got \(result)")
            return
        }
        #expect(store.groups == [group])
        #expect(group.name == "Xcode +1" && group.apps == [Self.xcode, Self.safari])
    }

    @Test func appsAreAddedToAnActiveGroupOnly() {
        let store = GroupStore(persistence: CountingGroupPersistence(), saveDelay: .zero)
        let work = store.addGroup(named: "Work", items: [Self.safari])
        #expect(store.capture([Self.safari, Self.xcode], into: .group(work.id), named: "ignored") == .added(count: 1, groupID: work.id))
        #expect(store.group(withID: work.id)?.apps == [Self.safari, Self.xcode])
        #expect(store.capture([Self.xcode], into: .group(work.id), named: "") == .added(count: 0, groupID: work.id))

        store.archiveGroup(work.id)
        #expect(store.capture([Self.xcode], into: .group(work.id), named: "") == .unavailableGroup)
        #expect(store.archivedGroup(withID: work.id)?.group.apps == [Self.safari, Self.xcode], "an archived group isn't changed")
        #expect(store.capture([Self.xcode], into: .group(UUID()), named: "") == .unavailableGroup)
        #expect(store.groups.isEmpty)
    }
}

/// The app's wiring of capture, read from its sources (the tests don't link the app target).
@Suite("Capture: the app's wiring")
struct CaptureSurfaceTests {
    private static func source(_ path: String) throws -> String {
        try String(contentsOf: LocalizationTests.root.appending(path: "Sources/CybokronDockGroups/\(path)"), encoding: .utf8)
    }

    /// The body of the first function `signature` starts, up to the next function at its level.
    private static func body(of signature: String, in source: String) throws -> String {
        let start = try #require(source.range(of: signature)).lowerBound
        let rest = source[start...].dropFirst(signature.count)
        let end = rest.range(of: "\n    private func ")?.lowerBound ?? rest.range(of: "\n    func ")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    /// The open apps are read before anything brings this app forward (spec §2.6).
    @Test func theSnapshotIsTakenBeforeTheWindowComesForward() throws {
        let app = try Self.source("App/AppDelegate.swift")
        let begin = try Self.body(of: "private func beginCapture(_ target: CaptureTarget)", in: app)
        let snapshot = try #require(begin.range(of: "let snapshot = capture.snapshot()")).lowerBound
        let window = try #require(begin.range(of: "mainWindowController.capture(target, from: snapshot)")).lowerBound
        #expect(snapshot < window)
        #expect(!begin.contains("NSApp.activate"))
        #expect(!begin[..<snapshot].contains("mainWindowController"), "the window controller isn't even created before")

        let controller = try Self.source("MainWindow/MainWindowController.swift")
        let capture = try Self.body(of: "func capture(_ target: CaptureTarget, from snapshot: OpenAppsSnapshot)", in: controller)
        let request = try #require(capture.range(of: "selection.capture = CaptureRequest(target: target, snapshot: snapshot)")).lowerBound
        let show = try #require(capture.range(of: "show()")).lowerBound
        #expect(request < show)
    }

    /// Every surface goes through `beginCapture`; links only show the sheet.
    @Test func everySurfaceGoesThroughBeginCapture() throws {
        let app = try Self.source("App/AppDelegate.swift")
        #expect(app.contains("captureNewGroup: { [weak self] in self?.beginCapture(.newGroup) }"), "menu bar")
        #expect(app.contains("capture: { [weak self] target in self?.beginCapture(target) }"), "group window")
        #expect(app.contains("captureOpenApps: { [weak self] group in self?.beginCapture(.group(group.id)) }"), "popup")
        #expect(app.contains("case .captureNewGroup:\n            // Only the sheet: the user's click makes the group (capture spec Decision 5).\n            beginCapture(.newGroup)"))
        #expect(app.contains("case .captureOpenApps(let name):\n            if let group = group(named: name) { beginCapture(.group(group.id)) }"))
        // Links find active groups only (`store.groups`), so an archived group is never a target.
        #expect(app.contains("guard let group = GroupLookup.group(matching: name, in: store.groups) else {"))
        #expect(app.contains("if case .group(let id) = target, store.group(withID: id) == nil {"))

        let window = try Self.source("MainWindow/MainWindowView.swift")
        #expect(window.contains("captureNewGroup: { actions.capture(.newGroup) },"))
        #expect(window.contains("guard let request = selection.capture, shownCapture == nil, items.window?.attachedSheet == nil else { return }"))
        #expect(window.contains("if case .group(let id) = request.target, store.group(withID: id) == nil {"))
        let detail = try Self.source("MainWindow/GroupDetailView.swift")
        #expect(detail.contains("Button(L10n.Capture.addMenuItem) { actions.capture(.group(group.id)) }"))
        let sidebar = try Self.source("MainWindow/GroupSidebarView.swift")
        #expect(sidebar.contains("Button(L10n.Capture.sidebarItem, action: actions.captureNewGroup)"))
        let menu = try Self.source("MenuBar/StatusBarController.swift")
        #expect(menu.contains("NSMenuItem(title: L10n.Capture.menuBarItem, action: #selector(captureNewGroup(_:)), keyEquivalent: \"\")"))
        let settings = try Self.source("Settings/ShortcutsSettingsView.swift")
        #expect(settings.contains("+ [GroupInvocations.captureLink(for: group, in: store.groups)]"))
    }

    /// The popup offers Add Open Apps… only where the group can be edited: never for Most Used, and
    /// never in a standalone group's own app, which doesn't capture at all.
    @Test func standaloneGroupsOwnAppsDontCapture() throws {
        let popup = try Self.source("Popup/PopupPanelController.swift")
        #expect(popup.contains("addOpenApps: allowsEditing && id != MostUsedGroup.id && actions.captureOpenApps != nil"))
        let content = try Self.source("Popup/PopupContentView.swift")
        #expect(content.contains("if content.isEditable, let addOpenApps = actions.addOpenApps {"))
        let agent = try Self.source("Agent/AgentAppDelegate.swift")
        for name in ["capture", "Capture"] {
            #expect(!agent.contains(name), "the agent mentions \(name)")
        }
    }

    /// Only regular apps other than this one feed the history, and the app's capture code asks for
    /// no permission.
    @Test func theAppSideAsksForNoPermission() throws {
        let controller = try Self.source("Capture/CaptureController.swift")
        #expect(controller.contains("guard application.processIdentifier != ownProcessIdentifier,\n              application.activationPolicy == .regular,"))
        #expect(controller.contains("forName: NSWorkspace.didActivateApplicationNotification"))
        let forbidden = [
            "AXIsProcessTrusted", "AXUIElement", "kAXTrustedCheckOptionPrompt", "AccessibilityAccess",
            "kCGWindowName", "CGRequestScreenCaptureAccess", "CGPreflightScreenCaptureAccess", "ScreenCaptureKit",
            "NSAppleScript", "NSAppleEventDescriptor", "CGEventTapCreate", "addGlobalMonitorForEvents",
            // Capturing never opens, hides or quits anything.
            "openApplication", "terminate(", "hide()", "launchApplication", ".activate(",
        ]
        let sources = try ["Capture/CaptureController.swift", "Capture/CaptureSheet.swift"].map { ($0, try Self.source($0)) }
            + [("DockGroupsCore/Capture/CaptureSelection.swift", try String(contentsOf: LocalizationTests.root.appending(path: "Sources/DockGroupsCore/Capture/CaptureSelection.swift"), encoding: .utf8))]
        for (file, text) in sources {
            for name in forbidden {
                #expect(!text.contains(name), "\(file) uses \(name)")
            }
        }
    }
}
