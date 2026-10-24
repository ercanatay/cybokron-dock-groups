import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Launch options: the app that opens an item")
@MainActor
struct ItemOpenerPolicyTests {
    private static let notes = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/notes.txt"), kind: .file)
    private static let projects = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Projects/cybokron"), kind: .folder)
    private static let github = AppReference(websiteURL: URL(string: "https://github.com")!)
    private static let notesURL = URL(fileURLWithPath: "/Users/me/notes.txt")
    private static let projectsURL = URL(fileURLWithPath: "/Users/me/Projects/cybokron", isDirectory: true)

    private func decide(_ item: GroupItem, _ opener: ItemOpener?, target: URL, _ catalog: FakeCatalog) -> ItemOpenerDecision {
        ItemOpenerPolicy.decide(opener, for: item, target: target, catalog: catalog)
    }

    @Test func noOpenerOrAnAppMeansTheDefaultApp() {
        let catalog = FakeCatalog()
        #expect(decide(Self.notes, nil, target: Self.notesURL, catalog) == .defaultApp)
        let app = AppReference(bundleIdentifier: "com.apple.mail", name: "Mail")
        #expect(decide(app, .app("com.apple.Terminal"), target: Self.notesURL, catalog) == .defaultApp)
        #expect(catalog.listingQuestions == 0, "nothing to ask LaunchServices")
    }

    @Test func anOpenerThatIsntOnThisMacFallsBackToTheDefaultApp() {
        #expect(decide(Self.notes, .app("com.example.gone"), target: Self.notesURL, FakeCatalog()) == .defaultApp)
    }

    @Test func aListedAppOpensTheItem() {
        let catalog = FakeCatalog()
        let code = catalog.install("com.microsoft.VSCode", at: "/Applications/Visual Studio Code.app")
        catalog.list(code, for: Self.notesURL)
        catalog.list(code, for: Self.projectsURL)
        let chrome = catalog.install("com.google.Chrome")
        catalog.list(chrome, for: Self.github.websiteURL!)

        #expect(decide(Self.notes, .app("com.microsoft.VSCode"), target: Self.notesURL, catalog) == .openWith(code))
        // Bundle identifiers compare as LaunchServices compares them, ignoring case.
        #expect(decide(Self.projects, .app("COM.MICROSOFT.VSCODE"), target: Self.projectsURL, catalog) == .openWith(code))
        #expect(decide(Self.github, .app("com.google.Chrome"), target: Self.github.websiteURL!, catalog) == .openWith(chrome))
    }

    @Test func anAppMacOSDoesntListForTheItemIsRefused() {
        let catalog = FakeCatalog()
        let numbers = catalog.install("com.apple.iWork.Numbers")
        catalog.list(numbers, for: URL(fileURLWithPath: "/Users/me/sheet.numbers"))
        #expect(decide(Self.notes, .app("com.apple.iWork.Numbers", "Numbers"), target: Self.notesURL, catalog) == .refused(openerName: "Numbers"))
    }

    @Test func appsThatRunWhatTheyOpenAreRefusedEvenWhenListed() {
        let catalog = FakeCatalog()
        for runner in ["com.apple.Terminal", "com.googlecode.iterm2", "org.python.PythonLauncher", "dev.warp.Warp-Stable", "com.apple.installer", "com.apple.ScriptEditor.id.Cleanup"] {
            let url = catalog.install(runner, at: "/Applications/\(runner).app")
            catalog.list(url, for: Self.notesURL)
            catalog.list(url, for: Self.github.websiteURL!)
            #expect(decide(Self.notes, .app(runner), target: Self.notesURL, catalog) == .refused(openerName: runner), "\(runner)")
            #expect(decide(Self.github, .app(runner), target: Self.github.websiteURL!, catalog) == .refused(openerName: runner), "\(runner)")
        }
    }

    @Test func terminalAndITermOpenFoldersOnly() {
        let catalog = FakeCatalog()
        let terminal = catalog.install("com.apple.Terminal", at: "/System/Applications/Utilities/Terminal.app")
        let iTerm = catalog.install("com.googlecode.iterm2", at: "/Applications/iTerm.app")
        // macOS doesn't list them for folders; they're allowed anyway, for folder items.
        #expect(decide(Self.projects, .app("com.apple.Terminal"), target: Self.projectsURL, catalog) == .openWith(terminal))
        #expect(decide(Self.projects, .app("com.googlecode.iterm2"), target: Self.projectsURL, catalog) == .openWith(iTerm))
        // Not for files, even listed, nor for websites; other terminals not for folders either.
        catalog.list(terminal, for: Self.notesURL)
        #expect(decide(Self.notes, .app("com.apple.Terminal", "Terminal"), target: Self.notesURL, catalog) == .refused(openerName: "Terminal"))
        #expect(decide(Self.github, .app("com.apple.Terminal", "Terminal"), target: Self.github.websiteURL!, catalog) == .refused(openerName: "Terminal"))
        let warp = catalog.install("dev.warp.Warp-Stable")
        catalog.list(warp, for: Self.projectsURL)
        #expect(decide(Self.projects, .app("dev.warp.Warp-Stable", "Warp"), target: Self.projectsURL, catalog) == .refused(openerName: "Warp"))
        #expect(ItemOpenerPolicy.acceptsOpener(bundleIdentifier: "com.apple.Terminal", for: .folder))
        #expect(!ItemOpenerPolicy.acceptsOpener(bundleIdentifier: "com.apple.Terminal", for: .file))
    }

    @Test func anOpenerMustBeTheAppBundleItClaimsToBe() {
        let catalog = FakeCatalog()
        // Not an app bundle, though LaunchServices answered with it.
        let tool = catalog.install("com.example.tool", at: "/usr/local/bin/tool")
        catalog.list(tool, for: Self.notesURL)
        #expect(decide(Self.notes, .app("com.example.tool", "Tool"), target: Self.notesURL, catalog) == .refused(openerName: "Tool"))
        // An app bundle whose own bundle identifier is another app's (a Terminal in disguise).
        let fake = catalog.install("com.example.editor", at: "/Applications/Editor.app", claims: "com.apple.Terminal")
        catalog.list(fake, for: Self.notesURL)
        #expect(decide(Self.notes, .app("com.example.editor", "Editor"), target: Self.notesURL, catalog) == .refused(openerName: "Editor"))
        // A folder terminal must be one too.
        catalog.install("com.apple.Terminal", at: "/Users/me/Downloads/Terminal.app", claims: "com.example.dropper")
        #expect(decide(Self.projects, .app("com.apple.Terminal", "Terminal"), target: Self.projectsURL, catalog) == .refused(openerName: "Terminal"))
    }

    @Test func runnersAreKnownByIdentifier() {
        for runner in ["com.apple.Terminal", "COM.GOOGLECODE.ITERM2", "net.kovidgoyal.kitty", "com.mitchellh.ghostty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper", "com.apple.Automator.Automator-Application-Stub", "com.apple.ScriptEditor.id.anything"] {
            #expect(ItemOpenerPolicy.isRunner(bundleIdentifier: runner), "\(runner)")
        }
        for app in ["com.microsoft.VSCode", "com.apple.Preview", "com.apple.TextEdit", "com.google.Chrome", "com.apple.ScriptEditor2", "com.apple.finder"] {
            #expect(!ItemOpenerPolicy.isRunner(bundleIdentifier: app), "\(app)")
        }
    }

    @Test func refusalsSayWhichApp() {
        #expect(ItemOpeningError.openerRefused(name: "Terminal").localizedDescription == "wasn't opened with “Terminal”, because that app can't open it safely.")
    }
}
