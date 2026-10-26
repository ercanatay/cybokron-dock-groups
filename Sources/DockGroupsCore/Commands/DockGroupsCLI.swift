import Foundation

/// The CLI deliberately exposes only these existing links. `open` shows the popup.
public enum CLIGroupAction: String, Sendable { case start, finish, open }

public enum CLICommand: Equatable, Sendable {
    case group(CLIGroupAction, String), status, help, version
    public init?(arguments: [String]) {
        if arguments.count == 1 {
            switch arguments[0] {
            case "status": self = .status
            case "--help": self = .help
            case "--version": self = .version
            default: return nil
            }
        } else if arguments.count == 2, let action = CLIGroupAction(rawValue: arguments[0]),
                  !arguments[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self = .group(action, arguments[1])
        } else {
            return nil
        }
    }

    /// Encode the entire name as one path component, including slashes and literal percent signs.
    /// No query, fragment or arbitrary scheme can be supplied by the caller.
    public var url: URL? {
        guard case .group(let action, let name) = self else { return nil }
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#"))
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        var components = URLComponents()
        components.scheme = URLCommand.scheme
        components.host = action.rawValue
        components.percentEncodedPath = "/" + encoded
        return components.url
    }
}

/// The containing app, not whichever copy LaunchServices happens to prefer. Resolving the
/// executable first also handles a user-created PATH symlink without inspecting any group data.
public struct CLIApplication: Equatable, Sendable {
    public static let bundleIdentifier = "com.cybokron.dockgroups"
    public let url: URL
    public let mainExecutableURL: URL
    public let version: String
    public init?(executableURL: URL) {
        guard executableURL.isFileURL else { return nil }
        let executable = executableURL.resolvingSymlinksInPath().standardizedFileURL
        let macOS = executable.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard executable.lastPathComponent == "cybokrondockgroups", macOS.lastPathComponent == "MacOS",
              contents.lastPathComponent == "Contents", app.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: app), bundle.bundleIdentifier == Self.bundleIdentifier,
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !version.contains(where: { $0.isWhitespace }), SemanticVersion(version) != nil,
              let mainName = bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String,
              !mainName.isEmpty, !mainName.contains("/"), !mainName.contains("\0"),
              mainName != ".", mainName != "..", mainName != executable.lastPathComponent
        else { return nil }
        url = app
        mainExecutableURL = macOS.appendingPathComponent(mainName)
        self.version = version
    }

    /// A CLI process, standalone agent or another installed/development copy is not this main app.
    public func matches(bundleIdentifier: String?, bundleURL: URL?, executableURL: URL?, isTerminated: Bool) -> Bool {
        !isTerminated && bundleIdentifier == Self.bundleIdentifier
            && bundleURL?.resolvingSymlinksInPath().standardizedFileURL == url
            && executableURL?.resolvingSymlinksInPath().standardizedFileURL == mainExecutableURL
    }
}

@MainActor public protocol CLIRuntime {
    func isRunning(_ application: CLIApplication) -> Bool
    func dispatch(_ url: URL, to application: CLIApplication) async -> Bool
}

public struct CLIResult: Equatable, Sendable {
    public let exitCode: Int32
    public let output: String
    public let errors: String
}

public enum DockGroupsCLI {
    public static let help = """
        Usage: cybokrondockgroups start <group>
               cybokrondockgroups finish <group>
               cybokrondockgroups open <group>
               cybokrondockgroups status | --help | --version

        <group> is an active group's UUID or name; quote names containing spaces.
        open shows the group's popup; it does not run Open All.
        start and finish use the app's link cooldown and confirmation rules.
        A stopped app may be launched to handle a dispatch.

        Exit codes: 0 = running or URL dispatch accepted; 2 = bad arguments;
                    3 = stopped or dispatch unavailable/failed.
        Accepted dispatch does not report group existence, confirmation or completion.
        status prints running VERSION or stopped VERSION for this CLI's containing app.

        """

    @MainActor public static func run(arguments: [String], application: () -> CLIApplication?, runtime: some CLIRuntime) async -> CLIResult {
        guard let command = CLICommand(arguments: arguments) else {
            return CLIResult(exitCode: 2, output: "", errors: help)
        }
        if command == .help { return CLIResult(exitCode: 0, output: help, errors: "") }
        guard let app = application() else {
            return CLIResult(exitCode: 3, output: "", errors: "Run the CLI bundled with Cybokron Dock Groups.\n")
        }
        switch command {
        case .help: return CLIResult(exitCode: 0, output: help, errors: "")
        case .version: return CLIResult(exitCode: 0, output: app.version + "\n", errors: "")
        case .status:
            let running = runtime.isRunning(app)
            return CLIResult(exitCode: running ? 0 : 3, output: "\(running ? "running" : "stopped") \(app.version)\n", errors: "")
        case .group:
            guard let url = command.url, await runtime.dispatch(url, to: app) else {
                return CLIResult(exitCode: 3, output: "", errors: "URL dispatch failed; no command completion is reported.\n")
            }
            return CLIResult(exitCode: 0, output: "", errors: "URL dispatch accepted; group existence, confirmation and completion are not reported.\n")
        }
    }
}
