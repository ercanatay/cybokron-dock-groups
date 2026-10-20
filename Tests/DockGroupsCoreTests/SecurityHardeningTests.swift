import Foundation
import Testing
@testable import DockGroupsCore

/// `AgentNotification.acceptedBundleURL`: a configuration-change notification may move an agent
/// only to an agent bundle in the agents folder with the agent's own bundle identifier.
@Suite("Agent notification bundle path")
struct AgentNotificationPathTests {
    static let groupID = UUID(uuidString: "6B1E2A3C-0D4F-4A5B-9C6D-7E8F90A1B2C3")!
    static var identifier: String { AgentIdentity.bundleIdentifier(for: groupID) }

    /// `<directory>/<name>` with an Info.plist naming `identifier`.
    private func agentBundle(named name: String, in directory: URL, identifier: String = AgentNotificationPathTests.identifier) throws -> URL {
        let bundle = directory.appending(path: name, directoryHint: .isDirectory)
        let contents = bundle.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier], format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
        return bundle
    }

    @Test func anAgentBundleInTheAgentsFolderIsAccepted() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let agents = temporary.url.appending(path: "Agents", directoryHint: .isDirectory)
        let bundle = try agentBundle(named: "work.app", in: agents)

        let accepted = AgentNotification.acceptedBundleURL(fromPath: bundle.path, agentDirectory: agents, bundleIdentifier: Self.identifier)

        #expect(accepted?.resolvingSymlinksInPath().path == bundle.resolvingSymlinksInPath().path)
        // Bundle identifiers compare case-insensitively, as LaunchServices does.
        #expect(AgentNotification.acceptedBundleURL(fromPath: bundle.path, agentDirectory: agents, bundleIdentifier: Self.identifier.lowercased()) != nil)
    }

    @Test func pathsOutsideTheAgentsFolderAreRefused() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let agents = temporary.url.appending(path: "Agents", directoryHint: .isDirectory)
        _ = try agentBundle(named: "work.app", in: agents)
        let elsewhere = try agentBundle(named: "evil.app", in: temporary.url.appending(path: "Downloads", directoryHint: .isDirectory))
        let nested = try agentBundle(named: "deep.app", in: agents.appending(path: "sub", directoryHint: .isDirectory))
        let link = agents.appending(path: "link.app", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)

        for path in [
            elsewhere.path,
            nested.path,
            link.path,
            agents.path + "/../Downloads/evil.app",
            "Agents/work.app",
            "",
        ] {
            #expect(AgentNotification.acceptedBundleURL(fromPath: path, agentDirectory: agents, bundleIdentifier: Self.identifier) == nil, "\(path)")
        }
    }

    @Test func anotherAgentsOrAppsBundleIsRefused() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let agents = temporary.url.appending(path: "Agents", directoryHint: .isDirectory)
        let other = try agentBundle(named: "play.app", in: agents, identifier: AgentIdentity.bundleIdentifier(for: UUID()))
        let main = try agentBundle(named: "main.app", in: agents, identifier: "com.cybokron.dockgroups")
        let notAnApp = try agentBundle(named: "work.bundle", in: agents)
        let noInfo = agents.appending(path: "empty.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: noInfo, withIntermediateDirectories: true)

        for bundle in [other, main, notAnApp, noInfo] {
            #expect(AgentNotification.acceptedBundleURL(fromPath: bundle.path, agentDirectory: agents, bundleIdentifier: Self.identifier) == nil, "\(bundle.lastPathComponent)")
        }
    }
}

/// `ReleaseHistory.minimumSecurityVersion`: Other Versions… warns before installing an older one.
@Suite("Versions without the security fixes")
struct MinimumSecurityVersionTests {
    @Test func versionsBefore065LackTheSecurityFixes() throws {
        #expect(ReleaseHistory.minimumSecurityVersion == SemanticVersion(major: 0, minor: 6, patch: 5))
        for version in ["0.5.1", "0.6.2", "0.6.3", "0.6.4"] {
            #expect(ReleaseHistory.lacksSecurityFixes(try #require(SemanticVersion(version))), "\(version)")
        }
        for version in ["0.6.5", "0.6.10", "0.7.0", "1.0.0"] {
            #expect(!ReleaseHistory.lacksSecurityFixes(try #require(SemanticVersion(version))), "\(version)")
        }
    }

    @Test func theWarningNamesTheVersion() throws {
        let english = try LocalizationTests.table("en")
        #expect(english["updates.otherVersions.preSafety.title"] == "This version lacks security fixes")
        let message = try #require(english["updates.otherVersions.preSafety.message"])
        #expect(String(format: message, "0.6.3").hasPrefix("Version 0.6.3 was released before important security fixes"))
    }
}

/// Import Settings… on files it shouldn't trust: too large, or with app locations that aren't app
/// bundles.
@Suite("Backup import limits")
struct BackupImportLimitTests {
    static func backupJSON(apps: String) -> String {
        """
        {"schemaVersion": 1, "app": "cybokron-dock-groups", "appVersion": "0.6.4", "exportedAt": "2026-10-20T10:00:00Z",
         "groups": [{"id": "6B1E2A3C-0D4F-4A5B-9C6D-7E8F90A1B2C3", "name": "Work", "apps": [\(apps)],
                     "freeLayoutSlots": {"/tmp/evil.command": 0, "com.apple.safari": 1}}],
         "preferences": {"formatVersion": 1}}
        """
    }

    @Test func aFileLargerThanFiveMegabytesIsntRead() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        #expect(SettingsBackup.maximumFileSize == 5 * 1024 * 1024)
        let large = temporary.url.appending(path: "large.dockgroups")
        let valid = Data(Self.backupJSON(apps: #"{"bundleIdentifier": "com.apple.Safari", "name": "Safari"}"#).utf8)
        // A valid backup padded with spaces past the limit: refused by size alone.
        try (valid + Data(repeating: 0x20, count: SettingsBackup.maximumFileSize)).write(to: large)
        let small = temporary.url.appending(path: "small.dockgroups")
        try valid.write(to: small)

        #expect(throws: SettingsBackupError.tooLarge) { try SettingsBackup.read(from: large) }
        #expect(throws: SettingsBackupError.tooLarge) { try SettingsBackup.decode(from: valid + Data(repeating: 0x20, count: SettingsBackup.maximumFileSize)) }
        #expect(try SettingsBackup.read(from: small).groups.first?.apps.count == 1)
        #expect(SettingsBackupError.tooLarge.localizedDescription == "This file is too large to be a Cybokron Dock Groups backup.")
    }

    @Test func appLocationsMustBeAppBundles() throws {
        let apps = """
            {"bundleIdentifier": "com.apple.Safari", "name": "Safari", "path": "/Applications/Safari.app"},
            {"bundleIdentifier": "com.apple.mail", "name": "Mail", "path": "/tmp/evil.command"},
            {"bundleIdentifier": "/tmp/evil.command", "name": "Evil"},
            {"bundleIdentifier": "/Users/x/Half-Life.app", "name": "Half-Life", "path": "/Users/x/Half-Life.app"},
            {"bundleIdentifier": "/Applications/../tmp/x.app", "name": "Traversal"},
            {"bundleIdentifier": "https://example.com", "name": "Example", "kind": "website", "url": "https://example.com"}
            """
        let backup = try SettingsBackup.decode(from: Data(Self.backupJSON(apps: apps).utf8))
        let group = try #require(backup.groups.first)

        #expect(group.apps.map(\.name) == ["Safari", "Mail", "Half-Life", "Example"])
        #expect(group.apps[0].path == "/Applications/Safari.app")
        #expect(group.apps[1].path == nil, "a fallback location that isn't an app is dropped")
        #expect(group.apps[2].isIdentifiedByPath && group.apps[2].path == "/Users/x/Half-Life.app")
        #expect(group.apps[3].isWebsite)
        // Free layout cells of dropped items go with them.
        #expect(group.freeLayoutSlots == ["com.apple.safari": 1])
        #expect(backup.appCount == 4)
    }

    @Test(arguments: [
        ("/Applications/Safari.app", true),
        ("/Applications/Safari.APP", true),
        ("/Users/x/Desktop/Half-Life/Half-Life.app", true),
        ("/Applications/Safari.app/", true),
        ("Applications/Safari.app", false),
        ("/Applications/Safari", false),
        ("/tmp/evil.command", false),
        ("/bin/sh", false),
        ("/.app", false),
        ("/Applications/../tmp/x.app", false),
        ("/Applications/./x.app", false),
        ("/Applications/x\u{0}.app", false),
        ("", false),
    ])
    func appBundlePaths(path: String, isApp: Bool) {
        #expect(SettingsBackup.isAppBundlePath(path) == isApp)
    }

    @Test func overlyLongPathsAreRefused() {
        let long = "/" + String(repeating: "a", count: Int(PATH_MAX)) + ".app"
        #expect(!SettingsBackup.isAppBundlePath(long))
    }
}
