import CryptoKit
import Foundation

public enum AgentInstallError: LocalizedError, Equatable, Sendable {
    /// The group's icon couldn't be drawn.
    case iconRenderFailed
    /// Putting the bundle together or moving it into place failed.
    case bundleWriteFailed(String)
    /// A system tool isn't there or couldn't be started.
    case toolMissing(String)
    /// `codesign` failed to sign the bundle.
    case signingFailed(String)
    /// The signed bundle didn't pass `codesign --verify`.
    case verificationFailed(String)
    /// LaunchServices didn't register the bundle.
    case registrationFailed(String)
    /// The main app's executable can't be read.
    case hostUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .iconRenderFailed:
            return Localization.string("core.agent.error.icon", "The group's icon couldn't be drawn.")
        case .bundleWriteFailed(let reason):
            return Localization.format("core.agent.error.bundleWrite", "The group's app couldn't be created: %@", reason)
        case .toolMissing(let path):
            return Localization.format("core.agent.error.toolMissing", "A system tool this needs is missing: %@.", path)
        case .signingFailed, .verificationFailed:
            return Localization.string("core.agent.error.signing", "macOS requires every app to be code-signed, and signing the group's app failed on this Mac, so nothing was installed.")
        case .registrationFailed(let reason):
            return Localization.format("core.agent.error.registration", "macOS didn't register the group's app: %@", reason)
        case .hostUnavailable(let reason):
            return Localization.format("core.agent.error.hostUnavailable", "Cybokron Dock Groups couldn't read its own executable: %@", reason)
        }
    }
}

extension AgentHost {
    /// The running main app as the source of agents.
    public static func current(bundle: Bundle = .main) throws -> AgentHost {
        guard let executableURL = bundle.executableURL else {
            throw AgentInstallError.hostUnavailable(Localization.string("core.agent.error.noExecutable", "The app has no executable."))
        }
        let data: Data
        do {
            data = try Data(contentsOf: executableURL, options: .mappedIfSafe)
        } catch {
            throw AgentInstallError.hostUnavailable(error.localizedDescription)
        }
        let info = bundle.infoDictionary ?? [:]
        return AgentHost(
            executableURL: executableURL,
            version: info["CFBundleShortVersionString"] as? String ?? "0",
            build: info["CFBundleVersion"] as? String ?? "0",
            minimumSystemVersion: info["LSMinimumSystemVersion"] as? String ?? "14.0",
            executableDigest: digest(of: data),
            localizationsURL: bundle.resourceURL
        )
    }

    /// Lowercase hex SHA-256.
    static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Builds, installs, registers and removes agent bundles in the agents directory.
///
/// A bundle is put together in a hidden staging folder next to its destination, signed ad hoc and
/// verified there, and only then moved into place (replacing the previous one in one step), so a
/// failure never leaves a half-built or unsigned agent behind.
public struct AgentInstaller: Sendable {
    /// What goes into one agent bundle.
    public struct Input: Sendable {
        public let configuration: AgentConfiguration
        public let folderName: String
        public let host: AgentHost
        public let icns: Data

        public init(configuration: AgentConfiguration, folderName: String, host: AgentHost, icns: Data) {
            self.configuration = configuration
            self.folderName = folderName
            self.host = host
            self.icns = icns
        }
    }

    /// Set to make signing fail on purpose, to try the failure path.
    public static let simulateSigningFailureVariable = "CYBOKRON_SIMULATE_SIGN_FAILURE"

    public let directory: URL
    private let tools: ToolRunning
    private let simulatesSigningFailure: Bool

    public init(
        directory: URL = AgentDirectory.defaultURL,
        tools: ToolRunning = SystemToolRunner(),
        simulatesSigningFailure: Bool = DevelopmentOverrides.value(AgentInstaller.simulateSigningFailureVariable) != nil
    ) {
        self.directory = directory
        self.tools = tools
        self.simulatesSigningFailure = simulatesSigningFailure
    }

    /// Where the agent with this folder name lives.
    public func bundleURL(folderName: String) -> URL {
        directory.appending(path: folderName, directoryHint: .isDirectory)
    }

    /// Builds the agent and puts it at `bundleURL(folderName:)`. Returns that location.
    @discardableResult
    public func install(_ input: Input) async throws -> URL {
        let fileManager = FileManager.default
        let staging = directory.appending(path: AgentDirectory.stagingPrefix + UUID().uuidString, directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: staging) }
        let staged = staging.appending(path: input.folderName, directoryHint: .isDirectory)
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            try writeBundle(input, at: staged)
        } catch let error as AgentInstallError {
            throw error
        } catch {
            throw AgentInstallError.bundleWriteFailed(error.localizedDescription)
        }

        try await sign(staged)
        try await verify(staged)

        let destination = bundleURL(folderName: input.folderName)
        do {
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
            } else {
                try fileManager.moveItem(at: staged, to: destination)
            }
        } catch {
            throw AgentInstallError.bundleWriteFailed(error.localizedDescription)
        }
        return destination
    }

    /// Registers the bundle with LaunchServices (`lsregister -f`), so the Dock and Finder know it.
    public func register(_ bundleURL: URL) async throws {
        let result = try await tools.run(SystemTools.lsregister, arguments: ["-f", bundleURL.path])
        guard result.succeeded else {
            throw AgentInstallError.registrationFailed(result.output.isEmpty ? "lsregister exited with \(result.status)" : result.output)
        }
    }

    /// Forgets the bundle in LaunchServices (`lsregister -u`). Best effort: a bundle that isn't
    /// registered is no problem.
    public func unregister(_ bundleURL: URL) async {
        _ = try? await tools.run(SystemTools.lsregister, arguments: ["-u", bundleURL.path])
    }

    /// Deletes an agent bundle.
    public func remove(_ bundleURL: URL) throws {
        guard FileManager.default.fileExists(atPath: bundleURL.path) else { return }
        try FileManager.default.removeItem(at: bundleURL)
    }

    /// Deletes what macOS kept for a removed agent outside its bundle: its caches and saved window
    /// state, all named after the agent's bundle identifier.
    public func removeSystemLeftovers(bundleIdentifier: String) {
        guard AgentIdentity.isAgent(bundleIdentifier: bundleIdentifier) else { return }
        let library = URL.libraryDirectory
        var locations = [
            library.appending(components: "Caches", bundleIdentifier, directoryHint: .isDirectory),
            library.appending(components: "Saved Application State", "\(bundleIdentifier).savedState", directoryHint: .isDirectory),
        ]
        if let cache = SystemTools.userCacheDirectory {
            locations.append(cache.appending(path: bundleIdentifier, directoryHint: .isDirectory))
        }
        for url in locations where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Deletes staging folders of builds that never finished.
    public func removeStagingLeftovers() {
        for url in AgentDirectory.stagingLeftovers(in: directory) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Steps

    func writeBundle(_ input: Input, at bundleURL: URL) throws {
        let fileManager = FileManager.default
        let layout = AgentBundleLayout(bundleURL: bundleURL)
        let group = input.configuration.group
        try fileManager.createDirectory(at: layout.macOSURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: layout.localizedStringsURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // A deliberate copy of the main app's executable: started from this bundle, it sees the
        // agent bundle identifier and runs as the group's agent.
        do {
            try fileManager.copyItem(at: input.host.executableURL, to: layout.executableURL)
        } catch {
            throw AgentInstallError.hostUnavailable(error.localizedDescription)
        }
        try AgentInfoPlist.data(groupID: group.id, groupName: group.name, folderName: input.folderName, host: input.host)
            .write(to: layout.infoPlistURL)
        try Data("APPL????".utf8).write(to: layout.pkgInfoURL)
        try AgentInfoPlist.localizedStrings(groupName: group.name).write(to: layout.localizedStringsURL)
        try copyStringTables(from: input.host, groupName: group.name, into: layout)
        try input.configuration.encoded().write(to: layout.configurationURL)
        try input.icns.write(to: layout.iconURL)
    }

    /// The main app's string tables, one `<language>.lproj` each, so the agent's popup and menus
    /// use the user's language. Every such folder gets the group's name in an `InfoPlist.strings`
    /// too: the Dock and Finder look for the name in the language they picked.
    private func copyStringTables(from host: AgentHost, groupName: String, into layout: AgentBundleLayout) throws {
        let fileManager = FileManager.default
        let infoPlistStrings = AgentInfoPlist.localizedStrings(groupName: groupName)
        for (language, source) in host.stringTables(fileManager: fileManager) {
            let folder = layout.localizationURL(for: language)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let table = folder.appending(path: AgentBundleLayout.stringTableFileName, directoryHint: .notDirectory)
            try fileManager.copyItem(at: source, to: table)
            try infoPlistStrings.write(to: folder.appending(path: AgentBundleLayout.infoPlistStringsFileName, directoryHint: .notDirectory))
        }
    }

    private func sign(_ bundleURL: URL) async throws {
        guard !simulatesSigningFailure else {
            throw AgentInstallError.signingFailed("Signing failure simulated (\(Self.simulateSigningFailureVariable)).")
        }
        let result = try await tools.run(
            SystemTools.codesign,
            arguments: ["--force", "--sign", "-", "--options", "runtime", "--timestamp=none", bundleURL.path]
        )
        guard result.succeeded else { throw AgentInstallError.signingFailed(result.output) }
    }

    private func verify(_ bundleURL: URL) async throws {
        let result = try await tools.run(SystemTools.codesign, arguments: ["--verify", "--strict", bundleURL.path])
        guard result.succeeded else { throw AgentInstallError.verificationFailed(result.output) }
    }
}
