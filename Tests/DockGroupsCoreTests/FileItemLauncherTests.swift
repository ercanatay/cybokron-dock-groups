import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Group items: opening")
@MainActor
struct FileItemLauncherTests {
    private let directory: TemporaryDirectory

    init() throws {
        directory = try TemporaryDirectory()
    }

    private func write(_ name: String, _ text: String = "x", executable: Bool = false) throws -> URL {
        let url = directory.url.appending(path: name, directoryHint: .notDirectory)
        try Data(text.utf8).write(to: url)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return url
    }

    private func makeFolder(_ name: String) throws -> URL {
        let url = directory.url.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func link(_ name: String, to destination: URL) throws -> URL {
        let url = directory.url.appending(path: name, directoryHint: .notDirectory)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
        return url
    }

    private static func file(_ url: URL) -> GroupItem { GroupItem(fileURL: url, kind: .file) }
    private static func folder(_ url: URL) -> GroupItem { GroupItem(fileURL: url, kind: .folder) }

    private static let refused = LaunchReport.Outcome.failed(reason: FileItemOpeningError.refused.localizedDescription)
    private static let unchecked = LaunchReport.Outcome.failed(reason: FileItemOpeningError.unchecked.localizedDescription)

    private func open(_ item: GroupItem, workspace: FileRecordingWorkspace, locator: ItemLocating? = nil) async -> LaunchReport.Outcome? {
        await GroupLauncher(workspace: workspace, locator: locator)
            .open(item, inGroup: DockGroup(name: "Files", apps: [item]))
            .entries.first?.outcome
    }

    // MARK: - Opening

    @Test func aFileOrFolderOpensInOneRequest() async throws {
        defer { directory.remove() }
        let report = try write("Q3 Report.pdf")
        let projects = try makeFolder("Projects")
        let workspace = FileRecordingWorkspace()

        #expect(await open(Self.file(report), workspace: workspace) == .launched)
        #expect(await open(Self.folder(projects), workspace: workspace) == .launched)

        #expect(workspace.fileRequests.map { $0.map(\.lastPathComponent) } == [["Q3 Report.pdf"], ["Projects"]])
        #expect(workspace.launched.isEmpty && workspace.activated.isEmpty && workspace.websiteRequests.isEmpty)
    }

    @Test func aMissingOrChangedItemIsNotFoundAndNothingIsOpened() async throws {
        defer { directory.remove() }
        let workspace = FileRecordingWorkspace()
        let gone = Self.file(directory.url.appending(path: "Gone.pdf"))
        // A file that's now a folder, and the reverse. (A folder named "Plan.key" would be a
        // Keynote document package: a file.)
        let nowFolder = Self.file(try makeFolder("Plan.txt"))
        let nowFile = Self.folder(try write("Photos"))

        for item in [gone, nowFolder, nowFile] {
            #expect(await open(item, workspace: workspace) == .notFound)
        }
        #expect(workspace.fileRequests.isEmpty)
    }

    /// F1-6: whatever a groups file says, a file item never runs code: scripts, executables, app
    /// bundles and location or alias files are refused by name and by type — symbolic links
    /// followed — before the workspace is asked anything.
    @Test func programsScriptsAndLocationFilesAreNeverOpened() async throws {
        defer { directory.remove() }
        let command = try write("run.command", "#!/bin/sh\necho hi\n")
        let disguised = try link("Invoice.pdf", to: command)
        let executable = try write("tool", "#!/bin/sh\necho hi\n", executable: true)
        let disguisedExecutable = try link("Notes.txt", to: executable)
        let python = try write("job.py", "print(1)\n")
        let webloc = try write("Home.webloc", "<plist/>")
        let appBundle = try directory.makeAppBundle(named: "Tool", info: ["CFBundleIdentifier": "com.example.tool"])
        let alias = directory.url.appending(path: "Shortcut")
        try URL.writeBookmarkData(try command.bookmarkData(options: .suitableForBookmarkFile), to: alias)
        let workspace = FileRecordingWorkspace()

        let items = [
            Self.file(command), Self.file(disguised), Self.file(executable), Self.file(disguisedExecutable),
            Self.file(python), Self.file(webloc), Self.file(appBundle), Self.folder(appBundle), Self.file(alias),
        ]
        for item in items {
            #expect(await open(item, workspace: workspace) == Self.refused, "\(item.name)")
        }
        #expect(workspace.fileRequests.isEmpty)
        #expect(workspace.launched.isEmpty)
    }

    @Test func aFileOnADisconnectedVolumeOrOneThatCantBeCheckedIsntOpened() async throws {
        defer { directory.remove() }
        let workspace = FileRecordingWorkspace()
        let volume = "CybokronTest-\(UUID().uuidString)"
        let onVolume = Self.file(URL(fileURLWithPath: "/Volumes/\(volume)/x.pdf"))

        #expect(await open(onVolume, workspace: workspace) == .failed(reason: FileItemOpeningError.volumeUnavailable(name: volume).localizedDescription))
        let refusing = WorkspaceItemLocator(fileSystem: FakeProbe(error: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))))
        #expect(await open(Self.file(URL(fileURLWithPath: "/Users/me/Documents/x.pdf")), workspace: workspace, locator: refusing) == Self.unchecked)
        #expect(workspace.fileRequests.isEmpty)
    }

    @Test func aFailureOfTheWorkspaceIsReportedForThatItemOnly() async throws {
        defer { directory.remove() }
        let report = try write("Report.pdf")
        let plan = try write("Plan.key")
        let workspace = FileRecordingWorkspace(failing: [plan.resolvingSymlinksInPath()])

        let result = await GroupLauncher(workspace: workspace).openAll(DockGroup(name: "Files", apps: [Self.file(report), Self.file(plan)]))

        #expect(result.entries.map(\.outcome) == [.launched, .failed(reason: FileItemOpeningError.noHandler(name: "Plan.key").localizedDescription)])
        #expect(workspace.fileRequests.count == 1)
    }

    @Test func openAllOpensAppsThenFilesAndFoldersThenWebsitesInGroupOrder() async throws {
        defer { directory.remove() }
        let mail = AppReference(bundleIdentifier: "com.apple.mail", name: "Mail")
        let notes = AppReference(bundleIdentifier: "com.apple.Notes", name: "Notes")
        let github = AppReference(websiteURL: URL(string: "https://github.com")!)
        let report = Self.file(try write("Report.pdf"))
        let projects = Self.folder(try makeFolder("Projects"))
        let gone = Self.file(directory.url.appending(path: "Gone.pdf"))
        let workspace = FileRecordingWorkspace(installed: [mail.bundleIdentifier, notes.bundleIdentifier])
        let group = DockGroup(name: "Work", apps: [report, mail, github, gone, projects, notes])

        let result = await GroupLauncher(workspace: workspace).openAll(group)

        #expect(result.entries.map(\.app) == group.apps)
        #expect(result.entries.map(\.outcome) == [.launched, .launched, .launched, .notFound, .launched, .launched])
        #expect(workspace.fileRequests.map { $0.map(\.lastPathComponent) } == [["Report.pdf", "Projects"]])
        #expect(workspace.calls == ["launch", "launch", "files", "websites"])
    }

    // MARK: - Crafted groups files

    /// F1-6 for groups.json, which isn't cleaned up like a backup: only the real document opens,
    /// and nothing at all is started as an app.
    @Test func aCraftedGroupsFileCantRunAScript() async throws {
        defer { directory.remove() }
        let command = try write("run.command", "#!/bin/sh\necho hi\n")
        let executable = try write("tool", "#!/bin/sh\necho hi\n", executable: true)
        let disguised = try link("Invoice.pdf", to: command)
        let report = try write("Report.pdf")
        func identity(_ url: URL) -> String { FileLocation.identity(for: url, kind: .file) }
        let groupsURL = directory.url.appending(path: "groups.json")
        try Data("""
        { "formatVersion": 1, "groups": [{ "id": "8D9A5E2C-6B1F-4F7E-9C3A-2B4D6E8F0A1B", "name": "Crafted", "apps": [
          { "bundleIdentifier": "\(identity(command))", "kind": "file", "name": "Report.pdf" },
          { "bundleIdentifier": "\(identity(executable))", "kind": "file", "name": "Notes" },
          { "bundleIdentifier": "\(identity(disguised))", "kind": "file", "name": "Invoice.pdf" },
          { "bundleIdentifier": "\(identity(command))", "name": "No kind" },
          { "bundleIdentifier": "\(command.path)", "kind": "file", "name": "A path, not a file URL" },
          { "bundleIdentifier": "com.example.mail", "kind": "file", "name": "An identity of an app", "path": "\(command.path)" },
          { "bundleIdentifier": "com.example.notes", "name": "An app at a script", "path": "\(command.path)" },
          { "bundleIdentifier": "\(identity(report))", "kind": "file", "name": "Report" }
        ]}]}
        """.utf8).write(to: groupsURL)
        let groups = try JSONFileGroupPersistence(fileURL: groupsURL).loadGroups()
        let group = try #require(groups.first)
        // Apps are located as the real workspace locates them (`resolvedURL`): by bundle
        // identifier, else at their saved location — which here is a script.
        let workspace = FileRecordingWorkspace(locatesByResolvedURL: true)

        let result = await GroupLauncher(workspace: workspace).openAll(group)

        #expect(workspace.fileRequests.map { $0.map(\.lastPathComponent) } == [["Report.pdf"]])
        #expect(workspace.launched.isEmpty)
        #expect(result.entries.map(\.outcome) == [Self.refused, Self.refused, Self.refused, Self.refused, .notFound, .notFound, .notFound, .launched])
    }
}

// MARK: - Handlers and messages

@Suite("Group items: default apps")
struct FileItemHandlerTests {
    @Test func appsThatWouldRunAFileAreRefusedAsItsDefaultApp() {
        #expect(FileItemPolicy.refusesHandler(bundleIdentifier: "com.apple.Terminal"))
        #expect(FileItemPolicy.refusesHandler(bundleIdentifier: "com.googlecode.iterm2"))
        #expect(FileItemPolicy.refusesHandler(bundleIdentifier: "com.apple.installer"))
        #expect(!FileItemPolicy.refusesHandler(bundleIdentifier: "com.apple.TextEdit"))
        #expect(!FileItemPolicy.refusesHandler(bundleIdentifier: "com.apple.finder"))
        #expect(!FileItemPolicy.refusesHandler(bundleIdentifier: "com.apple.Preview"))
    }

    @Test func messagesFollowTheItemsName() {
        #expect(FileItemOpeningError.refused.localizedDescription == "wasn't opened, because programs and scripts open only as apps.")
        #expect(FileItemOpeningError.noHandler(name: "x.zzz").localizedDescription == "No app on this Mac opens “x.zzz”.")
        #expect(FileItemOpeningError.volumeUnavailable(name: "Backup SSD").localizedDescription == "It's on “Backup SSD”, which isn't connected.")
        #expect(FileItemOpeningError.unchecked.localizedDescription == "wasn't opened, because macOS didn't allow checking what it is.")
    }
}

/// Records what it's asked to open instead of opening it.
@MainActor
private final class FileRecordingWorkspace: ApplicationWorkspace {
    private let installed: Set<String>
    private let failing: Set<URL>
    private let locatesByResolvedURL: Bool
    private(set) var activated: [String] = []
    private(set) var launched: [URL] = []
    private(set) var websiteRequests: [[URL]] = []
    private(set) var fileRequests: [[URL]] = []
    private(set) var revealed: [[URL]] = []
    /// "launch", "files" and "websites", in the order they happened.
    private(set) var calls: [String] = []

    init(installed: Set<String> = [], failing: Set<URL> = [], locatesByResolvedURL: Bool = false) {
        self.installed = installed
        self.failing = failing
        self.locatesByResolvedURL = locatesByResolvedURL
    }

    func activateRunningApplication(bundleIdentifier: String) -> Bool { false }

    func locateApplication(_ app: AppReference) -> URL? {
        if locatesByResolvedURL {
            // As `AppReference.resolvedURL`, minus LaunchServices: the saved location, if it exists.
            guard let location = app.path ?? (app.isIdentifiedByPath ? app.bundleIdentifier : nil),
                  FileManager.default.fileExists(atPath: location)
            else { return nil }
            return URL(fileURLWithPath: location)
        }
        return installed.contains(app.bundleIdentifier) ? URL(fileURLWithPath: "/Applications/\(app.bundleIdentifier).app") : nil
    }

    func launchApplication(at url: URL) async throws {
        launched.append(url)
        calls.append("launch")
    }

    func openWebsites(_ urls: [URL]) async throws {
        websiteRequests.append(urls)
        calls.append("websites")
    }

    func openFileItems(_ urls: [URL]) async -> [URL: any Error] {
        fileRequests.append(urls)
        calls.append("files")
        var failures: [URL: any Error] = [:]
        for url in urls where failing.contains(url) {
            failures[url] = FileItemOpeningError.noHandler(name: url.lastPathComponent)
        }
        return failures
    }

    func revealFileItems(_ urls: [URL]) {
        revealed.append(urls)
    }
}
