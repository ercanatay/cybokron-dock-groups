import Foundation
import Testing
@testable import DockGroupsCore

/// The second line of an item's row in the group window.
@Suite("Group items: group window rows")
struct ItemRowStatusTests {
    private static let home = "/Users/me"
    private static let mail = AppReference(bundleIdentifier: "com.apple.mail", name: "Mail")
    private static let scriptApp = AppReference(bundleIdentifier: "/Users/me/Applications/Tool.app", name: "Tool")
    private static let github = AppReference(websiteURL: URL(string: "https://github.com")!)
    private static let report = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Desktop/Old Plan.key"), kind: .file)
    private static let shots = GroupItem(fileURL: URL(fileURLWithPath: "/Volumes/Backup SSD/Shots.zip"), kind: .file)
    private static let projects = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Projects/cybokron"), kind: .folder)

    private func status(_ item: GroupItem, _ presence: ItemPresence?) -> ItemRowStatus {
        ItemRowStatus(item: item, presence: presence, home: Self.home)
    }

    @Test func appsAndWebsitesShowWhatTheyAlwaysDid() {
        let found = ItemPresence.available(URL(fileURLWithPath: "/System/Applications/Mail.app"))
        #expect(status(Self.mail, found) == .identity("com.apple.mail"))
        #expect(status(Self.mail, .missing) == .appNotFound("com.apple.mail"))
        #expect(status(Self.scriptApp, .missing) == .appNotFound("~/Applications/Tool.app"))
        #expect(status(Self.github, .online) == .identity("https://github.com"))
    }

    @Test func filesAndFoldersShowTheirLocation() {
        #expect(status(Self.projects, .available(URL(fileURLWithPath: "/Users/me/Projects/cybokron"))) == .identity("~/Projects/cybokron"))
        #expect(status(Self.shots, nil) == .identity("/Volumes/Backup SSD/Shots.zip"))
    }

    /// A missing item stays visible: dimmed, with where it was, and can be located.
    @Test func whatsWrongIsSaid() {
        let missing = status(Self.report, .missing)
        #expect(missing == .missing(location: "~/Desktop/Old Plan.key"))
        #expect(missing.isProblem)

        let ejected = status(Self.shots, .volumeUnavailable(name: "Backup SSD"))
        #expect(ejected == .volumeUnavailable(volume: "Backup SSD", location: "/Volumes/Backup SSD/Shots.zip"))
        #expect(ejected.isProblem)

        let unchecked = status(Self.report, .unverified)
        #expect(unchecked == .unverified(location: "~/Desktop/Old Plan.key"))
        #expect(!unchecked.isProblem)

        // Not checked yet: no verdict.
        #expect(!status(Self.report, nil).isProblem)
    }

    @Test(arguments: [
        ("/Users/me/Documents/a.pdf", "~/Documents/a.pdf"),
        ("/Users/me", "~"),
        ("/Users/meadow/a.pdf", "/Users/meadow/a.pdf"),
        ("/Applications/Safari.app", "/Applications/Safari.app"),
    ])
    func homeIsWrittenAsATilde(path: String, shown: String) {
        #expect(ItemRowStatus.abbreviated(path, home: Self.home) == shown)
        #expect(ItemRowStatus.abbreviated(path, home: Self.home + "/") == shown)
    }
}
