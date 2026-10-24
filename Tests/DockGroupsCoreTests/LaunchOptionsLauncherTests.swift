import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Launch options: opening with the chosen app")
@MainActor
struct LaunchOptionsLauncherTests {
    nonisolated private static let textInfo = ItemTypeInfo(typeIdentifiers: ["public.plain-text", "public.text", "public.data", "public.item"], isDirectory: false, isPackage: false)

    private let workspace = OpenerRecordingWorkspace()
    private let catalog = FakeCatalog()
    private let locator = ScriptedLocator()

    private func launcher(pending: DelayedLaunches? = nil) -> GroupLauncher {
        GroupLauncher(workspace: workspace, locator: locator, catalog: catalog, pendingLaunches: pending)
    }

    /// A file or folder item that's there, of the given type.
    private func item(_ path: String, kind: AppReference.Kind = .file, info: ItemTypeInfo = Self.textInfo) -> GroupItem {
        let url = URL(fileURLWithPath: path, isDirectory: kind == .folder)
        let item = GroupItem(fileURL: url, kind: kind)
        locator.set(.available(url), for: item)
        locator.typeInfos[url.standardizedFileURL.path] = info
        return item
    }

    private func outcomes(_ report: LaunchReport) -> [LaunchReport.Outcome] {
        report.entries.map(\.outcome)
    }

    private static func refused(_ name: String) -> LaunchReport.Outcome {
        .failed(reason: ItemOpeningError.openerRefused(name: name).localizedDescription)
    }

    @Test func itemsOpenWithTheirAppsOneRequestPerApp() async {
        let code = catalog.install("com.microsoft.VSCode", at: "/Applications/Visual Studio Code.app")
        let notes = item("/Users/me/notes.txt").launching(with: .app("com.microsoft.VSCode"))
        let todo = item("/Users/me/todo.txt").launching(with: .app("com.microsoft.VSCode"))
        let plain = item("/Users/me/plain.txt")
        catalog.list(code, for: notes.fileURL!)
        catalog.list(code, for: todo.fileURL!)

        let report = await launcher().openAll(DockGroup(name: "Notes", apps: [notes, plain, todo]))

        #expect(outcomes(report) == [.launched, .launched, .launched])
        #expect(workspace.events == ["files:plain.txt", "open:Visual Studio Code:notes.txt,todo.txt"])
    }

    @Test func anUninstalledAppFallsBackToTheDefaultApp() async {
        let notes = item("/Users/me/notes.txt").launching(with: .app("com.example.gone"))
        let report = await launcher().open(notes, inGroup: DockGroup(name: "Notes", apps: [notes]))
        #expect(outcomes(report) == [.launched])
        #expect(workspace.events == ["files:notes.txt"])
    }

    @Test func aRefusedAppOpensNothingNotEvenTheDefaultApp() async {
        catalog.install("com.apple.iWork.Numbers")
        let notes = item("/Users/me/notes.txt").launching(with: .app("com.apple.iWork.Numbers", "Numbers"))

        let report = await launcher().open(notes, inGroup: DockGroup(name: "Notes", apps: [notes]))

        #expect(outcomes(report) == [Self.refused("Numbers")])
        #expect(workspace.events.isEmpty)
    }

    @Test func websitesOpenWithTheirBrowsersAndTheRestTogether() async {
        let chrome = catalog.install("com.google.Chrome")
        let github = AppReference(websiteURL: URL(string: "https://github.com")!).launching(with: .app("com.google.Chrome"))
        let apple = AppReference(websiteURL: URL(string: "https://apple.com")!)
        let swift = AppReference(websiteURL: URL(string: "https://swift.org")!)
        let terminal = AppReference(websiteURL: URL(string: "https://example.com")!).launching(with: .app("com.apple.Terminal", "Terminal"))
        catalog.list(chrome, for: github.websiteURL!)
        let terminalURL = catalog.install("com.apple.Terminal", at: "/System/Applications/Utilities/Terminal.app")
        catalog.list(terminalURL, for: terminal.websiteURL!)

        let report = await launcher().openAll(DockGroup(name: "Web", apps: [github, apple, terminal, swift]))

        #expect(outcomes(report) == [.launched, .launched, Self.refused("Terminal"), .launched])
        #expect(workspace.events == ["websites:https://apple.com,https://swift.org", "open:Chrome:https://github.com"])
    }

    @Test func clickingAnItemOpensItRightAwayWhateverItsDelay() async {
        let sleeper = FakeSleeper()
        let pending = DelayedLaunches(sleeper: sleeper) { _ in nil }
        let notes = item("/Users/me/notes.txt").launching(after: 30)
        let report = await launcher(pending: pending).open(notes, inGroup: DockGroup(name: "Notes", apps: [notes]))
        #expect(outcomes(report) == [.launched])
        #expect(workspace.events == ["files:notes.txt"])
        #expect(sleeper.requested.isEmpty && !pending.hasPending)
    }

    @Test func aWorkspaceThatCantOpenWithAnAppRefuses() async {
        // `SwitchingWorkspace` doesn't implement `open(_:withApplicationAt:)`: the default refuses.
        let log = SwitchingLog()
        let code = catalog.install("com.microsoft.VSCode")
        let notes = item("/Users/me/notes.txt").launching(with: .app("com.microsoft.VSCode"))
        catalog.list(code, for: notes.fileURL!)
        let launcher = GroupLauncher(workspace: SwitchingWorkspace(log: log), locator: locator, catalog: catalog)

        let report = await launcher.open(notes, inGroup: DockGroup(name: "Notes", apps: [notes]))

        #expect(report.problems.count == 1)
        #expect(log.events.isEmpty)
    }

    @Test func theSystemWorkspaceOpensOnlyWithAppBundles() async {
        await #expect(throws: ItemOpeningError.self) {
            try await SystemApplicationWorkspace().open([URL(fileURLWithPath: "/tmp/notes.txt")], withApplicationAt: URL(fileURLWithPath: "/bin/sh"))
        }
    }

    // MARK: - Crafted groups files

    /// E-4: whatever a groups file says, launch options run nothing an item couldn't run on its own.
    /// Openers that run what they open are refused (Terminal and iTerm2 for a folder excepted), as
    /// are apps macOS doesn't list for the item; a program stays refused whatever app is named; and
    /// nothing refused falls back to the default app.
    @Test func aCraftedGroupsFileCantRunCodeThroughLaunchOptions() async throws {
        let terminal = catalog.install("com.apple.Terminal", at: "/System/Applications/Utilities/Terminal.app")
        let iTerm = catalog.install("com.googlecode.iterm2", at: "/Applications/iTerm.app")
        let python = catalog.install("org.python.PythonLauncher", at: "/Applications/Python 3.13/Python Launcher.app")
        catalog.install("com.apple.iWork.Numbers")
        let notesURL = URL(fileURLWithPath: "/Users/me/notes.txt")
        let commandURL = URL(fileURLWithPath: "/Users/me/run.command")
        // macOS lists the runners for these (as Terminal declares shell scripts).
        for runner in [terminal, iTerm, python] {
            catalog.list(runner, for: notesURL)
            catalog.list(runner, for: commandURL)
        }
        _ = item("/Users/me/notes.txt")
        _ = item("/Users/me/run.command", info: .shellScript)
        _ = item("/Users/me/Projects/cybokron", kind: .folder, info: .plainFolder)
        let groupsURL = try TemporaryDirectory()
        defer { groupsURL.remove() }
        let file = groupsURL.url.appending(path: "groups.json")
        func opener(_ id: String) -> String { #""openWith": { "bundleIdentifier": "\#(id)", "name": "\#(id)" }"# }
        try Data("""
        { "formatVersion": 1, "groups": [{ "id": "8D9A5E2C-6B1F-4F7E-9C3A-2B4D6E8F0A1B", "name": "Crafted", "apps": [
          { "bundleIdentifier": "file:///Users/me/notes.txt", "kind": "file", "name": "notes.txt", \(opener("com.apple.Terminal")) },
          { "bundleIdentifier": "file:///Users/me/notes.txt", "kind": "file", "name": "notes.txt", \(opener("com.googlecode.iterm2")) },
          { "bundleIdentifier": "file:///Users/me/notes.txt", "kind": "file", "name": "notes.txt", \(opener("org.python.PythonLauncher")) },
          { "bundleIdentifier": "file:///Users/me/notes.txt", "kind": "file", "name": "notes.txt", \(opener("com.apple.iWork.Numbers")) },
          { "bundleIdentifier": "file:///Users/me/run.command", "kind": "file", "name": "run.command", \(opener("com.apple.iWork.Numbers")) },
          { "bundleIdentifier": "file:///Users/me/run.command", "kind": "file", "name": "run.command", \(opener("com.apple.Terminal")) },
          { "bundleIdentifier": "https://example.com", "kind": "website", "name": "Example", \(opener("com.apple.Terminal")) },
          { "bundleIdentifier": "com.apple.mail", "name": "Mail", "path": "/Users/me/run.command", \(opener("com.apple.Terminal")) },
          { "bundleIdentifier": "file:///Users/me/Projects/cybokron/", "kind": "folder", "name": "cybokron", \(opener("com.apple.Terminal")) }
        ]}]}
        """.utf8).write(to: file)
        // Duplicate identities are kept as written here: every line is opened on its own.
        let items = try JSONFileGroupPersistence(fileURL: file).loadGroups()[0].apps

        var results: [LaunchReport.Outcome] = []
        for item in items {
            results += outcomes(await launcher().open(item, inGroup: DockGroup(name: "Crafted", apps: [item])))
        }

        let programRefused = LaunchReport.Outcome.failed(reason: FileItemOpeningError.refused.localizedDescription)
        #expect(results == [
            Self.refused("com.apple.Terminal"),
            Self.refused("com.googlecode.iterm2"),
            Self.refused("org.python.PythonLauncher"),
            Self.refused("com.apple.iWork.Numbers"),
            programRefused,
            programRefused,
            Self.refused("com.apple.Terminal"),
            .notFound,
            .launched,
        ])
        // The only thing opened: the folder, in Terminal, as allowed for folders.
        #expect(workspace.events == ["open:Terminal:cybokron"])
        #expect(items[7].launch.opener == nil, "an app keeps no opener")
    }
}
