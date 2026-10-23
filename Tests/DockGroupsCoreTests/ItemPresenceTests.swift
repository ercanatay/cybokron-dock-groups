import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Group items: presence")
@MainActor
struct ItemPresenceTests {
    private let directory: TemporaryDirectory

    init() throws {
        directory = try TemporaryDirectory()
    }

    private func write(_ name: String, _ text: String = "x") throws -> URL {
        let url = directory.url.appending(path: name, directoryHint: .notDirectory)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func makeFolder(_ name: String) throws -> URL {
        let url = directory.url.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func resolved(_ url: URL) -> URL {
        url.resolvingSymlinksInPath()
    }

    @Test func aFileOrFolderThatsThereIsAvailableWhereItResolvesTo() throws {
        defer { directory.remove() }
        let report = try write("Q3 Report.pdf")
        let projects = try makeFolder("Projects")
        let link = directory.url.appending(path: "Report link.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: report)
        let locator = WorkspaceItemLocator()

        #expect(locator.presence(of: GroupItem(fileURL: report, kind: .file)) == .available(Self.resolved(report)))
        #expect(locator.presence(of: GroupItem(fileURL: projects, kind: .folder)).location?.path == Self.resolved(projects).path)
        #expect(locator.presence(of: GroupItem(fileURL: link, kind: .file)) == .available(Self.resolved(report)))
        // A document package is a file.
        let package = try makeFolder("Notes.rtfd")
        #expect(locator.presence(of: GroupItem(fileURL: package, kind: .file)).location != nil)
        #expect(locator.presence(of: GroupItem(fileURL: package, kind: .folder)) == .missing)
    }

    @Test func aDeletedFileOrOneOfAnotherKindIsMissing() throws {
        defer { directory.remove() }
        let report = try write("Report.pdf")
        let item = GroupItem(fileURL: report, kind: .file)
        let locator = WorkspaceItemLocator()
        try FileManager.default.removeItem(at: report)

        #expect(locator.presence(of: item) == .missing)

        // Now a folder of that name: not the file it was.
        _ = try makeFolder("Report.pdf")
        #expect(locator.presence(of: item) == .missing)
        let folderItem = GroupItem(fileURL: try write("Plans"), kind: .folder)
        #expect(locator.presence(of: folderItem) == .missing)
        #expect(!ItemPresence.missing.isOpenable)
    }

    @Test func anItemOnAVolumeThatIsntConnected() {
        defer { directory.remove() }
        let volume = "CybokronTest-\(UUID().uuidString)"
        let item = GroupItem(fileURL: URL(fileURLWithPath: "/Volumes/\(volume)/Shots/x.zip"), kind: .file)

        let presence = WorkspaceItemLocator().presence(of: item)

        #expect(presence == .volumeUnavailable(name: volume))
        #expect(!presence.isOpenable)
        // On a connected volume (the startup disk's own entry), a missing file is just missing.
        let probe = FakeProbe(error: CocoaError(.fileReadNoSuchFile), existingPaths: ["/Volumes/Backup"])
        let onConnected = GroupItem(fileURL: URL(fileURLWithPath: "/Volumes/Backup/x.zip"), kind: .file)
        #expect(WorkspaceItemLocator(fileSystem: probe).presence(of: onConnected) == .missing)
    }

    @Test(arguments: [
        NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)),
        NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)),
        NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoPermission.rawValue, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)),
        ]),
        NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadUnknown.rawValue),
    ])
    func whenMacOSRefusesTheCheckTheItemIsUnverified(error: NSError) {
        defer { directory.remove() }
        let locator = WorkspaceItemLocator(fileSystem: FakeProbe(error: error))
        let item = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Documents/x.pdf"), kind: .file)

        let presence = locator.presence(of: item)

        #expect(presence == .unverified)
        #expect(presence.isOpenable)
        #expect(locator.typeInfo(at: URL(fileURLWithPath: "/Users/me/Documents/x.pdf")) == nil)
    }

    @Test func errorsThatMeanNothingIsThere() {
        defer { directory.remove() }
        #expect(WorkspaceItemLocator.meansNotThere(CocoaError(.fileReadNoSuchFile)))
        #expect(WorkspaceItemLocator.meansNotThere(CocoaError(.fileNoSuchFile)))
        #expect(WorkspaceItemLocator.meansNotThere(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))))
        #expect(WorkspaceItemLocator.meansNotThere(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR))))
        #expect(WorkspaceItemLocator.meansNotThere(NSError(domain: "Other", code: 1, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)),
        ])))
        #expect(!WorkspaceItemLocator.meansNotThere(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))))
        #expect(!WorkspaceItemLocator.meansNotThere(CocoaError(.fileReadNoPermission)))
    }

    @Test func websitesAreOnlineAndAppsAreLookedUp() throws {
        defer { directory.remove() }
        let locator = WorkspaceItemLocator()
        #expect(locator.presence(of: AppReference(websiteURL: URL(string: "https://github.com")!)) == .online)
        // An app identified by its location is only looked for there (no LaunchServices lookup).
        let bundle = try directory.makeAppBundle(named: "Tool", info: [:])
        let app = try AppReference(applicationURL: bundle)
        #expect(app.isIdentifiedByPath)
        #expect(locator.presence(of: app).location?.path == bundle.path)
        try FileManager.default.removeItem(at: bundle)
        #expect(locator.presence(of: app) == .missing)
    }

    @Test func typesAreReadFromTheFileSystemSymbolicLinksFollowed() throws {
        defer { directory.remove() }
        let script = try write("run.command", "echo hi\n")
        let link = directory.url.appending(path: "Invoice.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: script)
        let locator = WorkspaceItemLocator()

        let info = try #require(locator.typeInfo(at: link))
        #expect(info.typeIdentifiers.contains("public.script"))
        #expect(!info.isDirectory)
        #expect(FileItemPolicy.refusal(for: info, name: "Invoice.pdf") == .program(name: "Invoice.pdf"))
        let folder = try #require(locator.typeInfo(at: try makeFolder("Plain")))
        #expect(folder.itemKind == .folder)
        #expect(FileItemPolicy.refusal(for: folder, name: "Plain") == nil)
    }
}

/// A file system where every item fails to be read with `error`, and only `existingPaths` exist.
struct FakeProbe: FileSystemProbing {
    var error: Error
    var existingPaths: Set<String> = []

    func resolvingSymbolicLinks(in url: URL) -> URL { url }
    func typeInfo(at url: URL) throws -> ItemTypeInfo { throw error }
    func itemExists(atPath path: String) -> Bool { existingPaths.contains(path) }
}
