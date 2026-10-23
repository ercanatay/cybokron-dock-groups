import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Group items: privacy-protected locations")
@MainActor
struct DeferringItemLocatorTests {
    private static let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)

    private static func file(_ path: String) -> GroupItem {
        GroupItem(fileURL: URL(fileURLWithPath: path), kind: .file)
    }

    @Test(arguments: [
        ("/Users/me/Documents/Q3 Report.pdf", true),
        ("/Users/me/Desktop", true),
        ("/Users/me/Downloads/archive.zip", true),
        ("/users/ME/documents/notes.txt", true),
        ("/Users/me/Library/Mobile Documents/com~apple~CloudDocs/Plan.key", true),
        ("/Users/me/Library/CloudStorage/Dropbox/Shots.zip", true),
        ("/Volumes/Backup SSD/Shots.zip", true),
        ("/Users/me/Projects/cybokron", false),
        ("/Users/me/DocumentsArchive/old.pdf", false),
        ("/Users/other/Documents/x.pdf", false),
        ("/Applications/Utilities", false),
    ])
    func protectedLocations(path: String, isProtected: Bool) {
        #expect(ProtectedLocations.contains(URL(fileURLWithPath: path), home: Self.home) == isProtected)
    }

    /// In a standalone group's own app, nothing there is looked at ahead of time.
    @Test func protectedFilesAndFoldersArentCheckedAheadOfTime() {
        let base = ScriptedLocator()
        let documents = Self.file("/Users/me/Documents/Q3 Report.pdf")
        let downloads = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Downloads/Invoices"), kind: .folder)
        base.set(.available(URL(fileURLWithPath: "/Users/me/Documents/Q3 Report.pdf")), for: documents)
        let locator = DeferringItemLocator(base: base, fileSystem: FakeProbe(error: CocoaError(.fileReadNoSuchFile)), home: Self.home)

        #expect(locator.presence(of: documents) == .unverified)
        #expect(locator.presence(of: downloads) == .unverified)
        #expect(base.presenceChecks.isEmpty)
    }

    /// Only a volume's mount point is looked at: an ejected one shows as such.
    @Test func itemsOnOtherVolumesOnlyHaveTheirVolumeChecked() {
        let base = ScriptedLocator()
        let probe = FakeProbe(error: CocoaError(.fileReadNoSuchFile), existingPaths: ["/Volumes/Work"])
        let locator = DeferringItemLocator(base: base, fileSystem: probe, home: Self.home)

        #expect(locator.presence(of: Self.file("/Volumes/Backup SSD/Shots.zip")) == .volumeUnavailable(name: "Backup SSD"))
        #expect(locator.presence(of: Self.file("/Volumes/Work/Plan.key")) == .unverified)
        #expect(base.presenceChecks.isEmpty)
    }

    @Test func everythingElseIsCheckedAsUsual() {
        let base = ScriptedLocator()
        let projects = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Projects"), kind: .folder)
        let mail = AppReference(bundleIdentifier: "com.apple.mail", name: "Mail")
        let website = AppReference(websiteURL: URL(string: "https://github.com")!)
        base.set(.available(URL(fileURLWithPath: "/Users/me/Projects")), for: projects)
        let locator = DeferringItemLocator(base: base, fileSystem: FakeProbe(error: CocoaError(.fileReadNoSuchFile)), home: Self.home)

        #expect(locator.presence(of: projects) == .available(URL(fileURLWithPath: "/Users/me/Projects")))
        #expect(locator.presence(of: mail) == .missing)
        #expect(locator.presence(of: website) == .online)
        #expect(base.presenceChecks.count == 3)

        // What a location is (adding, opening) is always asked of the real locator.
        base.typeInfos["/Users/me/Documents/x.pdf"] = .pdf
        #expect(locator.typeInfo(at: URL(fileURLWithPath: "/Users/me/Documents/x.pdf")) == .pdf)
    }
}
