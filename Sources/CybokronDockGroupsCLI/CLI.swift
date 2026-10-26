import AppKit
import DockGroupsCore

/// A URL client only: the main app remains responsible for group lookup, cooldowns and questions.
@main
struct CommandLineClient {
    @MainActor static func main() async {
        let result = await DockGroupsCLI.run(
            arguments: Array(CommandLine.arguments.dropFirst()),
            application: {
                guard let url = Bundle.main.executableURL else { return nil }
                return CLIApplication(executableURL: url)
            },
            runtime: WorkspaceRuntime()
        )
        FileHandle.standardOutput.write(Data(result.output.utf8))
        FileHandle.standardError.write(Data(result.errors.utf8))
        exit(result.exitCode)
    }
}

@MainActor
private struct WorkspaceRuntime: CLIRuntime {
    func isRunning(_ application: CLIApplication) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: CLIApplication.bundleIdentifier).contains {
            application.matches(bundleIdentifier: $0.bundleIdentifier, bundleURL: $0.bundleURL,
                executableURL: $0.executableURL, isTerminated: $0.isTerminated)
        }
    }

    func dispatch(_ url: URL, to application: CLIApplication) async -> Bool {
        await withCheckedContinuation { continuation in
            NSWorkspace.shared.open([url], withApplicationAt: application.url, configuration: .init()) { app, error in
                continuation.resume(returning: app != nil && error == nil)
            }
        }
    }
}
