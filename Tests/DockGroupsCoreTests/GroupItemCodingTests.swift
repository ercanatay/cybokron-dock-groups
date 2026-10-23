import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Group items: saving")
struct GroupItemCodingTests {
    static let report = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Documents/Finance/Q3 Report.pdf"), kind: .file)
    static let projects = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Projects/cybokron", isDirectory: true), kind: .folder)
    static let numbers = AppReference(bundleIdentifier: "com.apple.iWork.Numbers", name: "Numbers", path: "/Applications/Numbers.app")
    static let github = AppReference(websiteURL: URL(string: "https://github.com")!, name: "GitHub")

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    private func object(_ item: GroupItem) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
    }

    private func decode(_ json: String) throws -> GroupItem {
        try JSONDecoder().decode(GroupItem.self, from: Data(json.utf8))
    }

    // MARK: - 0.6.7 data

    @Test func version067GroupsFileReadsAsBeforeAndIsSavedByteForByte() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let fileURL = directory.url.appending(path: "groups.json")
        try Data(Version067Fixtures.groupsFile.utf8).write(to: fileURL)
        let persistence = JSONFileGroupPersistence(fileURL: fileURL)

        let groups = try persistence.loadGroups()

        #expect(groups == [Version067Fixtures.workGroup, Version067Fixtures.emptyGroup])
        #expect(groups[0].apps.map(\.kind) == [.application, .application, .website, .application])
        #expect(groups[0].apps[1].isIdentifiedByPath)
        #expect(groups[0].freeLayoutSlots == ["com.apple.safari": 4, "https://github.com/cybokron": 0])
        // Nothing in the file has details: they're empty, and nothing new is written.
        #expect(groups.flatMap(\.apps).allSatisfy { $0.details.isEmpty })
        try persistence.saveGroups(groups)
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == Version067Fixtures.groupsFile)
    }

    @Test func version067AgentConfigurationIsWhatThisVersionWrites() throws {
        let installed = try AgentConfiguration.decode(from: Data(Version067Fixtures.agentConfiguration.utf8))
        let current = AgentConfiguration(group: Version067Fixtures.workGroup, preferences: PopupPreferences())

        // Equal values and equal bytes: an update doesn't rebuild the agent as `outdated`.
        #expect(installed == current)
        #expect(String(decoding: try current.encoded(), as: UTF8.self) == Version067Fixtures.agentConfiguration)
    }

    @Test func version067BackupImportsAsBefore() throws {
        let backup = try SettingsBackup.decode(from: Data(Version067Fixtures.backup.utf8))

        #expect(backup.groups == [Version067Fixtures.workGroup, Version067Fixtures.emptyGroup])
        #expect(backup.schemaVersion == 1)
        #expect(backup.appVersion == "0.6.7")
        #expect(backup.exportedAt == Version067Fixtures.exportedAt)
        #expect(backup.leftOutItemCount == 0)
        #expect(backup.itemCount == 4)
        #expect(String(decoding: try backup.encoded(), as: UTF8.self) == Version067Fixtures.backup)
    }

    // MARK: - Files and folders

    @Test func filesAndFoldersAreIdentifiedByTheirLocation() {
        #expect(Self.report.kind == .file)
        #expect(Self.report.bundleIdentifier == "file:///Users/me/Documents/Finance/Q3%20Report.pdf")
        #expect(Self.report.name == "Q3 Report.pdf")
        #expect(Self.report.path == nil)
        #expect(Self.report.fileURL?.path == "/Users/me/Documents/Finance/Q3 Report.pdf")
        #expect(Self.projects.kind == .folder)
        #expect(Self.projects.bundleIdentifier == "file:///Users/me/Projects/cybokron/")
        #expect(Self.projects.name == "cybokron")
        #expect(Self.projects.fileURL?.hasDirectoryPath == true)
        // Neither is an app or a website.
        for item in [Self.report, Self.projects] {
            #expect(!item.isWebsite && !item.isIdentifiedByPath)
            #expect(item.websiteURL == nil)
            #expect(item.resolvedURL() == nil)
        }
        #expect(GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/a.txt"), kind: .file, name: " Plan ").name == "Plan")
        #expect(GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/a.txt"), kind: .file, name: "  ").name == "a.txt")
    }

    @Test func logsNameFilesAndFoldersByKindOnly() {
        #expect(Self.report.logIdentity == "file .pdf")
        #expect(Self.projects.logIdentity == "folder")
        #expect(GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Makefile"), kind: .file).logIdentity == "file")
        #expect(Self.numbers.logIdentity == "com.apple.iWork.Numbers")
    }

    @Test func kindCapabilities() {
        #expect(AppReference.Kind.allCases.filter(\.hasProcess) == [.application])
        #expect(AppReference.Kind.allCases.filter(\.isOnDisk) == [.application, .file, .folder])
        #expect(AppReference.Kind.allCases.filter(\.isFileSystemItem) == [.file, .folder])
    }

    @Test func filesAndFoldersSurviveRoundTripNextToAppsAndWebsites() throws {
        let group = DockGroup(
            name: "Mixed",
            apps: [Self.numbers, Self.github, Self.report, Self.projects],
            freeLayoutSlots: [Self.report.normalizedBundleIdentifier: 2, Self.projects.normalizedBundleIdentifier: 0]
        )

        let decoded = try roundTrip(group)

        #expect(decoded == group)
        #expect(decoded.apps.map(\.kind) == [.application, .website, .file, .folder])
        #expect(decoded.freeLayoutSlots == group.freeLayoutSlots)
    }

    /// What a version without files and folders relies on to show them as missing apps that open
    /// nothing: no app location, and an identity that's neither a bundle identifier nor a path.
    @Test func filesAndFoldersWriteTheirKindButNeverALocation() throws {
        #expect(try object(Self.report) as? [String: String] == [
            "bundleIdentifier": "file:///Users/me/Documents/Finance/Q3%20Report.pdf", "kind": "file", "name": "Q3 Report.pdf",
        ])
        #expect(try object(Self.projects) as? [String: String] == [
            "bundleIdentifier": "file:///Users/me/Projects/cybokron/", "kind": "folder", "name": "cybokron",
        ])
        var withLocation = Self.report
        withLocation.path = "/Applications/Numbers.app"
        #expect(try object(withLocation)["path"] == nil)
        #expect(try object(withLocation)["url"] == nil)
    }

    @Test func kindComesBackWhenAVersionWithoutItDroppedIt() throws {
        let folder = try decode(#"{ "bundleIdentifier": "file:///Users/me/Projects/cybokron/", "name": "cybokron" }"#)
        let file = try decode(#"{ "bundleIdentifier": "file:///Users/me/Documents/Finance/Q3%20Report.pdf", "name": "Q3 Report.pdf" }"#)
        #expect(folder == Self.projects)
        #expect(file == Self.report)
    }

    @Test func aSavedLocationOfAFileIsIgnored() throws {
        let item = try decode(#"""
        { "bundleIdentifier": "file:///Users/me/Documents/Finance/Q3%20Report.pdf", "kind": "file", "name": "Q3 Report.pdf", "path": "/Applications/Numbers.app" }
        """#)
        #expect(item == Self.report)
        #expect(item.path == nil)
    }

    @Test(arguments: [
        #"{ "bundleIdentifier": "Documents/x.pdf", "kind": "file", "name": "x" }"#,
        #"{ "bundleIdentifier": "/tmp/run.command", "kind": "file", "name": "run", "path": "/tmp/run.command" }"#,
        #"{ "bundleIdentifier": "file:///Users/me/../../etc/hosts", "kind": "file", "name": "hosts" }"#,
        #"{ "bundleIdentifier": "file://example.com/share/x.pdf", "kind": "file", "name": "x" }"#,
        #"{ "bundleIdentifier": "file:///Users/me/x.pdf?query", "kind": "file", "name": "x" }"#,
        #"{ "bundleIdentifier": "file:///Users/me/x%00.pdf", "kind": "file", "name": "x" }"#,
        #"{ "bundleIdentifier": "file:///Users/me/Projects/", "kind": "file", "name": "Projects" }"#,
        #"{ "bundleIdentifier": "file:///Users/me/x.pdf", "kind": "folder", "name": "x" }"#,
        #"{ "bundleIdentifier": "file:relative.pdf", "name": "x" }"#,
    ])
    func unreadableFilesAndFoldersStayVisibleAsMissingApps(json: String) throws {
        let item = try decode(json)
        #expect(item.kind == .application)
        // Never with a location an app could be opened from.
        #expect(item.path == nil)
    }

    // MARK: - Details

    @Test func detailsAreWrittenFlatAndOnlyWhenSet() throws {
        var item = Self.numbers
        item.details = ItemDetails(alias: "Budget", tags: ["finance", "q3"], notes: "Monthly budget; send totals to Ayşe")

        let saved = try object(item)

        #expect(saved["alias"] as? String == "Budget")
        #expect(saved["tags"] as? [String] == ["finance", "q3"])
        #expect(saved["notes"] as? String == "Monthly budget; send totals to Ayşe")
        #expect(saved["path"] as? String == "/Applications/Numbers.app")
        #expect(saved["kind"] == nil)
        #expect(try roundTrip(item) == item)
        // Without details, none of the keys is written.
        #expect(Set(try object(Self.numbers).keys) == ["bundleIdentifier", "name", "path"])
    }

    @Test func everyKindCanHaveDetails() throws {
        let details = ItemDetails(alias: "Quarterly report", tags: ["finance"], notes: "Line one\nLine two")
        for var item in [Self.numbers, Self.github, Self.report, Self.projects] {
            item.details = details
            let decoded = try roundTrip(item)
            #expect(decoded == item)
            #expect(decoded.kind == item.kind)
            #expect(decoded.displayName == "Quarterly report")
            #expect(decoded.name != "Quarterly report")
        }
    }

    @Test func unreadableDetailsAreLeftEmptyOneByOne() throws {
        let item = try decode(#"""
        { "bundleIdentifier": "com.apple.mail", "name": "Mail", "alias": 5, "tags": ["inbox", 1], "notes": "Reply on Fridays" }
        """#)
        #expect(item.bundleIdentifier == "com.apple.mail" && item.name == "Mail")
        #expect(item.details.alias == nil)
        #expect(item.details.tags.isEmpty)
        #expect(item.details.notes == "Reply on Fridays")

        let wrongType = try decode(#"{ "bundleIdentifier": "com.apple.mail", "name": "Mail", "alias": " Inbox ", "tags": "inbox" }"#)
        #expect(wrongType.details == ItemDetails(alias: "Inbox"))
    }

    @Test func savedDetailsAreCleanedUpWhenRead() throws {
        let tags = (1...20).map { "tag\($0)" }
        let json = try JSONSerialization.data(withJSONObject: [
            "bundleIdentifier": "com.apple.mail", "name": "Mail",
            "alias": String(repeating: "a", count: 200), "tags": tags + ["#tag1"], "notes": " \r\n ",
        ])
        let item = try JSONDecoder().decode(GroupItem.self, from: json)
        #expect(item.details.alias?.count == ItemDetails.maximumAliasLength)
        #expect(item.details.tags == Array(tags.prefix(ItemDetails.maximumTagCount)))
        #expect(item.details.notes == nil)
    }

    @Test func listsShowTheAliasAndSortByIt() {
        var report = Self.report
        report.details = ItemDetails(alias: "Annual plan")
        var numbers = Self.numbers
        numbers.details = ItemDetails(alias: "Budget")
        let zulip = AppReference(bundleIdentifier: "com.zulip.Zulip", name: "Zulip")

        #expect(report.displayName == "Annual plan")
        #expect(Self.projects.displayName == "cybokron")
        #expect(DockGroup.sortedByName([zulip, numbers, Self.projects, report]).map(\.displayName) == ["Annual plan", "Budget", "cybokron", "Zulip"])
    }
}

@Suite("Group items: details")
struct ItemDetailsTests {
    @Test func aliasIsOneTrimmedLine() {
        #expect(ItemDetails(alias: "  Quarterly\nreport \t ").alias == "Quarterly report")
        #expect(ItemDetails(alias: "Bud\u{7}get").alias == "Budget")
        #expect(ItemDetails(alias: " \n ").alias == nil)
        #expect(ItemDetails(alias: "").alias == nil)
        let long = ItemDetails(alias: String(repeating: "é", count: 100)).alias
        #expect(long?.count == ItemDetails.maximumAliasLength)
        // Emoji sequences (joined by zero-width joiners) stay whole.
        #expect(ItemDetails(alias: "👩‍💻 Dev").alias == "👩‍💻 Dev")
    }

    @Test func tagsAreTrimmedDistinctAndLimited() {
        let details = ItemDetails(tags: ["#finance", " q3 ", "Q3", "Fatura", "fatüra", "", "  ", "#", "work   in\nprogress", "Çay", "cay"])
        #expect(details.tags == ["finance", "q3", "Fatura", "work in progress", "Çay"])
        #expect(ItemDetails(tags: [String(repeating: "x", count: 40)]).tags == [String(repeating: "x", count: ItemDetails.maximumTagLength)])
        #expect(ItemDetails(tags: (1...15).map { "t\($0)" }).tags.count == ItemDetails.maximumTagCount)
    }

    @Test func tagsAreTypedSeparatedByTheCommasOfTheAppsLanguages() {
        #expect(ItemDetails.tags(fromCommaSeparated: "finance, q3,,  #invoice ") == ["finance", "q3", "invoice"])
        #expect(ItemDetails.tags(fromCommaSeparated: "مالي، فاتورة") == ["مالي", "فاتورة"])
        #expect(ItemDetails.tags(fromCommaSeparated: "财务，发票、报告") == ["财务", "发票", "报告"])
        #expect(ItemDetails.tags(fromCommaSeparated: "") == [])
        #expect(ItemDetails(tags: ["finance", "q3"]).commaSeparatedTags == "finance, q3")
    }

    @Test func notesKeepLinesButNotControlCharacters() {
        #expect(ItemDetails(notes: "  Send totals\r\nto Ayşe\ron Fridays\u{0}\t  ").notes == "Send totals\nto Ayşe\non Fridays")
        #expect(ItemDetails(notes: " \n\r\n ").notes == nil)
        #expect(ItemDetails(notes: String(repeating: "n", count: 600)).notes?.count == ItemDetails.maximumNotesLength)
    }

    @Test func emptiness() {
        #expect(ItemDetails().isEmpty)
        #expect(ItemDetails(alias: " ", tags: ["", "#"], notes: "\n").isEmpty)
        #expect(!ItemDetails(tags: ["x"]).isEmpty)
        #expect(AppReference(bundleIdentifier: "com.apple.mail", name: "Mail").details.isEmpty)
    }
}
