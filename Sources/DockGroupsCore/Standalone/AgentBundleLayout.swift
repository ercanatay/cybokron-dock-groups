import Foundation

/// Where things live inside an agent bundle:
///
///     <slug>.app/Contents/Info.plist
///     <slug>.app/Contents/PkgInfo
///     <slug>.app/Contents/MacOS/Cybokron Group Agent      (a copy of the main app's executable)
///     <slug>.app/Contents/Resources/AppIcon.icns          (the group's tile)
///     <slug>.app/Contents/Resources/group-config.json     (AgentConfiguration)
///     <slug>.app/Contents/Resources/en.lproj/InfoPlist.strings  (the name the Dock and Finder show)
public struct AgentBundleLayout: Equatable, Sendable {
    public static let iconName = "AppIcon"
    public static let iconFileName = "AppIcon.icns"

    public let bundleURL: URL

    public init(bundleURL: URL) {
        self.bundleURL = bundleURL
    }

    public var contentsURL: URL { bundleURL.appending(path: "Contents", directoryHint: .isDirectory) }
    public var infoPlistURL: URL { contentsURL.appending(path: "Info.plist", directoryHint: .notDirectory) }
    public var pkgInfoURL: URL { contentsURL.appending(path: "PkgInfo", directoryHint: .notDirectory) }
    public var macOSURL: URL { contentsURL.appending(path: "MacOS", directoryHint: .isDirectory) }
    public var executableURL: URL {
        macOSURL.appending(path: AgentIdentity.executableName, directoryHint: .notDirectory)
    }
    public var resourcesURL: URL { contentsURL.appending(path: "Resources", directoryHint: .isDirectory) }
    public var iconURL: URL { resourcesURL.appending(path: Self.iconFileName, directoryHint: .notDirectory) }
    public var configurationURL: URL {
        resourcesURL.appending(path: AgentConfiguration.fileName, directoryHint: .notDirectory)
    }
    public var localizedStringsURL: URL {
        resourcesURL.appending(components: "en.lproj", "InfoPlist.strings", directoryHint: .notDirectory)
    }
}

/// The parts of the main app an agent copies.
public struct AgentHost: Equatable, Sendable {
    /// The main app's executable, copied into every agent.
    public let executableURL: URL
    public let version: String
    public let build: String
    public let minimumSystemVersion: String
    /// SHA-256 of the executable (hex), recorded in the agent to notice when the main app changed.
    public let executableDigest: String

    public init(executableURL: URL, version: String, build: String, minimumSystemVersion: String, executableDigest: String) {
        self.executableURL = executableURL
        self.version = version
        self.build = build
        self.minimumSystemVersion = minimumSystemVersion
        self.executableDigest = executableDigest
    }
}

/// The agent's Info.plist and the strings that give it the group's name.
public enum AgentInfoPlist {
    /// The group the agent stands for (also part of the bundle identifier).
    public static let groupIDKey = "CybokronAgentGroupID"
    /// `AgentHost.executableDigest` of the executable the agent was built from.
    public static let sourceDigestKey = "CybokronAgentSourceDigest"

    /// A minimal Info.plist: an agent app (`LSUIElement`, so no Dock icon of its own while it runs and
    /// no menu bar) that runs once at a time, without URL schemes or App Intents.
    ///
    /// Finder and the Dock show an app's file name unless the bundle has a localized display name and
    /// its file name equals the unlocalized one; so `CFBundleDisplayName` is the folder name here and
    /// `InfoPlist.strings` holds the group's real name.
    public static func dictionary(groupID: UUID, groupName: String, folderName: String, host: AgentHost) -> [String: Any] {
        [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleDisplayName": (folderName as NSString).deletingPathExtension,
            "CFBundleExecutable": AgentIdentity.executableName,
            "CFBundleIconFile": AgentBundleLayout.iconName,
            "CFBundleIdentifier": AgentIdentity.bundleIdentifier(for: groupID),
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": groupName,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": host.version,
            "CFBundleVersion": host.build,
            "LSHasLocalizedDisplayName": true,
            "LSMinimumSystemVersion": host.minimumSystemVersion,
            "LSMultipleInstancesProhibited": true,
            "LSUIElement": true,
            "NSHighResolutionCapable": true,
            "NSPrincipalClass": "NSApplication",
            groupIDKey: groupID.uuidString,
            sourceDigestKey: host.executableDigest,
        ]
    }

    public static func data(groupID: UUID, groupName: String, folderName: String, host: AgentHost) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: dictionary(groupID: groupID, groupName: groupName, folderName: folderName, host: host),
            format: .xml,
            options: 0
        )
    }

    /// `InfoPlist.strings` (UTF-8, which macOS accepts) naming the agent after the group.
    public static func localizedStrings(groupName: String) -> Data {
        let name = quoted(groupName)
        return Data("\"CFBundleDisplayName\" = \(name);\n\"CFBundleName\" = \(name);\n".utf8)
    }

    private static func quoted(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
