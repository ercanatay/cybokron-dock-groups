import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Website addresses")
struct WebsiteAddressTests {
    @Test func addressesWithoutASchemeGetHTTPS() throws {
        #expect(try WebsiteAddress.parse("github.com").absoluteString == "https://github.com")
        #expect(try WebsiteAddress.parse("  github.com/cybokron  ").absoluteString == "https://github.com/cybokron")
        #expect(try WebsiteAddress.parse("localhost:8080/admin").absoluteString == "https://localhost:8080/admin")
        #expect(try WebsiteAddress.parse("example.com:443").absoluteString == "https://example.com:443")
    }

    @Test func schemeAndHostAreNormalizedButThePathIsKept() throws {
        #expect(try WebsiteAddress.parse("HTTPS://GitHub.com/").absoluteString == "https://github.com")
        #expect(try WebsiteAddress.parse("http://Example.com/Docs?q=A#Top").absoluteString == "http://example.com/Docs?q=A#Top")
        #expect(try WebsiteAddress.parse("https://example.com/?q=1").absoluteString == "https://example.com/?q=1")
    }

    @Test func brokenAddressesAreRejected() {
        #expect(throws: WebsiteAddressError.empty) { try WebsiteAddress.parse("   ") }
        #expect(throws: WebsiteAddressError.invalid) { try WebsiteAddress.parse("not a url") }
        #expect(throws: WebsiteAddressError.invalid) { try WebsiteAddress.parse("github") }
        #expect(throws: WebsiteAddressError.invalid) { try WebsiteAddress.parse("https://") }
        #expect(throws: WebsiteAddressError.invalid) { try WebsiteAddress.parse("https://.com") }
        #expect(throws: WebsiteAddressError.invalid) { try WebsiteAddress.parse("https://exa..mple.com") }
        #expect(throws: WebsiteAddressError.unsupportedScheme("file")) { try WebsiteAddress.parse("file:///etc/hosts") }
        #expect(throws: WebsiteAddressError.unsupportedScheme("javascript")) { try WebsiteAddress.parse("javascript:alert(1)") }
        #expect(throws: WebsiteAddressError.unsupportedScheme("mailto")) { try WebsiteAddress.parse("mailto:me@example.com") }
        #expect(throws: WebsiteAddressError.containsCredentials) { try WebsiteAddress.parse("https://me:secret@example.com") }
    }

    @Test func defaultNameIsTheHostWithoutWWW() throws {
        #expect(WebsiteAddress.defaultName(for: try WebsiteAddress.parse("https://www.github.com/x")) == "github.com")
        #expect(WebsiteAddress.defaultName(for: try WebsiteAddress.parse("docs.swift.org")) == "docs.swift.org")
        #expect(AppReference(websiteURL: try WebsiteAddress.parse("github.com")).name == "github.com")
        #expect(AppReference(websiteURL: try WebsiteAddress.parse("github.com"), name: "  ").name == "github.com")
        #expect(AppReference(websiteURL: try WebsiteAddress.parse("github.com"), name: " Code ").name == "Code")
    }

    @Test func websiteItemsAreNeitherAppsNorPaths() throws {
        let website = AppReference(websiteURL: try WebsiteAddress.parse("github.com"))
        #expect(website.isWebsite)
        #expect(!website.isIdentifiedByPath)
        #expect(website.websiteURL?.absoluteString == "https://github.com")
        #expect(website.resolvedURL() == nil)
        #expect(website.logIdentity == "website github.com")
        let app = AppReference(bundleIdentifier: "com.apple.Safari", name: "Safari")
        #expect(!app.isWebsite && app.websiteURL == nil)
        #expect(app.logIdentity == "com.apple.Safari")
    }
}

@Suite("Website items: saving")
struct WebsiteCodingTests {
    private static let website = AppReference(websiteURL: URL(string: "https://github.com")!, name: "GitHub")

    @Test func websitesWriteTheirKindAndAddress() throws {
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.website)) as? [String: String])
        #expect(object == ["bundleIdentifier": "https://github.com", "name": "GitHub", "kind": "website", "url": "https://github.com"])
    }

    @Test func appsAreWrittenAsBefore() throws {
        let app = AppReference(bundleIdentifier: "com.apple.Safari", name: "Safari", path: "/Applications/Safari.app")
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(app)) as? [String: String])
        #expect(object == ["bundleIdentifier": "com.apple.Safari", "name": "Safari", "path": "/Applications/Safari.app"])
    }

    @Test func mixedGroupSurvivesRoundTrip() throws {
        let group = DockGroup(
            name: "Mixed",
            apps: [AppReference(bundleIdentifier: "com.apple.Safari", name: "Safari"), Self.website],
            freeLayoutSlots: ["https://github.com": 3]
        )
        let decoded = try JSONDecoder().decode(DockGroup.self, from: JSONEncoder().encode(group))
        #expect(decoded == group)
        #expect(decoded.apps.map(\.isWebsite) == [false, true])
        #expect(decoded.freeLayoutSlots == ["https://github.com": 3])
    }

    @Test func oldGroupFilesWithoutKindsAreApps() throws {
        let json = """
        {
          "id": "8D9A5E2C-6B1F-4F7E-9C3A-2B4D6E8F0A1B",
          "name": "Old",
          "apps": [
            { "bundleIdentifier": "com.apple.Safari", "name": "Safari", "path": "/Applications/Safari.app" },
            { "bundleIdentifier": "/Applications/Tool.app", "name": "Tool" }
          ]
        }
        """
        let group = try JSONDecoder().decode(DockGroup.self, from: Data(json.utf8))
        #expect(group.apps.map(\.kind) == [.application, .application])
        #expect(group.apps[0] == AppReference(bundleIdentifier: "com.apple.Safari", name: "Safari", path: "/Applications/Safari.app"))
        #expect(group.apps[1].isIdentifiedByPath)
    }

    @Test func websiteKeptByAVersionWithoutWebsitesIsRecognized() throws {
        // Saved again by a version that only kept the identifier and name.
        let json = #"{ "bundleIdentifier": "https://GitHub.com/", "name": "GitHub" }"#
        let item = try JSONDecoder().decode(AppReference.self, from: Data(json.utf8))
        #expect(item == Self.website)
    }

    @Test func unreadableWebsitesAndUnknownKindsStayVisibleAsMissingApps() throws {
        let json = """
        [
          { "bundleIdentifier": "broken", "name": "Broken", "kind": "website", "url": "javascript:alert(1)" },
          { "bundleIdentifier": "note:123", "name": "Note", "kind": "hologram" }
        ]
        """
        let items = try JSONDecoder().decode([AppReference].self, from: Data(json.utf8))
        #expect(items.map(\.kind) == [.application, .application])
        #expect(items.map(\.bundleIdentifier) == ["broken", "note:123"])
    }

    @Test func backupKeepsWebsitesAndOldBackupsStillRead() throws {
        let groups = [DockGroup(name: "Web", apps: [Self.website, AppReference(bundleIdentifier: "com.apple.mail", name: "Mail")])]
        let backup = SettingsBackup(appVersion: "0.5.4", groups: groups, preferences: PopupPreferences())

        let data = try backup.encoded()
        let decoded = try SettingsBackup.decode(from: data)

        #expect(decoded.groups == groups)
        #expect(decoded.schemaVersion == 1)
        #expect(String(decoding: data, as: UTF8.self).contains(#""url" : "https://github.com""#))

        let id = UUID()
        let old = Data("""
        {
          "schemaVersion": 1,
          "app": "cybokron-dock-groups",
          "groups": [{ "id": "\(id.uuidString)", "name": "Dev", "apps": [{ "bundleIdentifier": "com.apple.mail", "name": "Mail" }] }],
          "preferences": { "formatVersion": 1 }
        }
        """.utf8)
        #expect(try SettingsBackup.decode(from: old).groups.first?.apps == [AppReference(bundleIdentifier: "com.apple.mail", name: "Mail")])
    }
}

@Suite("Website items: groups")
@MainActor
struct WebsiteGroupTests {
    private let directory: TemporaryDirectory
    private let fileURL: URL

    init() throws {
        directory = try TemporaryDirectory()
        fileURL = directory.url.appending(components: "DockGroups", "groups.json")
    }

    private func makeStore() -> GroupStore {
        GroupStore(persistence: JSONFileGroupPersistence(fileURL: fileURL), saveDelay: .zero)
    }

    private static func website(_ address: String, name: String? = nil) -> AppReference {
        AppReference(websiteURL: try! WebsiteAddress.parse(address), name: name)
    }

    private static let mail = AppReference(bundleIdentifier: "com.apple.mail", name: "Mail")

    @Test func aWebsiteIsInAGroupOnceButMayBeInSeveralGroups() {
        defer { directory.remove() }
        let store = makeStore()
        let work = store.addGroup(named: "Work")
        let home = store.addGroup(named: "Home")

        #expect(store.addApps([Self.website("github.com")], toGroup: work.id) == 1)
        // The same address typed differently is the same website.
        #expect(store.addApps([Self.website("https://GitHub.com/", name: "Code")], toGroup: work.id) == 0)
        #expect(store.addApps([Self.website("github.com")], toGroup: home.id) == 1)
        #expect(store.addApps([Self.website("github.com/cybokron")], toGroup: work.id) == 1)

        #expect(store.group(withID: work.id)?.apps.map(\.bundleIdentifier) == ["https://github.com", "https://github.com/cybokron"])
        #expect(store.group(withID: home.id)?.apps.count == 1)
    }

    @Test func websitesSurviveRestart() {
        defer { directory.remove() }
        let store = makeStore()
        let group = store.addGroup(named: "Web")
        store.addApps([Self.mail, Self.website("github.com", name: "GitHub")], toGroup: group.id)

        let reloaded = makeStore()

        #expect(reloaded.group(withID: group.id)?.apps == [Self.mail, Self.website("github.com", name: "GitHub")])
        #expect(reloaded.group(withID: group.id)?.apps.last?.isWebsite == true)
    }

    @Test func movingAWebsiteToAnotherGroup() {
        defer { directory.remove() }
        let store = makeStore()
        let github = Self.website("github.com")
        let work = store.addGroup(named: "Work")
        let home = store.addGroup(named: "Home")
        store.addApps([github, Self.mail], toGroup: work.id)
        store.updateGroup(work.id) { $0.freeLayoutSlots = [github.normalizedBundleIdentifier: 2, Self.mail.normalizedBundleIdentifier: 0] }

        #expect(store.moveApp(bundleIdentifier: github.bundleIdentifier, fromGroup: work.id, toGroup: home.id))

        #expect(store.group(withID: work.id)?.apps == [Self.mail])
        #expect(store.group(withID: work.id)?.freeLayoutSlots == [Self.mail.normalizedBundleIdentifier: 0])
        #expect(store.group(withID: home.id)?.apps == [github])

        // Moving it to a group that already has it only takes it out of the source.
        store.addApps([github], toGroup: work.id)
        #expect(store.moveApp(bundleIdentifier: github.bundleIdentifier, fromGroup: work.id, toGroup: home.id))
        #expect(store.group(withID: work.id)?.apps == [Self.mail])
        #expect(store.group(withID: home.id)?.apps == [github])
    }

    @Test func removingAWebsite() {
        defer { directory.remove() }
        let store = makeStore()
        let github = Self.website("github.com")
        let group = store.addGroup(named: "Web")
        store.addApps([github, Self.mail], toGroup: group.id)

        store.removeApp(bundleIdentifier: github.bundleIdentifier, fromGroup: group.id)

        #expect(store.group(withID: group.id)?.apps == [Self.mail])
    }

    @Test func sortingMixesWebsitesAndAppsByName() {
        defer { directory.remove() }
        let store = makeStore()
        let group = store.addGroup(named: "Mixed")
        let zulip = AppReference(bundleIdentifier: "com.zulip.Zulip", name: "Zulip")
        let github = Self.website("github.com", name: "GitHub")
        let apple = Self.website("apple.com")
        store.addApps([zulip, github, Self.mail, apple], toGroup: group.id)

        store.sortAppsByName(inGroup: group.id)

        #expect(store.group(withID: group.id)?.apps.map(\.name) == ["apple.com", "GitHub", "Mail", "Zulip"])
    }

    @Test func websitesNeverCountForMostUsed() {
        var tracker = UsageTracker()
        #expect(!UsageTracker.isTracked(bundleIdentifier: "https://github.com"))
        let recordedWebsite = tracker.recordLaunch(of: Self.website("github.com"), at: Date())
        let recordedApp = tracker.recordLaunch(of: Self.mail, at: Date())
        #expect(!recordedWebsite)
        #expect(recordedApp)
        #expect(tracker.stats.apps.keys.sorted() == [Self.mail.normalizedBundleIdentifier])
    }

    @Test func freeLayoutPlacesWebsitesLikeApps() {
        let github = Self.website("github.com")
        let layout = FreeLayout(apps: [Self.mail, github], savedSlots: [github.normalizedBundleIdentifier: 5], slotCount: 9)
        #expect(layout.slot(of: github) == 5)
        #expect(layout.slot(of: Self.mail) == 0)
    }
}
