import Combine
import Foundation
import Testing
@testable import DockGroupsCore

/// The details editor's Opening part (context switching PR 4): the draft's launch fields and how
/// closing the editor saves them.
@Suite("Launch options: the editor's draft")
@MainActor
struct LaunchOptionsDraftTests {
    private static let report = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Report.pdf"), kind: .file)
        .launching(after: 3, with: .app("com.apple.Preview", "Preview"))
    private static let slack = AppReference(bundleIdentifier: "com.tinyspeck.slackmacgap", name: "Slack").launching(after: 5)

    @Test func startsFromTheItemsLaunchOptions() {
        let draft = ItemDetailsDraft(Self.report)
        #expect(draft.delay == 3)
        #expect(draft.opener == .app("com.apple.Preview", "Preview"))
        #expect(draft.offersOpener)
        #expect(draft.launch == Self.report.launch)
        #expect(!draft.hasChanges)
        for ending in [ItemDetailsDraft.Ending.done, .dismissed, .cancel] {
            #expect(draft.launchToSave(endingWith: ending) == nil)
            #expect(draft.detailsToSave(endingWith: ending) == nil)
        }

        // A details-only draft has the defaults and never saves launch options.
        let detailsOnly = ItemDetailsDraft(ItemDetails(alias: "Q3"))
        #expect(detailsOnly.launch.isEmpty && !detailsOnly.offersOpener)
        #expect(detailsOnly.launchToSave(endingWith: .done) == nil)
    }

    @Test func appsHaveADelayButNoOpener() {
        var draft = ItemDetailsDraft(Self.slack)
        #expect(!draft.offersOpener)
        #expect(draft.delay == 5)
        draft.opener = .app("com.apple.Preview")
        #expect(draft.opener == nil)
        draft.delay = 10
        #expect(draft.launchToSave(endingWith: .done) == ItemLaunchOptions(delay: 10))
    }

    @Test func delaysAreTheOfferedStepsAndTheItemsOwn() {
        var draft = ItemDetailsDraft(Self.report)
        #expect(draft.delayChoices == ItemLaunchOptions.allowedDelays)
        let odd = ItemDetailsDraft(GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/a.txt"), kind: .file).launching(after: 7))
        // A delay a groups file gave stays offered, so opening the editor doesn't change it.
        #expect(odd.delayChoices == [0, 1, 2, 3, 5, 7, 10, 15, 30, 60])
        #expect(odd.launchToSave(endingWith: .done) == nil)
        draft.delay = 99
        #expect(draft.delay == ItemLaunchOptions.maximumDelay)
        draft.delay = -3
        #expect(draft.delay == 0)
    }

    @Test func closingSavesTheLaunchOptionsUnlessCancelled() {
        var draft = ItemDetailsDraft(Self.report)
        draft.opener = nil
        draft.delay = 0
        #expect(draft.hasChanges)
        #expect(draft.launchToSave(endingWith: .done) == ItemLaunchOptions())
        #expect(draft.launchToSave(endingWith: .dismissed) == ItemLaunchOptions())
        #expect(draft.launchToSave(endingWith: .cancel) == nil)
        #expect(draft.detailsToSave(endingWith: .done) == nil, "the details didn't change")
    }
}

@Suite("Launch options: saving the editor once")
@MainActor
struct LaunchOptionsSavingTests {
    private let persistence = MemoryGroupPersistence()
    private let store: GroupStore
    private let group: DockGroup
    private static let report = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Report.pdf"), kind: .file)

    init() {
        store = GroupStore(persistence: persistence, saveDelay: .zero)
        let added = store.addGroup(named: "Work")
        store.addItems([Self.report, AppReference(bundleIdentifier: "com.apple.mail", name: "Mail")], toGroup: added.id)
        group = store.group(withID: added.id)!
    }

    @Test func detailsAndLaunchOptionsAreOneChangeAndOneSave() {
        var changes = 0
        let subscription = store.$groups.dropFirst().sink { _ in changes += 1 }
        let saves = persistence.saveCount
        var draft = ItemDetailsDraft(Self.report)
        draft.alias = "Q3"
        draft.delay = 3
        draft.opener = .app("com.apple.Preview", "Preview")

        #expect(store.saveItemEdits(of: draft, endingWith: .done, ofItem: Self.report.bundleIdentifier, inGroup: group.id))

        #expect(persistence.saveCount == saves + 1)
        #expect(changes == 1, "one change of the groups: a standalone group's app is rebuilt once")
        let saved = store.group(withID: group.id)!.apps[0]
        #expect(saved.details == ItemDetails(alias: "Q3"))
        #expect(saved.launch == ItemLaunchOptions(delay: 3, opener: .app("com.apple.Preview", "Preview")))
        subscription.cancel()
    }

    @Test func cancelAndNoChangeSaveNothing() {
        let saves = persistence.saveCount
        var draft = ItemDetailsDraft(Self.report)
        draft.delay = 10
        #expect(!store.saveItemEdits(of: draft, endingWith: .cancel, ofItem: Self.report.bundleIdentifier, inGroup: group.id))
        #expect(!store.saveItemEdits(of: ItemDetailsDraft(Self.report), endingWith: .done, ofItem: Self.report.bundleIdentifier, inGroup: group.id))
        #expect(persistence.saveCount == saves)
        #expect(store.group(withID: group.id)!.apps[0].launch.isEmpty)

        // The launch options alone are saved too.
        #expect(store.saveItemEdits(of: draft, endingWith: .dismissed, ofItem: Self.report.bundleIdentifier, inGroup: group.id))
        #expect(store.group(withID: group.id)!.apps[0].launch == ItemLaunchOptions(delay: 10))
        #expect(persistence.saveCount == saves + 1)
    }

    @Test func anItemThatsGoneSavesNothing() {
        var draft = ItemDetailsDraft(Self.report)
        draft.delay = 5
        store.removeApp(bundleIdentifier: Self.report.bundleIdentifier, fromGroup: group.id)
        let saves = persistence.saveCount
        #expect(!store.saveItemEdits(of: draft, endingWith: .done, ofItem: Self.report.bundleIdentifier, inGroup: group.id))
        #expect(!store.updateItem(Self.report.bundleIdentifier, inGroup: UUID(), details: nil, launch: ItemLaunchOptions(delay: 5)))
        #expect(persistence.saveCount == saves)
    }

    @Test func anAppKeepsNoOpener() {
        #expect(store.updateItem("com.apple.mail", inGroup: group.id, details: nil, launch: ItemLaunchOptions(delay: 2, opener: .app("com.apple.Preview"))))
        #expect(store.group(withID: group.id)!.apps[1].launch == ItemLaunchOptions(delay: 2))
    }
}

@Suite("Launch options: the Open With menu")
@MainActor
struct ItemOpenerMenuTests {
    private static let notesURL = URL(fileURLWithPath: "/Users/me/notes.txt")
    private static let notes = GroupItem(fileURL: notesURL, kind: .file)
    private static let projectsURL = URL(fileURLWithPath: "/Users/me/Projects/cybokron", isDirectory: true)
    private static let projects = GroupItem(fileURL: projectsURL, kind: .folder)

    /// TextEdit (the default), Visual Studio Code, BBEdit twice, Terminal and Python Launcher listed
    /// for the text file; VS Code for the folder; Terminal and iTerm2 installed.
    private func catalog() -> (FakeCatalog, [String: URL]) {
        let catalog = FakeCatalog()
        var apps: [String: URL] = [:]
        apps["textedit"] = catalog.install("com.apple.TextEdit")
        apps["code"] = catalog.install("com.microsoft.VSCode", at: "/Applications/Visual Studio Code.app")
        apps["bbedit"] = catalog.install("com.barebones.bbedit", at: "/Applications/BBEdit.app")
        apps["terminal"] = catalog.install("com.apple.Terminal", at: "/System/Applications/Utilities/Terminal.app")
        apps["iterm"] = catalog.install("com.googlecode.iterm2", at: "/Applications/iTerm.app")
        apps["python"] = catalog.install("org.python.PythonLauncher", at: "/Applications/Python 3.13/Python Launcher.app")
        for name in ["textedit", "code", "bbedit", "terminal", "python"] {
            catalog.list(apps[name]!, for: Self.notesURL)
        }
        catalog.list(apps["bbedit"]!, for: Self.notesURL)
        catalog.list(apps["code"]!, for: Self.projectsURL)
        return (catalog, apps)
    }

    @Test func offersTheListedAppsThatMayOpenTheItemByName() {
        let (catalog, apps) = catalog()
        let menu = ItemOpenerMenu(for: Self.notes, opener: nil, target: Self.notesURL, catalog: catalog)

        #expect(menu.defaultAppName == "TextEdit")
        // Terminal and Python Launcher run what they open; BBEdit is offered once.
        #expect(menu.choices.map(\.opener.name) == ["BBEdit", "TextEdit", "Visual Studio Code"])
        #expect(menu.choices.map(\.applicationURL) == [apps["bbedit"], apps["textedit"], apps["code"]])
        #expect(menu.currentStatus == .defaultApp && menu.current == nil)
        // Once for the list, however many apps are checked against it; the fake finds the
        // default app by listing too (the app's catalog asks LaunchServices for it directly).
        #expect(catalog.listingQuestions == 2)
    }

    @Test func aFolderAlsoOffersTheTerminals() {
        let (catalog, _) = catalog()
        let menu = ItemOpenerMenu(for: Self.projects, opener: nil, target: Self.projectsURL, catalog: catalog)
        #expect(menu.choices.map(\.opener.name) == ["iTerm", "Terminal", "Visual Studio Code"])
        #expect(menu.choices.map(\.opener.bundleIdentifier).contains("com.apple.Terminal"), "the bundle's own spelling")
        // Not for a file, though macOS lists Terminal for it.
        #expect(!ItemOpenerMenu(for: Self.notes, opener: nil, target: Self.notesURL, catalog: catalog).choices.contains { $0.opener.name == "Terminal" })
    }

    @Test func saysHowTheChosenAppStands() {
        let (catalog, _) = catalog()
        let code = ItemOpenerMenu(for: Self.notes, opener: .app("com.microsoft.VSCode", "Visual Studio Code"), target: Self.notesURL, catalog: catalog)
        #expect(code.currentStatus == .available)
        #expect(code.choice(for: .app("COM.MICROSOFT.VSCODE"))?.opener.name == "Visual Studio Code")

        let gone = ItemOpenerMenu(for: Self.notes, opener: .app("com.example.gone", "Gone"), target: Self.notesURL, catalog: catalog)
        #expect(gone.currentStatus == .notOnThisMac)
        #expect(gone.currentStatus.message(openerName: "Gone") == "“Gone” isn't on this Mac: the item opens with its default app.")

        let terminal = ItemOpenerMenu(for: Self.notes, opener: .app("com.apple.Terminal", "Terminal"), target: Self.notesURL, catalog: catalog)
        #expect(terminal.currentStatus == .refused)
        #expect(terminal.choice(for: terminal.current) == nil)
        #expect(terminal.currentStatus.message(openerName: "Terminal") == "“Terminal” can't open this item safely, so the item won't open. Choose another app.")
        #expect(ItemOpenerStatus.available.message(openerName: "Code") == nil)
    }

    @Test func otherIsCheckedAsWhenTheItemOpens() {
        let (catalog, apps) = catalog()
        let check = { (url: URL, item: GroupItem, target: URL) in ItemOpenerMenu.check(url, for: item, target: target, catalog: catalog) }

        #expect(check(apps["code"]!, Self.notes, Self.notesURL) == .success(.app("com.microsoft.VSCode", "Visual Studio Code")))
        #expect(check(apps["terminal"]!, Self.projects, Self.projectsURL) == .success(.app("com.apple.Terminal", "Terminal")))
        #expect(check(apps["terminal"]!, Self.notes, Self.notesURL) == .failure(.runsItems(name: "Terminal")))
        #expect(check(apps["python"]!, Self.notes, Self.notesURL) == .failure(.runsItems(name: "Python Launcher")))
        // Installed, but macOS doesn't list it for a folder.
        #expect(check(apps["bbedit"]!, Self.projects, Self.projectsURL) == .failure(.notListed(name: "BBEdit")))
        // Not an app bundle, or a bundle without an identifier.
        #expect(check(URL(fileURLWithPath: "/usr/bin/python3"), Self.notes, Self.notesURL) == .failure(.notAnApp(name: "python3")))
        #expect(check(URL(fileURLWithPath: "/Applications/Nameless.app"), Self.notes, Self.notesURL) == .failure(.notAnApp(name: "Nameless")))
        // A bundle LaunchServices doesn't know by its identifier would open the item with its
        // default app instead: not taken.
        let unknown = URL(fileURLWithPath: "/Users/me/Downloads/Zed.app")
        let claims = FakeCatalog()
        claims.install("dev.zed.Zed", at: unknown.path)
        let unregistered = ItemOpenerMenu.check(unknown, for: Self.notes, target: Self.notesURL, catalog: UnregisteredCatalog(base: claims))
        #expect(unregistered == .failure(.unknownToMacOS(name: "Zed")))
    }

    @Test func refusalsSayWhy() {
        #expect(ItemOpenerRefusal.runsItems(name: "Terminal").message == "“Terminal” runs what it opens, so it can't open this item.")
        #expect(ItemOpenerRefusal.notListed(name: "BBEdit").message == "“BBEdit” isn't one of the apps macOS lists for this item.")
        #expect(ItemOpenerRefusal.notAnApp(name: "python3").message == "“python3” isn't an app that can open items.")
        #expect(ItemOpenerRefusal.unknownToMacOS(name: "Zed").message == "macOS doesn't know “Zed” yet. Open it once, then choose it again.")
    }
}

/// A catalog that reads bundles as `base` does but finds no app by bundle identifier: an app
/// LaunchServices hasn't registered.
@MainActor
private final class UnregisteredCatalog: ApplicationCatalog {
    let base: FakeCatalog

    init(base: FakeCatalog) {
        self.base = base
    }

    func applicationURL(forBundleIdentifier bundleIdentifier: String) -> URL? { nil }
    func applicationURLs(toOpen url: URL) -> [URL] { base.applicationURLs(toOpen: url) }
    func bundleIdentifier(ofApplicationAt url: URL) -> String? { base.bundleIdentifier(ofApplicationAt: url) }
}

@Suite("Launch options: rows and the popup")
@MainActor
struct LaunchOptionsTextTests {
    private static let folder = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Projects/cybokron"), kind: .folder)

    @Test func rowCaptions() {
        #expect(ItemLaunchCaption(item: Self.folder, isOpenerInstalled: nil) == nil)
        let code = Self.folder.launching(after: 3, with: .app("com.microsoft.VSCode", "Visual Studio Code"))
        #expect(ItemLaunchCaption(item: code, isOpenerInstalled: true)?.text == "Opens with Visual Studio Code · after 3 s")
        #expect(ItemLaunchCaption(item: code, isOpenerInstalled: nil)?.isOpenerMissing == false, "not checked yet: no warning")
        let report = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Report.pdf"), kind: .file).launching(with: .app("com.apple.Preview", "Preview"))
        let missing = ItemLaunchCaption(item: report, isOpenerInstalled: false)
        #expect(missing?.text == "Opens with Preview (not on this Mac: uses the default app)")
        #expect(missing?.isOpenerMissing == true)
        let slack = AppReference(bundleIdentifier: "com.tinyspeck.slackmacgap", name: "Slack").launching(after: 5)
        #expect(ItemLaunchCaption(item: slack, isOpenerInstalled: nil)?.text == "After 5 s")
    }

    @Test func popupTooltipsNameTheAppAndTheDelay() {
        let code = Self.folder.launching(after: 3, with: .app("com.microsoft.VSCode", "Visual Studio Code"))
        let text = PopupCellText(item: code, presence: .available(URL(fileURLWithPath: "/Users/me/Projects/cybokron")), isRunning: false, isEditable: true, isFreeLayout: false)
        #expect(text.help == .openWith(name: "cybokron", appName: "Visual Studio Code"))
        #expect(text.hint == .openWith(appName: "Visual Studio Code"))
        #expect(text.launchDelay == 3)
        #expect(text.launchDelayText == "Open All and Start open it after 3 seconds.")

        // A missing item still says it's missing; a website with a browser chosen says which.
        let gone = PopupCellText(item: code, presence: .missing, isRunning: false, isEditable: true, isFreeLayout: false)
        #expect(gone.help == .itemMissing(name: "cybokron"))
        let site = AppReference(websiteURL: URL(string: "https://github.com")!).launching(with: .app("com.google.Chrome", "Google Chrome"))
        #expect(PopupCellText(item: site, presence: .online, isRunning: false, isEditable: false, isFreeLayout: false).help == .openWith(name: site.displayName, appName: "Google Chrome"))

        let slack = AppReference(bundleIdentifier: "com.tinyspeck.slackmacgap", name: "Slack").launching(after: 1)
        let app = PopupCellText(item: slack, presence: .available(URL(fileURLWithPath: "/Applications/Slack.app")), isRunning: false, isEditable: false, isFreeLayout: false)
        #expect(app.help == .openApp(name: "Slack"))
        #expect(app.launchDelayText == "Open All and Start open it after 1 second.")
        #expect(PopupCellText(item: Self.folder, presence: .missing, isRunning: false, isEditable: false, isFreeLayout: false).launchDelayText == nil)
    }

    @Test func theGroupWindowLooksUpTheChosenAppsOnce() {
        let catalog = FakeCatalog()
        catalog.install("com.microsoft.VSCode")
        let locator = ScriptedLocator()
        let cache = ItemPresenceCache(locator: locator, catalog: catalog)
        let code = Self.folder.launching(with: .app("com.microsoft.VSCode", "Visual Studio Code"))
        let report = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Report.pdf"), kind: .file).launching(with: .app("com.apple.Preview", "Preview"))
        let plain = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/a.txt"), kind: .file)

        cache.track([code, report, plain])

        #expect(cache.isOpenerInstalled(code) == true)
        #expect(cache.isOpenerInstalled(report) == false)
        #expect(cache.isOpenerInstalled(plain) == nil)
        #expect(cache.installedOpeners.count == 2)
        // Without a catalog, chosen apps aren't checked.
        let unchecked = ItemPresenceCache(locator: locator)
        unchecked.track([code])
        #expect(unchecked.isOpenerInstalled(code) == nil)
    }
}

/// The app's wiring, read from its sources (the tests don't link the app target): delayed items
/// wait in the one `DelayedLaunches` that Start, Finish, Hide All and Close All cancel, in the main
/// app and in a standalone group's app, and the editor saves once.
@Suite("Launch options: the app's wiring")
struct LaunchOptionsWiringTests {
    @Test func delayedItemsShareOneQueueWithHideAndCloseAll() throws {
        for file in ["App/AppDelegate.swift", "Agent/AgentAppDelegate.swift"] {
            let url = LocalizationTests.root.appending(path: "Sources/CybokronDockGroups/\(file)")
            let source = try String(contentsOf: url, encoding: .utf8)
            #expect(source.contains("GroupLauncher(workspace: SystemApplicationWorkspace(), pendingLaunches: delayedLaunches)"), "\(file)")
            #expect(source.contains("pendingLaunches: delayedLaunches\n    )"), "\(file): the terminator cancels them")
            #expect(source.contains("delayedLaunches.cancelAll()"), "\(file): quitting cancels them")
        }
    }

    @Test func theEditorSavesItsDetailsAndLaunchOptionsOnce() throws {
        let source = try SettingsPaneTests.source("CybokronDockGroups", "MainWindow", "GroupDetailView.swift")
        #expect(source.contains("store.saveItemEdits(of: closed.draft, endingWith: ending, ofItem: closed.itemID, inGroup: group.id)"))
        #expect(!source.contains("store.saveDetails("))
        #expect(source.contains("ItemOpenerMenu.check(url, for: item, target: target, catalog: items.catalog)"), "Other… is checked")
    }
}
