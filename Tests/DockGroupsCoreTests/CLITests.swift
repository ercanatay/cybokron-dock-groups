import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Command-line interface")
@MainActor
struct CLITests {
    @Test func swiftPMExecutableNamesDoNotCollideOnCaseInsensitiveVolumes() throws {
        let manifest = try String(contentsOf: RepositoryScript.root.appending(path: "Package.swift"), encoding: .utf8)
        let products = manifest.components(separatedBy: ".executable(name: \"").dropFirst()
            .map { String($0.prefix { $0 != "\"" }) }
        #expect(products.count >= 2)
        #expect(Set(products.map { $0.lowercased() }).count == products.count)
    }

    @Test(arguments: ["start", "finish", "open"])
    func groupCommandsKeepOneLiteralArgument(verb: String) throws {
        let name = "  Dev/Ops ?#% 🎮 $(touch nope); `exit`  "
        let command = try #require(CLICommand(arguments: [verb, name]))
        #expect(command == .group(try #require(CLIGroupAction(rawValue: verb)), name))
        let url = try #require(command.url)
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.host == verb)
        #expect(parts.query == nil && parts.fragment == nil && parts.user == nil)
        #expect(parts.percentEncodedPath.dropFirst().contains("/") == false)
        #expect(parts.percentEncodedPath.dropFirst().removingPercentEncoding == name)
        let link = try #require(LinkCommand(url: url))
        switch verb {
        case "start": #expect(link == .switching(.start(name)))
        case "finish": #expect(link == .switching(.finish(name)))
        default: #expect(link == .command(.showGroup(name)))
        }
    }

    @Test(arguments: [".", "..", "%2F", "a//b/", "Çalışma Alanı", "a\nb", UUID().uuidString])
    func encodedNamesRoundTripThroughTheExistingLinkParser(name: String) throws {
        let url = try #require(CLICommand(arguments: ["open", name])?.url)
        #expect(LinkCommand(url: url) == .command(.showGroup(name)))
    }

    @Test(arguments: [
        [String](), ["start"], ["open", ""], ["finish", "  \n"], ["start", "Work", "Other"],
        ["quit", "Work"], ["force", "Work"], ["launch", "Work"], ["status", "Work"],
        ["--help", "Work"], ["--version", "Work"], ["start", "Work", "--force"],
        ["cybokrondockgroups://start/Work"], ["Start", "Work"],
    ])
    func malformedAndUnsupportedCommandsAreRejected(arguments: [String]) async {
        let runtime = Runtime()
        var resolved = false
        let result = await DockGroupsCLI.run(arguments: arguments, application: { resolved = true; return nil }, runtime: runtime)
        #expect(result.exitCode == 2)
        #expect(result.output.isEmpty)
        #expect(result.errors.contains("Usage:"))
        #expect(!resolved)
        #expect(runtime.urls.isEmpty && runtime.statusChecks == 0)
        #expect(!result.errors.contains("Work") && !result.errors.contains("Other") && !result.errors.contains("cybokrondockgroups://"))
    }

    @Test func helpNeedsNoAppAndExplainsTheAsyncBoundary() async {
        let result = await DockGroupsCLI.run(arguments: ["--help"], application: { nil }, runtime: Runtime())
        #expect(result.exitCode == 0 && result.errors.isEmpty)
        #expect(result.output.contains("open <group>"))
        #expect(result.output.contains("popup"))
        #expect(result.output.contains("accepted"))
        #expect(result.output.contains("not"))
    }

    @Test(arguments: [true, false])
    func statusReadsOnlyItsOwnAppAndDoesNotDispatch(running: Bool) async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let application = try app(in: temporary)
        let runtime = Runtime(running: running)
        let result = await DockGroupsCLI.run(arguments: ["status"], application: { application }, runtime: runtime)
        #expect(result.exitCode == (running ? 0 : 3))
        #expect(result.output == "\(running ? "running" : "stopped") 9.8.7\n")
        #expect(result.errors.isEmpty)
        #expect(runtime.statusChecks == 1 && runtime.urls.isEmpty)
    }

    @Test func versionComesFromTheContainingAppWithoutCheckingItsRunningState() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let application = try app(in: temporary)
        let runtime = Runtime()
        let result = await DockGroupsCLI.run(arguments: ["--version"], application: { application }, runtime: runtime)
        #expect(result.exitCode == 0 && result.output == "9.8.7\n" && result.errors.isEmpty)
        #expect(runtime.statusChecks == 0 && runtime.urls.isEmpty)
    }

    @Test(arguments: [true, false])
    func dispatchReportsAcceptanceRatherThanCompletion(accepted: Bool) async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let application = try app(in: temporary)
        let runtime = Runtime(accepted: accepted)
        let result = await DockGroupsCLI.run(arguments: ["start", "Private Group"], application: { application }, runtime: runtime)
        #expect(result.exitCode == (accepted ? 0 : 3))
        #expect(result.output.isEmpty && !result.errors.contains("Private Group") && !result.errors.contains(temporary.url.path))
        #expect(result.errors.contains(accepted ? "dispatch accepted" : "dispatch failed"))
        #expect(runtime.urls.count == 1 && runtime.applications == [application])
        #expect(LinkCommand(url: try #require(runtime.urls.first)) == .switching(.start("Private Group")))
        #expect(runtime.statusChecks == 0) // A stopped app can be launched by URL delivery.
    }

    @Test(arguments: ["status", "--version", "start"])
    func unbundledExecutablesFailWithoutDispatch(verb: String) async {
        let runtime = Runtime()
        let result = await DockGroupsCLI.run(arguments: verb == "start" ? [verb, "Work"] : [verb], application: { nil }, runtime: runtime)
        #expect(result.exitCode == 3 && result.output.isEmpty)
        #expect(result.errors.contains("bundled"))
        #expect(runtime.urls.isEmpty && runtime.statusChecks == 0)
    }

    @Test func aSymlinkResolvesToTheContainingAppAndIgnoresOtherRunningCopies() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let application = try app(in: temporary)
        let cli = application.url.appending(path: "Contents/MacOS/cybokrondockgroups")
        let symlink = temporary.url.appending(path: "linked-cli")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: cli)
        #expect(CLIApplication(executableURL: symlink) == application)
        #expect(application.matches(bundleIdentifier: CLIApplication.bundleIdentifier, bundleURL: application.url,
            executableURL: application.mainExecutableURL, isTerminated: false))
        #expect(!application.matches(bundleIdentifier: CLIApplication.bundleIdentifier, bundleURL: URL(fileURLWithPath: "/Other.app"),
            executableURL: application.mainExecutableURL, isTerminated: false))
        #expect(!application.matches(bundleIdentifier: CLIApplication.bundleIdentifier, bundleURL: application.url,
            executableURL: cli, isTerminated: false))
        #expect(!application.matches(bundleIdentifier: "another.app", bundleURL: application.url,
            executableURL: application.mainExecutableURL, isTerminated: false))
        #expect(!application.matches(bundleIdentifier: CLIApplication.bundleIdentifier, bundleURL: application.url,
            executableURL: application.mainExecutableURL, isTerminated: true))
        #expect(!application.matches(bundleIdentifier: nil, bundleURL: nil, executableURL: nil, isTerminated: false))
    }

    @Test func unrelatedOrMalformedAppBundlesAreNotUsed() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        for (index, overrides) in [["CFBundleIdentifier": "other.app"], ["CFBundleShortVersionString": "bad\nversion"],
            ["CFBundleExecutable": "cybokrondockgroups"]].enumerated() {
            let bundle = try temporary.makeAppBundle(named: "Invalid\(index)", info: [
                "CFBundleIdentifier": CLIApplication.bundleIdentifier, "CFBundleShortVersionString": "9.8.7", "CFBundleExecutable": "Main",
            ].merging(overrides) { $1 })
            #expect(CLIApplication(executableURL: bundle.appending(path: "Contents/MacOS/cybokrondockgroups")) == nil)
        }
        #expect(CLIApplication(executableURL: temporary.url.appending(path: "cybokrondockgroups")) == nil)
    }

    private func app(in temporary: TemporaryDirectory) throws -> CLIApplication {
        let bundle = try temporary.makeAppBundle(named: "CLI Test", info: [
            "CFBundleIdentifier": CLIApplication.bundleIdentifier, "CFBundleShortVersionString": "9.8.7", "CFBundleExecutable": "Main",
        ])
        let directory = bundle.appending(path: "Contents/MacOS")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["Main", "cybokrondockgroups"] { try Data().write(to: directory.appending(path: name)) }
        return try #require(CLIApplication(executableURL: directory.appending(path: "cybokrondockgroups")))
    }

    @MainActor private final class Runtime: CLIRuntime {
        var running: Bool
        var accepted: Bool
        var statusChecks = 0
        var urls: [URL] = []
        var applications: [CLIApplication] = []
        init(running: Bool = false, accepted: Bool = true) { self.running = running; self.accepted = accepted }
        func isRunning(_ application: CLIApplication) -> Bool { statusChecks += 1; return running }
        func dispatch(_ url: URL, to application: CLIApplication) async -> Bool {
            urls.append(url); applications.append(application); return accepted
        }
    }
}
