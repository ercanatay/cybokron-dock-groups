import Foundation
import Testing
@testable import DockGroupsCore

/// Add Files or Folders… and Locate…: what the chosen locations become, and what the user is told
/// about the ones that can't be items.
@Suite("Group items: adding and locating")
@MainActor
struct ItemAdditionTests {
    private static func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    private func locator(_ infos: [String: ItemTypeInfo]) -> ScriptedLocator {
        let locator = ScriptedLocator()
        locator.typeInfos = infos
        return locator
    }

    /// Never reads a real bundle: an app chosen becomes this app item.
    private static func readApplication(_ url: URL) throws -> GroupItem {
        AppReference(bundleIdentifier: "com.example.\(url.deletingPathExtension().lastPathComponent.lowercased())", name: "App", path: url.path)
    }

    @Test func eachLocationBecomesTheItemOfItsKind() {
        let locator = locator([
            "/Users/me/Q3 Report.pdf": .pdf,
            "/Users/me/Projects": .plainFolder,
            "/Users/me/Notes.rtfd": .rtfd,
            "/Applications/Numbers.app": .appBundle,
        ])
        let chosen = ["/Users/me/Q3 Report.pdf", "/Users/me/Projects", "/Users/me/Notes.rtfd", "/Applications/Numbers.app"].map(Self.url)

        let result = ItemAddition.items(for: chosen, locator: locator, readApplication: Self.readApplication)

        #expect(result.problems.isEmpty)
        #expect(result.items.map(\.kind) == [.file, .folder, .file, .application])
        #expect(result.items[0].bundleIdentifier == "file:///Users/me/Q3%20Report.pdf")
        #expect(result.items[1].bundleIdentifier == "file:///Users/me/Projects/")
        #expect(result.items[2].name == "Notes.rtfd")
        #expect(result.items[3].bundleIdentifier == "com.example.numbers")
        // Files and folders never carry an app's location.
        #expect(result.items.prefix(3).allSatisfy { $0.path == nil })
    }

    /// Programs, scripts, installers and location files are refused by name and by type, with the
    /// item's own sentence (`core.item.error.program`); a location that can't be read is too.
    @Test func whatCantBeAnItemIsListedWithWhy() {
        let locator = locator([
            "/Users/me/run.command": .pdf,                  // refused by its name alone
            "/Users/me/notes": .shellScript,                // refused by its type
            "/Users/me/Q3 Report.pdf": .pdf,
        ])
        let chosen = ["/Users/me/run.command", "/Users/me/notes", "/Users/me/Locked.pdf", "/Users/me/Q3 Report.pdf"].map(Self.url)

        let result = ItemAddition.items(for: chosen, locator: locator, readApplication: Self.readApplication)

        #expect(result.items.map(\.name) == ["Q3 Report.pdf"])
        #expect(result.problems == [
            "“run.command” is a program or script, so it can't be added as a file.",
            "“notes” is a program or script, so it can't be added as a file.",
            "macOS didn't let the app check “Locked.pdf”.",
        ])
        #expect(result.problems[0] == FileItemRefusal.program(name: "run.command").localizedDescription)
    }

    @Test func anAppThatCantBeReadSaysSo() {
        let locator = locator(["/Applications/Broken.app": .appBundle])
        let result = ItemAddition.items(for: [Self.url("/Applications/Broken.app")], locator: locator) { url in
            throw AppReferenceError.notAnApplication(path: url.path)
        }
        #expect(result.items.isEmpty)
        #expect(result.problems == ["“Broken.app” isn't an app."])
    }

    /// The alert flow: the items that can be added are, and the reasons for the others reach the
    /// presenter once, all together; without problems nothing is presented.
    @Test func refusalsArePresentedOnceAfterTheOthersAreAdded() {
        let persistence = MemoryGroupPersistence()
        let store = GroupStore(persistence: persistence, saveDelay: .zero)
        let group = store.addGroup(named: "Finance")
        let locator = locator(["/Users/me/Q3 Report.pdf": .pdf, "/Users/me/Install.pkg": .pdf, "/Users/me/Projects": .plainFolder])
        var presented: [[String]] = []

        let added = ItemAddition.add(
            ["/Users/me/Q3 Report.pdf", "/Users/me/Install.pkg", "/Users/me/Projects"].map(Self.url),
            toGroup: group.id,
            in: store,
            locator: locator,
            readApplication: Self.readApplication
        ) { presented.append($0) }

        #expect(added == 2)
        #expect(store.group(withID: group.id)?.apps.map(\.name) == ["Q3 Report.pdf", "Projects"])
        #expect(presented == [["“Install.pkg” is a program or script, so it can't be added as a file."]])

        // Again: already there, skipped without a word.
        let again = ItemAddition.add([Self.url("/Users/me/Q3 Report.pdf")], toGroup: group.id, in: store, locator: locator) { presented.append($0) }
        #expect(again == 0)
        #expect(presented.count == 1)

        // Nothing chosen (cancelled): nothing checked, nothing presented.
        let checks = locator.typeInfoChecks.count
        #expect(ItemAddition.add([], toGroup: group.id, in: store, locator: locator) { presented.append($0) } == 0)
        #expect(locator.typeInfoChecks.count == checks)
        #expect(presented.count == 1)
    }

    @Test func locatingAcceptsOnlyAReadableItemOfTheSameKind() {
        let report = GroupItem(fileURL: Self.url("/Users/me/Old/Q3 Report.pdf"), kind: .file)
        let projects = GroupItem(fileURL: Self.url("/Users/me/Old/Projects"), kind: .folder)
        let locator = locator([
            "/Users/me/New/Q3 Report.pdf": .pdf,
            "/Users/me/New/Projects": .plainFolder,
            "/Users/me/New/run.sh": .shellScript,
        ])

        #expect(ItemAddition.relinkProblem(for: report, to: Self.url("/Users/me/New/Q3 Report.pdf"), locator: locator) == nil)
        #expect(ItemAddition.relinkProblem(for: projects, to: Self.url("/Users/me/New/Projects"), locator: locator) == nil)
        #expect(ItemAddition.relinkProblem(for: report, to: Self.url("/Users/me/New/Projects"), locator: locator)
                == "“Projects” isn't the same kind of item.")
        #expect(ItemAddition.relinkProblem(for: report, to: Self.url("/Users/me/New/run.sh"), locator: locator)
                == "“run.sh” is a program or script, so it can't be added as a file.")
        #expect(ItemAddition.relinkProblem(for: report, to: Self.url("/Users/me/New/Gone.pdf"), locator: locator)
                == "macOS didn't let the app check “Gone.pdf”.")
    }
}
