import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Agent identity and folder names")
struct AgentIdentityTests {
    private let id = UUID(uuidString: "1A2B3C4D-0000-4000-8000-00000000AAAA")!

    @Test func bundleIdentifierCarriesTheGroupAndParsesBack() {
        let identifier = AgentIdentity.bundleIdentifier(for: id)
        #expect(identifier == "com.cybokron.dockgroups.agent.1A2B3C4D-0000-4000-8000-00000000AAAA")
        #expect(AgentIdentity.groupID(fromBundleIdentifier: identifier) == id)
        #expect(AgentIdentity.groupID(fromBundleIdentifier: identifier.lowercased()) == id)
        #expect(AgentIdentity.isAgent(bundleIdentifier: identifier))
    }

    @Test func otherIdentifiersAreNotAgents() {
        #expect(!AgentIdentity.isAgent(bundleIdentifier: "com.cybokron.dockgroups"))
        #expect(!AgentIdentity.isAgent(bundleIdentifier: nil))
        #expect(!AgentIdentity.isAgent(bundleIdentifier: "com.cybokron.dockgroups.agent.not-a-uuid"))
        #expect(!AgentIdentity.isAgent(bundleIdentifier: "com.example.agent.\(id.uuidString)"))
    }

    @Test func folderNameIsTheNameSlug() {
        let group = DockGroup(id: id, name: "Çalışma Alanı")
        #expect(AgentIdentity.folderNames(for: [group]) == [id: "calisma-alani.app"])
    }

    @Test func namesWithoutLettersFallBackToTheIdentifier() {
        let group = DockGroup(id: id, name: "🚀")
        #expect(AgentIdentity.folderNames(for: [group]) == [id: "group-1a2b3c4d.app"])
    }

    @Test func collidingSlugsAllGetTheirIdentifierRegardlessOfOrder() {
        let other = UUID(uuidString: "9F8E7D6C-0000-4000-8000-00000000BBBB")!
        let work = DockGroup(id: id, name: "Work")
        let workToo = DockGroup(id: other, name: "work!")
        let unique = DockGroup(name: "Play")
        let names = AgentIdentity.folderNames(for: [work, workToo, unique])
        #expect(names[id] == "work-1a2b3c4d.app")
        #expect(names[other] == "work-9f8e7d6c.app")
        #expect(names[unique.id] == "play.app")
        #expect(AgentIdentity.folderNames(for: [unique, workToo, work]) == names)
    }
}

@Suite("Agent configuration")
struct AgentConfigurationTests {
    private func sampleConfiguration() -> AgentConfiguration {
        let group = DockGroup(
            name: "Work",
            emoji: "💼",
            apps: [
                AppReference(bundleIdentifier: "com.apple.Safari", name: "Safari", path: "/Applications/Safari.app"),
                AppReference(bundleIdentifier: "com.apple.mail", name: "Mail"),
            ],
            tile: TileAppearance(kind: .grid, backgroundStyle: .gradient, backgroundColor: TileColor(red: 1, green: 2, blue: 3)),
            isStandalone: true,
            popup: PopupOverrides(columns: .fixed(3), showsTitles: false)
        )
        return AgentConfiguration(group: group, preferences: PopupPreferences(theme: .light, maxRows: 2))
    }

    @Test func roundTripKeepsGroupAndPreferences() throws {
        let configuration = sampleConfiguration()
        let decoded = try AgentConfiguration.decode(from: configuration.encoded())
        #expect(decoded == configuration)
        #expect(decoded.formatVersion == AgentConfiguration.currentFormatVersion)
        #expect(decoded.group.apps.map(\.bundleIdentifier) == ["com.apple.Safari", "com.apple.mail"])
    }

    @Test func encodingIsDeterministic() throws {
        let configuration = sampleConfiguration()
        #expect(try configuration.encoded() == configuration.encoded())
    }

    @Test func popupSettingsCombineOverridesAndSnapshot() {
        let settings = sampleConfiguration().popupSettings
        #expect(settings == PopupSettings(columns: .fixed(3), maxRows: 2, showsTitles: false, anchor: .dockCenter))
    }

    @Test func fileUsesOurSchema() throws {
        let object = try JSONSerialization.jsonObject(with: sampleConfiguration().encoded()) as? [String: Any]
        #expect(Set(object?.keys.map { $0 } ?? []) == ["formatVersion", "group", "preferences"])
        let group = object?["group"] as? [String: Any]
        #expect(group?["name"] as? String == "Work")
        #expect(group?["emoji"] as? String == "💼")
        #expect((group?["apps"] as? [[String: Any]])?.count == 2)
    }

    @Test func newerFormatIsRejected() throws {
        var configuration = sampleConfiguration()
        configuration.formatVersion = AgentConfiguration.currentFormatVersion + 1
        let data = try configuration.encoded()
        #expect(throws: AgentConfigurationError.unsupportedFormatVersion(AgentConfiguration.currentFormatVersion + 1)) {
            try AgentConfiguration.decode(from: data)
        }
    }

    @Test func unreadablePreferencesFallBackButAGroupIsRequired() throws {
        let lenient = #"{ "formatVersion": 1, "group": { "id": "8D9A5E2C-6B1F-4F7E-9C3A-2B4D6E8F0A1B", "name": "G" }, "preferences": 42 }"#
        let decoded = try AgentConfiguration.decode(from: Data(lenient.utf8))
        #expect(decoded.preferences == PopupPreferences())
        #expect(decoded.group.name == "G")

        let missingGroup = #"{ "formatVersion": 1, "preferences": {} }"#
        #expect(throws: DecodingError.self) {
            try AgentConfiguration.decode(from: Data(missingGroup.utf8))
        }
    }
}

@Suite("Agent Info.plist")
struct AgentInfoPlistTests {
    private let host = AgentHost(
        executableURL: URL(fileURLWithPath: "/Applications/Cybokron Dock Groups.app/Contents/MacOS/Cybokron Dock Groups"),
        version: "0.5.0",
        build: "7",
        minimumSystemVersion: "14.0",
        executableDigest: "abc123"
    )

    @Test func minimalAgentPlist() throws {
        let id = UUID()
        let data = try AgentInfoPlist.data(groupID: id, groupName: "Work 🚀", folderName: "work.app", host: host)
        let info = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])

        #expect(info["CFBundleIdentifier"] as? String == "com.cybokron.dockgroups.agent.\(id.uuidString)")
        #expect(info["CFBundleName"] as? String == "Work 🚀")
        #expect(info["CFBundleDisplayName"] as? String == "work")
        #expect(info["CFBundleExecutable"] as? String == AgentIdentity.executableName)
        #expect(info["CFBundleIconFile"] as? String == "AppIcon")
        #expect(info["CFBundlePackageType"] as? String == "APPL")
        #expect(info["CFBundleShortVersionString"] as? String == "0.5.0")
        #expect(info["CFBundleVersion"] as? String == "7")
        #expect(info["LSUIElement"] as? Bool == true)
        #expect(info["LSMultipleInstancesProhibited"] as? Bool == true)
        #expect(info["LSHasLocalizedDisplayName"] as? Bool == true)
        #expect(info[AgentInfoPlist.groupIDKey] as? String == id.uuidString)
        #expect(info[AgentInfoPlist.sourceDigestKey] as? String == "abc123")
        // Links and Siri belong to the main app.
        #expect(info["CFBundleURLTypes"] == nil)
    }

    @Test func localizedStringsEscapeTheName() {
        let text = String(decoding: AgentInfoPlist.localizedStrings(groupName: #"Say "hi" \ bye"#), as: UTF8.self)
        #expect(text.contains(#""CFBundleDisplayName" = "Say \"hi\" \\ bye";"#))
        #expect(text.contains(#""CFBundleName" = "Say \"hi\" \\ bye";"#))
    }

    @Test func layoutPaths() {
        let layout = AgentBundleLayout(bundleURL: URL(fileURLWithPath: "/tmp/Agents/work.app", isDirectory: true))
        #expect(layout.infoPlistURL.path == "/tmp/Agents/work.app/Contents/Info.plist")
        #expect(layout.executableURL.path == "/tmp/Agents/work.app/Contents/MacOS/\(AgentIdentity.executableName)")
        #expect(layout.configurationURL.path == "/tmp/Agents/work.app/Contents/Resources/group-config.json")
        #expect(layout.iconURL.path == "/tmp/Agents/work.app/Contents/Resources/AppIcon.icns")
        #expect(layout.localizedStringsURL.path == "/tmp/Agents/work.app/Contents/Resources/en.lproj/InfoPlist.strings")
    }

    @Test func agentsLiveInApplicationSupport() {
        let path = AgentDirectory.defaultURL.path
        #expect(path.hasSuffix("/Library/Application Support/Cybokron/DockGroups/Agents"))
    }
}
