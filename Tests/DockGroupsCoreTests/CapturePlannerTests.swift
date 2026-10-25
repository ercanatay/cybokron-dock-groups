import CoreGraphics
import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Capture: which open apps are listed")
struct CapturePlannerEligibilityTests {
    private func plan(
        _ apps: [OpenApp],
        windows: WindowSnapshot? = nil,
        history: ActivationHistory = ActivationHistory(),
        settings: CaptureSettings = CaptureSettings(),
        target: CaptureTarget = .newGroup,
        targetItems: [GroupItem] = [],
        protectedApps: ProtectedApps = ProtectedApps(),
        leavingOut: Set<String> = []
    ) -> CapturePlan {
        CapturePlanner.plan(
            OpenAppsSnapshot(apps: apps, windows: windows, history: history),
            settings: settings, target: target, targetItems: targetItems,
            protectedApps: protectedApps, leavingOut: leavingOut
        )
    }

    @Test func onlyRegularAppsAreListedAndBackgroundAppsAreNotCounted() {
        let helper = CaptureApps.app("com.apple.dt.Xcode.helper", "Xcode Helper", pid: 7, regular: false)
        let extra = CaptureApps.app("com.example.menuextra", "Menu Extra", pid: 8, regular: false)
        let result = plan([CaptureApps.xcode, helper, extra, CaptureApps.safari])

        // Nothing used, no windows, no launch dates: by name.
        #expect(result.candidates.map(\.id) == ["com.apple.safari", "com.apple.dt.xcode"])
        #expect(result.unavailableCount == 0)
        #expect(result.target == .newGroup)
    }

    @Test func thisAppItsCopiesItsAgentsFinderAndTheCallerAreLeftOut() {
        let apps = [
            CaptureApps.app("com.cybokron.dockgroups", "Cybokron Dock Groups", pid: 1),
            CaptureApps.app("COM.CYBOKRON.DOCKGROUPS", "Cybokron Dock Groups", pid: 2, path: "/Users/me/Downloads/Cybokron Dock Groups.app"),
            CaptureApps.app("com.cybokron.dockgroups.agent.\(UUID().uuidString)", "Coding", pid: 3, path: "/Users/me/Library/Application Support/Cybokron/DockGroups/Agents/Coding.app"),
            CaptureApps.app("com.apple.finder", "Finder", pid: 4, path: "/System/Library/CoreServices/Finder.app"),
            CaptureApps.app("com.apple.shortcuts", "Shortcuts", pid: 5, path: "/System/Applications/Shortcuts.app"),
            CaptureApps.xcode,
        ]

        let fromTheSheet = plan(apps)
        #expect(fromTheSheet.candidates.map(\.id) == ["com.apple.shortcuts", "com.apple.dt.xcode"])
        let fromShortcuts = plan(apps, leavingOut: ["COM.APPLE.SHORTCUTS"])
        #expect(fromShortcuts.candidates.map(\.id) == ["com.apple.dt.xcode"])
        // Left out on purpose, not "couldn't be added".
        #expect(fromShortcuts.unavailableCount == 0)
    }

    @Test(arguments: [
        OpenApp(processIdentifier: 20, bundleIdentifier: "com.example.nobundle", bundleURL: nil, name: "No Bundle"),
        OpenApp(processIdentifier: 21, bundleIdentifier: "com.example.web", bundleURL: URL(string: "https://example.com/App.app"), name: "Web"),
        OpenApp(processIdentifier: 22, bundleIdentifier: "org.python.python", bundleURL: URL(fileURLWithPath: "/usr/bin/python3"), name: "Python"),
        OpenApp(processIdentifier: 23, bundleIdentifier: "com.example.folder", bundleURL: URL(fileURLWithPath: "/Applications/Tools", isDirectory: true), name: "Tools"),
        OpenApp(processIdentifier: 24, bundleIdentifier: "com.example.script", bundleURL: URL(fileURLWithPath: "/Users/me/run.command"), name: "Run"),
        OpenApp(processIdentifier: 25, bundleIdentifier: "com.example/evil", bundleURL: URL(fileURLWithPath: "/Applications/Evil.app"), name: "Evil"),
        OpenApp(processIdentifier: 26, bundleIdentifier: "file:///tmp/x", bundleURL: URL(fileURLWithPath: "/Applications/Evil.app"), name: "Evil"),
        OpenApp(processIdentifier: 27, bundleIdentifier: "com.example evil", bundleURL: URL(fileURLWithPath: "/Applications/Evil.app"), name: "Evil"),
        OpenApp(processIdentifier: 28, bundleIdentifier: "com.example.evil\u{7}", bundleURL: URL(fileURLWithPath: "/Applications/Evil.app"), name: "Evil"),
        OpenApp(processIdentifier: 29, bundleIdentifier: String(repeating: "a", count: 256), bundleURL: URL(fileURLWithPath: "/Applications/Long.app"), name: "Long"),
        OpenApp(processIdentifier: 30, bundleIdentifier: nil, bundleURL: nil, name: "Nothing"),
        OpenApp(processIdentifier: 31, bundleIdentifier: nil, bundleURL: URL(fileURLWithPath: "/private/var/folders/xy/abc/T/AppTranslocation/0F1E2D3C/d/Tool.app"), name: "Tool"),
    ])
    func appsThatCantBeItemsAreCounted(app: OpenApp) {
        let result = plan([app, CaptureApps.xcode])
        #expect(result.candidates.map(\.id) == ["com.apple.dt.xcode"])
        #expect(result.unavailableCount == 1)
        #expect(result.unavailableNote?.hasPrefix("1 open app can't be added here") == true)
    }

    @Test func theFootnoteCountsAndIsAbsentWithoutUnavailableApps() {
        let broken = (0..<3).map { OpenApp(processIdentifier: pid_t(40 + $0), bundleIdentifier: "com.example.b\($0)", bundleURL: nil, name: "B") }
        let result = plan(broken + [CaptureApps.xcode])
        #expect(result.unavailableCount == 3)
        #expect(result.unavailableNote == "3 open apps can't be added here: they aren't app bundles, or run from a temporary copy (move them to Applications first).")
        #expect(plan([CaptureApps.xcode]).unavailableNote == nil)
        #expect(CapturePlan.limitNote == "You can add up to 50 apps at once.")
    }

    @Test func itemsAreAppItemsAsAddAppsMakesThem() throws {
        let result = plan([CaptureApps.terminal])
        let item = try #require(result.candidates.first?.item)
        #expect(item == AppReference(bundleIdentifier: "com.apple.Terminal", name: "Terminal", path: "/System/Applications/Utilities/Terminal.app"))
        #expect(item.kind == .application)
        #expect(item.details.isEmpty && item.launch.isEmpty)
    }

    @Test func anAppWithoutABundleIdentifierIsIdentifiedByItsLocation() throws {
        let tool = CaptureApps.app(nil, "Old Tool", pid: 50, path: "/Applications/Games/Old Tool.app")
        let empty = CaptureApps.app("", "Other Tool", pid: 51, path: "/Applications/Games/Other Tool.app")
        let result = plan([tool, empty])

        let items = result.candidates.map(\.item)
        #expect(items == [
            AppReference(bundleIdentifier: "/Applications/Games/Old Tool.app", name: "Old Tool", path: "/Applications/Games/Old Tool.app"),
            AppReference(bundleIdentifier: "/Applications/Games/Other Tool.app", name: "Other Tool", path: "/Applications/Games/Other Tool.app"),
        ])
        #expect(items.allSatisfy { $0.isIdentifiedByPath })
        // The identity running apps are matched by (`RunningAppSnapshot.identity`).
        #expect(result.candidates.first?.id == RunningAppSnapshot.identity(bundleIdentifier: nil, bundleURL: tool.bundleURL))
    }

    @Test func anAppWithAnIdentifierRunFromATemporaryCopyIsKeptWithoutItsLocation() throws {
        let downloaded = CaptureApps.app("com.example.Downloaded", "Downloaded", pid: 60, path: "/private/var/folders/xy/abc/T/AppTranslocation/0F1E2D3C/d/Downloaded.app")
        let result = plan([downloaded])
        #expect(result.candidates.map(\.item) == [AppReference(bundleIdentifier: "com.example.Downloaded", name: "Downloaded")])
        #expect(result.unavailableCount == 0)
    }

    @Test func anAppOnADiskImageKeepsItsLocation() throws {
        let mounted = CaptureApps.app("com.example.Installer", "Mounted", pid: 61, path: "/Volumes/Mounted/Mounted.app")
        #expect(plan([mounted]).candidates.first?.item.path == "/Volumes/Mounted/Mounted.app")
    }

    @Test func namesAreCleanedUpAndFallBackToTheBundlesName() {
        let apps = [
            OpenApp(processIdentifier: 70, bundleIdentifier: "com.example.a", bundleURL: URL(fileURLWithPath: "/Applications/A.app"), name: "  Xcode\n "),
            OpenApp(processIdentifier: 71, bundleIdentifier: "com.example.b", bundleURL: URL(fileURLWithPath: "/Applications/Old Tool.app"), name: nil),
            OpenApp(processIdentifier: 72, bundleIdentifier: "com.example.c", bundleURL: URL(fileURLWithPath: "/Applications/C.app"), name: "Ter\u{0}mi\u{1B}nal"),
            OpenApp(processIdentifier: 73, bundleIdentifier: "com.example.d", bundleURL: URL(fileURLWithPath: "/Applications/Blank.app"), name: " \t "),
            OpenApp(processIdentifier: 74, bundleIdentifier: "com.example.e", bundleURL: URL(fileURLWithPath: "/Applications/E.app"), name: String(repeating: "é", count: 300)),
        ]
        let names = plan(apps, settings: CaptureSettings(order: .recentlyUsed)).candidates.map(\.item.name)
        #expect(Set(names) == ["Xcode", "Old Tool", "Terminal", "Blank", String(repeating: "é", count: 255)])
    }

    @Test func twoInstancesOfAnAppAreOneItemWithTheMoreRecentOnesLocation() {
        let stable = CaptureApps.app("com.apple.Safari", "Safari", pid: 80)
        let preview = CaptureApps.app("COM.APPLE.SAFARI", "Safari", pid: 81, path: "/Users/me/Applications/Safari.app")
        // The second instance has the frontmost window.
        let result = plan([stable, preview, CaptureApps.xcode], windows: CaptureApps.windows(onScreen: [81, 101, 80]))

        #expect(result.candidates.map(\.id) == ["com.apple.safari", "com.apple.dt.xcode"])
        #expect(result.candidates[0].item.path == "/Users/me/Applications/Safari.app")
        #expect(result.candidates[0].item.bundleIdentifier == "COM.APPLE.SAFARI")
    }
}

@Suite("Capture: order and notes")
struct CapturePlannerOrderTests {
    private func plan(_ snapshot: OpenAppsSnapshot, settings: CaptureSettings = CaptureSettings(), targetItems: [GroupItem] = [], protectedApps: ProtectedApps = ProtectedApps()) -> CapturePlan {
        CapturePlanner.plan(snapshot, settings: settings, target: targetItems.isEmpty ? .newGroup : .group(UUID()), targetItems: targetItems, protectedApps: protectedApps)
    }

    @Test func mostRecentlyUsedFirstThenWindowsThenLaunchDateThenName() {
        let apps = [
            CaptureApps.app("com.example.h", "Beta", pid: 8),
            CaptureApps.app("com.example.g", "Alpha", pid: 7),
            CaptureApps.app("com.example.f", "F", pid: 6, launched: 100),
            CaptureApps.app("com.example.e", "E", pid: 5, launched: 500),
            CaptureApps.app("com.example.d", "D", pid: 4),
            CaptureApps.app("com.example.c", "C", pid: 3),
            CaptureApps.app("com.example.a", "A", pid: 1, launched: 1),
            CaptureApps.app("com.example.b", "B", pid: 2),
        ]
        var history = ActivationHistory()
        history.recordActivation(ofIdentity: "com.example.a")
        history.recordActivation(ofIdentity: "COM.EXAMPLE.B")
        // C's window is in front of D's; A and B are on screen too, but they were used.
        let windows = CaptureApps.windows(onScreen: [1, 3, 2, 4], offScreen: [5])

        let result = plan(OpenAppsSnapshot(apps: apps, windows: windows, history: history))

        #expect(result.candidates.map(\.item.name) == ["B", "A", "C", "D", "E", "F", "Alpha", "Beta"])
    }

    @Test func withoutAHistoryOrWindowsTheLaunchDateAndNameDecide() {
        let apps = [
            CaptureApps.app("com.example.z", "Zed", pid: 1),
            CaptureApps.app("com.example.y", "Yak", pid: 2, launched: 10),
            CaptureApps.app("com.example.x", "Ant", pid: 3),
        ]
        let result = plan(OpenAppsSnapshot(apps: apps, windows: nil))
        #expect(result.candidates.map(\.item.name) == ["Yak", "Ant", "Zed"])
        #expect(!result.hasWindowInformation)
    }

    @Test func byNameAsFinderSortsNames() {
        let apps = [
            CaptureApps.app("com.example.10", "App 10", pid: 1),
            CaptureApps.app("com.example.2", "app 2", pid: 2),
            CaptureApps.app("com.example.c", "Calendar", pid: 3),
            CaptureApps.app("com.example.b", "Brave", pid: 4),
        ]
        var history = ActivationHistory()
        history.recordActivation(ofIdentity: "com.example.c")
        let result = plan(OpenAppsSnapshot(apps: apps, windows: nil, history: history), settings: CaptureSettings(order: .name))
        // Numbers in numeric order, case ignored; the history doesn't count.
        #expect(result.candidates.map(\.item.name) == ["app 2", "App 10", "Brave", "Calendar"])
    }

    @Test func notesSayHiddenNoWindowsProtectedAndInGroup() throws {
        let hiddenTwice = [
            CaptureApps.app("com.apple.Music", "Music", pid: 1, hidden: true),
            CaptureApps.app("com.apple.Music", "Music", pid: 2, path: "/Applications/Music Copy.app", hidden: true),
        ]
        let halfHidden = [
            CaptureApps.app("com.apple.Notes", "Notes", pid: 3, hidden: true),
            CaptureApps.app("com.apple.Notes", "Notes", pid: 4, path: "/Applications/Notes Copy.app"),
        ]
        let tool = CaptureApps.app(nil, "Old Tool", pid: 5, path: "/Applications/Games/Old Tool.app")
        let apps = hiddenTwice + halfHidden + [CaptureApps.mail, CaptureApps.xcode, tool]
        // Music's second copy has a window off screen; Mail has none.
        let windows = CaptureApps.windows(onScreen: [101, 4], offScreen: [2, 5])
        let protected = ProtectedApps([AppReference(bundleIdentifier: "com.apple.mail", name: "Mail")])
        let inGroup = [
            AppReference(bundleIdentifier: "COM.APPLE.DT.XCODE", name: "Xcode"),
            AppReference(bundleIdentifier: "/applications/games/old tool.app", name: "Old Tool", path: "/applications/games/old tool.app"),
        ]

        let result = plan(OpenAppsSnapshot(apps: apps, windows: windows), targetItems: inGroup, protectedApps: protected)
        let notes = Dictionary(uniqueKeysWithValues: result.candidates.map { ($0.item.name, $0.notes) })

        #expect(notes["Music"] == [.hidden])
        #expect(notes["Notes"] == [])
        #expect(notes["Mail"] == [.noWindows, .protected])
        #expect(notes["Xcode"] == [.inGroup])
        #expect(notes["Old Tool"] == [.inGroup])
        #expect(result.candidates.filter { !$0.isSelectable }.map(\.item.name).sorted() == ["Old Tool", "Xcode"])
    }

    @Test func withoutAWindowListNoAppIsSaidToHaveNoWindows() {
        let result = plan(OpenAppsSnapshot(apps: [CaptureApps.xcode, CaptureApps.mail], windows: nil), settings: CaptureSettings(selectsOnlyAppsWithWindows: true))
        #expect(result.candidates.allSatisfy { !$0.notes.contains(.noWindows) })
        // So the window option selects every app rather than none.
        #expect(result.defaultSelection == ["com.apple.mail", "com.apple.dt.xcode"])
    }
}

@Suite("Capture: what starts selected, and the limits")
struct CapturePlannerSelectionTests {
    private let windows = CaptureApps.windows(onScreen: [101, 102])

    private func plan(_ apps: [OpenApp], windows: WindowSnapshot?, settings: CaptureSettings = CaptureSettings(), targetItems: [GroupItem] = [], protectedApps: ProtectedApps = ProtectedApps()) -> CapturePlan {
        CapturePlanner.plan(OpenAppsSnapshot(apps: apps, windows: windows), settings: settings, target: .newGroup, targetItems: targetItems, protectedApps: protectedApps)
    }

    @Test func everythingStartsSelectedButProtectedAppsAndAppsInTheGroup() {
        let protected = ProtectedApps([AppReference(bundleIdentifier: "com.apple.mail", name: "Mail")])
        let result = plan(
            [CaptureApps.xcode, CaptureApps.safari, CaptureApps.mail, CaptureApps.music],
            windows: windows,
            targetItems: [AppReference(bundleIdentifier: "com.apple.Safari", name: "Safari")],
            protectedApps: protected
        )
        // Music has no window, but the window option is off (the default, Decision 4).
        #expect(result.defaultSelection == ["com.apple.dt.xcode", "com.apple.music"])
        #expect(result.candidates.map(\.id) == ["com.apple.dt.xcode", "com.apple.safari", "com.apple.mail", "com.apple.music"])
        #expect(result.hasSelectableCandidates)
    }

    @Test func theWindowOptionOnlyChangesWhatStartsSelected() {
        let apps = [CaptureApps.xcode, CaptureApps.safari, CaptureApps.music]
        let off = plan(apps, windows: windows)
        let on = plan(apps, windows: windows, settings: CaptureSettings(selectsOnlyAppsWithWindows: true))

        #expect(on.candidates == off.candidates)
        #expect(off.defaultSelection == ["com.apple.dt.xcode", "com.apple.safari", "com.apple.music"])
        #expect(on.defaultSelection == ["com.apple.dt.xcode", "com.apple.safari"])
        // Music can still be chosen.
        #expect(on.items(selecting: ["com.apple.music"]).map(\.name) == ["Music"])
    }

    @Test func atMostFiftyAppsAreSelectedOrAdded() {
        let apps = (0..<60).map { CaptureApps.app("com.example.app\($0)", "App \($0)", pid: pid_t(1_000 + $0), launched: Double(1_000 - $0)) }
        let result = plan(apps, windows: nil)

        #expect(result.candidates.count == 60)
        #expect(result.defaultSelection.count == CapturePlan.maximumItems)
        #expect(result.defaultSelection == Array(result.candidates.prefix(50).map(\.id)))
        let everything = Set(result.candidates.map(\.id))
        #expect(result.items(selecting: everything).count == 50)
        #expect(result.items(selecting: everything).map(\.bundleIdentifier) == result.candidates.prefix(50).map(\.item.bundleIdentifier))
        #expect(result.defaultItems.count == 50)
    }

    @Test func selectedItemsComeInListOrderAndOnlySelectableOnes() {
        let result = plan([CaptureApps.xcode, CaptureApps.safari, CaptureApps.terminal], windows: windows,
                          targetItems: [AppReference(bundleIdentifier: "com.apple.Safari", name: "Safari")])
        let items = result.items(selecting: ["com.apple.terminal", "COM.APPLE.DT.XCODE", "com.apple.safari", "com.example.unknown"])
        #expect(items.map(\.name) == ["Xcode", "Terminal"])
    }

    @Test func atMostTwoHundredOpenAppsAreListed() {
        let apps = (0..<230).map { CaptureApps.app("com.example.app\($0)", "App \($0)", pid: pid_t(2_000 + $0)) }
        let result = plan(apps, windows: nil)
        #expect(result.candidates.count == CapturePlan.maximumCandidates)
        #expect(result.unavailableCount == 0)
    }

    @Test func nothingOpenGivesAnEmptyPlan() {
        let result = plan([], windows: nil)
        #expect(result.candidates.isEmpty && result.defaultSelection.isEmpty)
        #expect(!result.hasSelectableCandidates)
        #expect(result.unavailableNote == nil)
        #expect(result.defaultItems.isEmpty)
    }

    @Test func whenEveryOpenAppIsInTheGroupNothingCanBeChosen() {
        let group = [CaptureApps.xcode, CaptureApps.safari].map { AppReference(bundleIdentifier: $0.bundleIdentifier!, name: $0.name!) }
        let result = plan([CaptureApps.xcode, CaptureApps.safari], windows: windows, targetItems: group)
        #expect(result.candidates.count == 2)
        #expect(!result.hasSelectableCandidates)
        #expect(result.defaultSelection.isEmpty)
        #expect(result.items(selecting: Set(result.candidates.map(\.id))).isEmpty)
    }

    @Test func replanningTheSameSnapshotGivesTheSamePlan() {
        let snapshot = OpenAppsSnapshot(apps: [CaptureApps.xcode, CaptureApps.music, CaptureApps.safari], windows: windows)
        let first = CapturePlanner.plan(snapshot, settings: CaptureSettings(order: .name), target: .newGroup)
        let again = CapturePlanner.plan(snapshot, settings: CaptureSettings(order: .name), target: .newGroup)
        #expect(first == again)
    }
}

@Suite("Capture: the suggested name")
@MainActor
struct CaptureNamingTests {
    private func items(_ names: String...) -> [GroupItem] {
        names.map { AppReference(bundleIdentifier: "com.example.\($0.lowercased())", name: $0) }
    }

    @Test func theFirstAppAndHowManyMore() {
        #expect(CapturePlanner.suggestedName(for: [], taken: []) == "Open Apps")
        #expect(CapturePlanner.suggestedName(for: items("Xcode"), taken: []) == "Xcode")
        #expect(CapturePlanner.suggestedName(for: items("Xcode", "Safari"), taken: []) == "Xcode +1")
        #expect(CapturePlanner.suggestedName(for: items("Xcode", "Safari", "Terminal", "Simulator"), taken: []) == "Xcode +3")
    }

    @Test func theNameIsUniqueAmongActiveAndArchivedGroups() {
        let store = GroupStore(persistence: CountingGroupPersistence(), saveDelay: .zero)
        let archived = store.addGroup(named: "Xcode +3")
        store.archiveGroup(archived.id)
        store.addGroup(named: "open apps")

        #expect(CapturePlanner.suggestedName(for: items("Xcode", "A", "B", "C"), taken: store.takenNames) == "Xcode +3 2")
        #expect(CapturePlanner.suggestedName(for: [], taken: store.takenNames) == "Open Apps 2")
        #expect(CapturePlanner.suggestedName(for: items("Safari"), taken: store.takenNames) == "Safari")
    }

    /// A translation may put the count first; numbered placeholders keep each value in its place.
    @Test func aTranslationCanReorderTheSuggestion() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let folder = temporary.url.appending(components: "Capture.bundle", "Contents", "Resources", "en.lproj", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("\"core.capture.name.more\" = \"+%2$ld · %1$@\";\n".utf8).write(to: folder.appending(path: "Localizable.strings"))
        let info = ["CFBundleIdentifier": "com.cybokron.dockgroups.capture-test", "CFBundleDevelopmentRegion": "en"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: temporary.url.appending(components: "Capture.bundle", "Contents", "Info.plist"))
        let bundle = try #require(Bundle(url: temporary.url.appending(path: "Capture.bundle", directoryHint: .isDirectory)))

        let format = Localization.string("core.capture.name.more", "%1$@ +%2$ld", in: bundle)
        #expect(String(format: format, locale: Locale(identifier: "en_US_POSIX"), "Xcode", 3) == "+3 · Xcode")
    }
}

@Suite("Capture: activation history")
struct ActivationHistoryTests {
    @Test func theMostRecentActivationComesFirst() {
        var history = ActivationHistory()
        history.recordActivation(ofIdentity: "com.apple.Safari")
        history.recordActivation(ofIdentity: "com.apple.dt.Xcode")
        #expect(history.rank(ofIdentity: "com.apple.dt.xcode") == 0)
        #expect(history.rank(ofIdentity: "COM.APPLE.SAFARI") == 1)
        #expect(history.rank(ofIdentity: "com.apple.mail") == nil)

        history.recordActivation(ofIdentity: "COM.APPLE.SAFARI")
        #expect(history.recentIdentities == ["com.apple.safari", "com.apple.dt.xcode"])
    }

    @Test func itKeepsAtMostTwoHundredAndIgnoresEmptyIdentities() {
        var history = ActivationHistory()
        for index in 0..<205 {
            history.recordActivation(ofIdentity: "com.example.app\(index)")
        }
        history.recordActivation(ofIdentity: "")
        #expect(history.recentIdentities.count == ActivationHistory.maximumCount)
        #expect(history.rank(ofIdentity: "com.example.app204") == 0)
        #expect(history.rank(ofIdentity: "com.example.app5") == 199)
        #expect(history.rank(ofIdentity: "com.example.app4") == nil)
    }

    @Test func aSeedIsCleanedUpAsActivationsAre() {
        let history = ActivationHistory(recentIdentities: ["com.apple.Safari", "", "com.apple.dt.Xcode", "COM.APPLE.SAFARI"])
        #expect(history.recentIdentities == ["com.apple.safari", "com.apple.dt.xcode"])
        #expect(ActivationHistory(recentIdentities: (0..<300).map { "id\($0)" }).recentIdentities.count == 200)
    }
}

@Suite("Capture: window list")
struct WindowSnapshotTests {
    private typealias Apps = CaptureApps

    @Test func onlyNormalVisibleWindowsOfSomeSizeCount() {
        let onScreen = [
            Apps.window(pid: 1, layer: 25),                 // a menu bar extra's item
            Apps.window(pid: 2, alpha: 0),                  // invisible
            Apps.window(pid: 3, width: 10, height: 600),    // too narrow
            Apps.window(pid: 4, width: 600, height: 49),    // too low
            Apps.window(pid: 5, alpha: nil),                // no alpha: opaque
            Apps.window(pid: 6, width: 50, height: 50),
        ]
        let snapshot = WindowSnapshot(onScreen: onScreen, all: onScreen)
        #expect(snapshot.onScreenOrder == [5, 6])
        #expect(snapshot.processesWithWindows == [5, 6])
    }

    @Test func onScreenWindowsGiveTheOrderAndOffScreenOnesCountToo() {
        let onScreen = [Apps.window(pid: 9), Apps.window(pid: 7), Apps.window(pid: 9), Apps.window(pid: 8)]
        let all = onScreen + [Apps.window(pid: 11), Apps.window(pid: 12, layer: 3)]
        let snapshot = WindowSnapshot(onScreen: onScreen, all: all)
        #expect(snapshot.onScreenOrder == [9, 7, 8])
        #expect(snapshot.processesWithWindows == [7, 8, 9, 11])
    }

    /// What every app keeps off screen on macOS 27 (docs/design/capture-spike.md): menu bar strips
    /// and squares at the left edge. They don't make an app look open; a hidden app's or a
    /// minimized window, off screen where it was shown, does.
    @Test func offScreenHelperWindowsDontCountButOffScreenWindowsDo() {
        let word: pid_t = 10, calculator: pid_t = 11, chrome: pid_t = 12, notes: pid_t = 13
        let all = [
            // Microsoft Word with no document: helpers only.
            Apps.window(pid: word, x: 0, y: 0, width: 2560, height: 30),
            Apps.window(pid: word, x: 0, y: 940, width: 500, height: 500),
            Apps.window(pid: word, x: 0, y: 940, width: 64, height: 64),
            // Calculator, hidden: its window, off screen where it was.
            Apps.window(pid: calculator, x: 1382, y: 750, width: 230, height: 408),
            Apps.window(pid: calculator, x: 0, y: 1012, width: 370, height: 370),
            // A window as wide as the screen at the left edge isn't a square: it counts.
            Apps.window(pid: chrome, x: 0, y: 30, width: 2560, height: 1347),
            // On screen, a square at the left edge is a window like any other.
            Apps.window(pid: notes, x: 0, y: 40, width: 600, height: 600, onScreen: true),
        ]
        let onScreen = [Apps.window(pid: notes, x: 0, y: 40, width: 600, height: 600, onScreen: true)]
        let snapshot = WindowSnapshot(onScreen: onScreen, all: all)
        #expect(snapshot.processesWithWindows == [calculator, chrome, notes])
        #expect(snapshot.onScreenOrder == [notes])
        #expect(WindowSnapshot.isOnScreen(onScreen[0]))
        #expect(!WindowSnapshot.isOnScreen(all[0]))
        #expect(WindowSnapshot.isOnScreen([kCGWindowIsOnscreen as String: true]))
    }

    @Test func entriesWithoutOwnerLayerOrBoundsDontCount() {
        var noOwner = Apps.window(pid: 1)
        noOwner[kCGWindowOwnerPID as String] = nil
        var noLayer = Apps.window(pid: 2)
        noLayer[kCGWindowLayer as String] = nil
        var noBounds = Apps.window(pid: 3)
        noBounds[kCGWindowBounds as String] = nil
        var oddBounds = Apps.window(pid: 4)
        oddBounds[kCGWindowBounds as String] = "800×600"
        let snapshot = WindowSnapshot(onScreen: [noOwner, noLayer, noBounds, oddBounds], all: [])
        #expect(snapshot.processesWithWindows.isEmpty && snapshot.onScreenOrder.isEmpty)
    }

    /// Window names are what Screen Recording access guards: with or without them, the result is
    /// the same, because they're never read.
    @Test func windowNamesMakeNoDifference() {
        let named = [Apps.window(pid: 1, name: "Secret.pdf"), Apps.window(pid: 2, name: "Inbox")]
        let unnamed = [Apps.window(pid: 1), Apps.window(pid: 2)]
        #expect(WindowSnapshot(onScreen: named, all: named) == WindowSnapshot(onScreen: unnamed, all: unnamed))
    }

    @Test func swiftNumbersReadAsTheWindowServersDo() {
        let window: [String: Any] = [
            kCGWindowOwnerPID as String: Int32(42),
            kCGWindowLayer as String: 0,
            kCGWindowAlpha as String: 1.0,
            kCGWindowBounds as String: ["X": 0, "Y": 0, "Width": 300.0, "Height": CGFloat(200)] as [String: Any],
        ]
        #expect(WindowSnapshot(onScreen: [window], all: []).onScreenOrder == [42])
    }

    @MainActor
    @Test func aReaderGivesTheSnapshotItsPlanUses() {
        let reader = FakeOpenAppsReader(apps: [Apps.xcode], windows: Apps.windows(onScreen: [101]))
        var history = ActivationHistory()
        history.recordActivation(ofIdentity: "com.apple.dt.xcode")
        let snapshot = reader.snapshot(history: history)
        #expect(snapshot == OpenAppsSnapshot(apps: [Apps.xcode], windows: Apps.windows(onScreen: [101]), history: history))
        #expect(reader.readCount == 1)
    }
}
