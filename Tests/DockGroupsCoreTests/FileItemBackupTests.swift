import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Group items: backups")
@MainActor
struct FileItemBackupTests {
    private static let mail = AppReference(bundleIdentifier: "com.apple.mail", name: "Mail")
    private static let report = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Documents/Q3 Report.pdf"), kind: .file)
    private static let projects = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Projects"), kind: .folder)

    private static func backup(_ groups: [DockGroup]) -> SettingsBackup {
        SettingsBackup(appVersion: "0.6.8", exportedAt: Date(timeIntervalSince1970: 1_792_000_000), groups: groups, preferences: PopupPreferences())
    }

    /// A backup whose only group holds `items` (JSON objects), as a hand-crafted file would.
    private static func craftedBackup(items: [String], freeLayoutSlots: String = "{}") -> Data {
        Data("""
        {
          "schemaVersion": 1,
          "app": "cybokron-dock-groups",
          "groups": [{
            "id": "8D9A5E2C-6B1F-4F7E-9C3A-2B4D6E8F0A1B",
            "name": "Crafted",
            "apps": [\(items.joined(separator: ","))],
            "freeLayoutSlots": \(freeLayoutSlots)
          }],
          "preferences": { "formatVersion": 1 }
        }
        """.utf8)
    }

    @Test func filesFoldersAndDetailsSurviveABackup() throws {
        var report = Self.report
        report.details = ItemDetails(alias: "Quarterly report", tags: ["finance", "q3"], notes: "Send the totals\non Fridays")
        let groups = [DockGroup(
            name: "Work",
            apps: [Self.mail, report, Self.projects],
            freeLayoutSlots: [report.normalizedBundleIdentifier: 5]
        )]

        let data = try Self.backup(groups).encoded()
        let decoded = try SettingsBackup.decode(from: data)

        #expect(decoded.groups == groups)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.leftOutItemCount == 0)
        #expect(decoded.itemCount == 3)
        #expect(decoded.appCount == decoded.itemCount)
        // The backup format itself is unchanged: version 1, with the new keys inside items only.
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(Set(object.keys) == ["schemaVersion", "app", "appVersion", "exportedAt", "groups", "preferences"])
    }

    /// What a crafted backup can't bring in: anything that isn't a plain location of a document or
    /// folder, and anything that would run code — judged by name, as the file may come from
    /// another Mac.
    @Test func importLeavesOutItemsThatCantBeOpenedSafely() throws {
        let kept = [
            #"{ "bundleIdentifier": "com.apple.mail", "name": "Mail" }"#,
            #"{ "bundleIdentifier": "file:///Users/me/Documents/Q3%20Report.pdf", "kind": "file", "name": "Q3 Report.pdf" }"#,
            #"{ "bundleIdentifier": "file:///Users/me/Projects/", "kind": "folder", "name": "Projects" }"#,
            #"{ "bundleIdentifier": "https://github.com", "kind": "website", "url": "https://github.com", "name": "GitHub" }"#,
        ]
        let leftOut = [
            #"{ "bundleIdentifier": "file:///Users/me/run.command", "kind": "file", "name": "run" }"#,
            #"{ "bundleIdentifier": "file:///Users/me/install.sh", "kind": "file", "name": "install" }"#,
            #"{ "bundleIdentifier": "file:///Users/me/tool.py", "kind": "file", "name": "tool" }"#,
            #"{ "bundleIdentifier": "file:///Users/me/Home.webloc", "kind": "file", "name": "Home" }"#,
            #"{ "bundleIdentifier": "file:///Applications/Calculator.app", "kind": "file", "name": "Calculator" }"#,
            #"{ "bundleIdentifier": "file:///Applications/Calculator.app/", "kind": "folder", "name": "Calculator" }"#,
            #"{ "bundleIdentifier": "file:///Users/me/run.command", "name": "run" }"#,
            // Locations that can't be read become apps that can't be found…
            #"{ "bundleIdentifier": "relative/x.pdf", "kind": "file", "name": "x" }"#,
            #"{ "bundleIdentifier": "/tmp/run.command", "kind": "file", "name": "run" }"#,
            #"{ "bundleIdentifier": "file:///Users/me/../../tmp/x.pdf", "kind": "file", "name": "x" }"#,
            #"{ "bundleIdentifier": "file://example.com/x.pdf", "kind": "file", "name": "x" }"#,
            #"{ "bundleIdentifier": "file:///Users/me/x.pdf?y", "kind": "file", "name": "x" }"#,
            #"{ "bundleIdentifier": "file:///Users/me/x.pdf#y", "kind": "file", "name": "x" }"#,
            #"{ "bundleIdentifier": "file:///Users/me/x%00.pdf", "kind": "file", "name": "x" }"#,
            #"{ "bundleIdentifier": "file:///Users/me/Projects", "kind": "folder", "name": "x" }"#,
            #"{ "bundleIdentifier": "file:///Users/me/x.pdf/", "kind": "file", "name": "x" }"#,
            #"{ "bundleIdentifier": "file:///\#(String(repeating: "a", count: Int(PATH_MAX)))", "kind": "file", "name": "x" }"#,
        ]
        let missingApps = [
            #"{ "bundleIdentifier": "/tmp/run.command", "name": "run" }"#,
        ]

        let backup = try SettingsBackup.decode(from: Self.craftedBackup(items: kept + leftOut + missingApps))

        let items = try #require(backup.groups.first?.apps)
        #expect(items.map(\.kind) == [.application, .file, .folder, .website])
        #expect(items.allSatisfy { $0.path == nil })
        #expect(backup.leftOutItemCount == leftOut.count + missingApps.count)
        #expect(backup.itemCount == kept.count)
        let summary = SettingsRestoreSummary(backup: backup, currentGroups: [])
        #expect(summary.itemCount == kept.count)
        #expect(summary.leftOutItemCount == backup.leftOutItemCount)
        #expect(summary.mergedItemCount == kept.count)
    }

    @Test func aCraftedBackupFileCantSmuggleInAScript() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let fileURL = directory.url.appending(path: "crafted.dockgroups")
        try Self.craftedBackup(
            items: [
                #"{ "bundleIdentifier": "file:///Users/me/Downloads/Invoice.command", "kind": "file", "name": "Invoice.pdf", "path": "/Users/me/Downloads/Invoice.command" }"#,
                #"{ "bundleIdentifier": "com.apple.mail", "name": "Mail", "path": "/Users/me/Downloads/Invoice.command" }"#,
            ],
            freeLayoutSlots: #"{ "file:///users/me/downloads/invoice.command": 0, "com.apple.mail": 1 }"#
        ).write(to: fileURL)

        let backup = try SettingsBackup.read(from: fileURL)

        let group = try #require(backup.groups.first)
        // The script is gone, with its Free Layout cell; the app keeps no location but an app's.
        #expect(group.apps == [Self.mail])
        #expect(group.freeLayoutSlots == ["com.apple.mail": 1])
        #expect(backup.leftOutItemCount == 1)
    }

    @Test func importedDetailsAreWithinTheirLimits() throws {
        let tags = (1...20).map { "\"tag\($0)\"" }.joined(separator: ",")
        let alias = String(repeating: "a", count: 300)
        let backup = try SettingsBackup.decode(from: Self.craftedBackup(items: [
            #"{ "bundleIdentifier": "com.apple.mail", "name": "Mail", "alias": "\#(alias)", "tags": [\#(tags)], "notes": "\#(String(repeating: "n", count: 900))" }"#,
        ]))

        let details = try #require(backup.groups.first?.apps.first?.details)
        #expect(details.alias?.count == ItemDetails.maximumAliasLength)
        #expect(details.tags.count == ItemDetails.maximumTagCount)
        #expect(details.notes?.count == ItemDetails.maximumNotesLength)
    }

    @Test func mergingABackupKeepsItsItemsDetails() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = GroupStore(persistence: JSONFileGroupPersistence(fileURL: directory.url.appending(path: "groups.json")), saveDelay: .zero)
        store.addGroup(named: "Mine")
        var report = Self.report
        report.details = ItemDetails(alias: "Quarterly report", tags: ["finance"])
        let incoming = DockGroup(name: "Theirs", apps: [report, Self.projects])

        try Self.backup([incoming]).merge(into: store)

        #expect(store.groups.last?.apps == [report, Self.projects])
        let reloaded = GroupStore(persistence: JSONFileGroupPersistence(fileURL: directory.url.appending(path: "groups.json")), saveDelay: .zero)
        #expect(reloaded.groups.last?.apps.first?.details == report.details)
    }
}
