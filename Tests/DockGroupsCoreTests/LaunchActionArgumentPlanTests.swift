import Foundation
import Testing
@testable import DockGroupsCore

/// Launch actions, slice 3, computing part (docs/design/launch-action-argv-slice.md): the argument
/// plan for a website item's browser profile. Nothing here starts or opens anything.
@Suite("Launch actions: argument plan")
struct LaunchActionArgumentPlanTests {
    typealias Plan = LaunchActionArgumentPlan

    static let url = URL(string: "https://github.com/cybokron")!

    static func enabled(_ browser: BrowserFamily = .chrome, _ name: String = "Work") -> LaunchActionSetting {
        .enabled(.browserProfile(browser: browser, profileName: name))
    }

    /// Records the identifiers the installation lookup was asked about.
    final class Lookup {
        var asked: [String] = []
        let installed: Bool
        init(installed: Bool = true) { self.installed = installed }
        func callAsFunction(_ identifier: String) -> Bool { asked.append(identifier); return installed }
    }

    /// The plan with every check passing except those the arguments change; the installation
    /// lookup is recorded by `lookup`.
    static func plan(
        _ setting: LaunchActionSetting = enabled(),
        kind: AppReference.Kind = .website,
        url: URL = url,
        browser: String = "com.google.Chrome",
        lookup: Lookup = Lookup()
    ) -> Result<Plan, LaunchActionArgumentRefusal> {
        Plan.make(setting: setting, itemKind: kind, url: url, browserBundleIdentifier: browser, isInstalled: lookup.callAsFunction)
    }

    // MARK: - Valid plans

    static let expected: [(BrowserFamily, String, [String])] = [
        (.chrome, "com.google.Chrome", ["--profile-directory=Work"]),
        (.edge, "com.microsoft.edgemac", ["--profile-directory=Work"]),
        (.brave, "com.brave.Browser", ["--profile-directory=Work"]),
        (.firefox, "org.mozilla.firefox", ["-P", "Work"]),
    ]

    @Test(arguments: expected)
    func eachBrowserGetsItsTemplate(browser: BrowserFamily, bundleIdentifier: String, arguments: [String]) throws {
        let lookup = Lookup()
        let plan = try Self.plan(Self.enabled(browser), browser: bundleIdentifier, lookup: lookup).get()
        #expect(plan.executableBundleIdentifier == bundleIdentifier)
        #expect(plan.arguments == arguments)
        #expect(plan.url == Self.url)
        #expect(lookup.asked == [bundleIdentifier])
        #expect(browser.bundleIdentifiers == [bundleIdentifier])
        #expect(BrowserFamily.family(forBundleIdentifier: bundleIdentifier) == browser)
    }

    @Test func aNameWithInnerSpacesStaysOneValue() throws {
        let chrome = try Self.plan(Self.enabled(.chrome, "Profile 1")).get()
        #expect(chrome.arguments == ["--profile-directory=Profile 1"])
        let firefox = try Self.plan(Self.enabled(.firefox, "Profile 1"), browser: "org.mozilla.firefox").get()
        #expect(firefox.arguments == ["-P", "Profile 1"])
        let unicode = try Self.plan(Self.enabled(.brave, "İş Çalışma"), browser: "com.brave.Browser").get()
        #expect(unicode.arguments == ["--profile-directory=İş Çalışma"])
    }

    @Test func theBundleIdentifierIsComparedIgnoringCaseAndWrittenCanonically() throws {
        let lookup = Lookup()
        let plan = try Self.plan(browser: "COM.GOOGLE.chrome", lookup: lookup).get()
        #expect(plan.executableBundleIdentifier == "com.google.Chrome")
        #expect(lookup.asked == ["com.google.Chrome"])
    }

    @Test func anItemWithAnActionGetsItsOwnAddress() throws {
        var item = GroupItem(websiteURL: URL(string: "https://example.com/docs")!, name: "Docs")
        item.setLaunchAction(.browserProfile(browser: .edge, profileName: "Work"))
        let plan = try #require(Plan.make(for: item, browserBundleIdentifier: "com.microsoft.edgemac", isInstalled: { _ in true })).get()
        #expect(plan.url.absoluteString == "https://example.com/docs")
        #expect(plan.arguments == ["--profile-directory=Work"])
    }

    @Test func anItemWithoutAnActionHasNoPlan() {
        let item = GroupItem(websiteURL: Self.url, name: "GitHub")
        let lookup = Lookup()
        #expect(Plan.make(for: item, browserBundleIdentifier: "com.google.Chrome", isInstalled: lookup.callAsFunction) == nil)
        #expect(lookup.asked.isEmpty)
    }

    // MARK: - Refusals

    @Test func theRefusalsAreFixed() {
        #expect(LaunchActionArgumentRefusal.allCases.map(\.rawValue) == [
            "unsupportedBrowser", "browserNotInstalled", "itemKindMismatch", "actionNeedsReview", "actionDisabled", "urlRejected",
        ])
    }

    @Test(arguments: [
        "com.apple.Safari", "org.mozilla.firefox", "com.microsoft.edgemac", "com.google.Chrome.canary",
        "com.google.Chrome.beta", "com.google", "", "Google Chrome", "/Applications/Google Chrome.app",
        "com.google.Chrome ", "com.google.Chrome\n",
    ])
    func aBrowserOutsideTheTemplatesSetIsRefused(identifier: String) {
        let lookup = Lookup()
        #expect(Self.plan(browser: identifier, lookup: lookup) == .failure(.unsupportedBrowser))
        #expect(lookup.asked.isEmpty)
    }

    @Test func aFirefoxActionIsNotStartedInAChromiumBrowser() {
        for identifier in ["com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser"] {
            #expect(Self.plan(Self.enabled(.firefox), browser: identifier) == .failure(.unsupportedBrowser))
        }
        #expect(BrowserFamily.family(forBundleIdentifier: "com.apple.Safari") == nil)
    }

    @Test func aMissingBrowserIsRefusedWithoutAnotherOne() {
        let lookup = Lookup(installed: false)
        #expect(Self.plan(lookup: lookup) == .failure(.browserNotInstalled))
        #expect(lookup.asked == ["com.google.Chrome"])
    }

    @Test(arguments: [AppReference.Kind.application, .file, .folder])
    func anActionOnAnotherKindIsRefused(kind: AppReference.Kind) {
        let lookup = Lookup()
        #expect(Self.plan(kind: kind, lookup: lookup) == .failure(.itemKindMismatch))
        #expect(Self.plan(.needsReview(.invalid(.unsupportedItemKind)), kind: kind, lookup: lookup) == .failure(.itemKindMismatch))
        #expect(lookup.asked.isEmpty)
    }

    @Test func anAppItemKeepsItsActionOffAndGetsNoPlan() {
        var app = AppReference(bundleIdentifier: "com.google.Chrome", name: "Google Chrome")
        app.setLaunchAction(.browserProfile(browser: .chrome, profileName: "Work"))
        #expect(Plan.make(for: app, browserBundleIdentifier: "com.google.Chrome", isInstalled: { _ in true }) == .failure(.itemKindMismatch))
    }

    @Test(arguments: [
        LaunchActionRejection.forbiddenKey, .unknownKey, .unknownTemplate, .unknownBrowser, .wrongValueType,
        .missingProfile, .notAnObject, .profileName(.leadingHyphen), .profileName(.controlCharacter),
    ])
    func anActionNeedingReviewIsRefused(rejection: LaunchActionRejection) {
        let lookup = Lookup()
        #expect(Self.plan(.needsReview(.invalid(rejection)), lookup: lookup) == .failure(.actionNeedsReview))
        #expect(lookup.asked.isEmpty)
    }

    @Test func anImportedActionIsOff() throws {
        let lookup = Lookup()
        let action = LaunchAction.browserProfile(browser: .chrome, profileName: "Work")
        #expect(Self.plan(.needsReview(.imported(action)), lookup: lookup) == .failure(.actionDisabled))
        #expect(Self.plan(LaunchActionSetting.enabled(action).disabledForImport, lookup: lookup) == .failure(.actionDisabled))
        var item = GroupItem(websiteURL: Self.url, name: "GitHub")
        item.launchActionSetting = .needsReview(.imported(action))
        #expect(Plan.make(for: item, browserBundleIdentifier: "com.google.Chrome", isInstalled: lookup.callAsFunction) == .failure(.actionDisabled))
        #expect(lookup.asked.isEmpty)
    }

    // MARK: - Checked again (defence in depth)

    /// Names an enabled case can be built with in code, bypassing the decoder: each must be refused.
    static let injectedNames: [String] = [
        "", "-x", "--load-extension=/tmp/evil", "--remote-debugging-port=9222", "--user-data-dir=/tmp/p",
        "-no-remote", "Work\n--load-extension=/tmp/evil", "Work\0", "Work\r", "Work\t2", "\u{1B}[31m",
        "Work;rm -rf ~", "Work|cat", "Work&", "$(id)", "`id`", "Work>out", "a\"b", "a'b", "a=b", "a:b",
        "../Default", "/tmp/profile", "~/profile", "file:///tmp", "FILE:x", " Work", "Work ", "Wo\u{202E}rk",
        "Wo\u{200B}rk", "Wo\u{00A0}rk", "Wo\u{2028}rk", "Wo\u{E000}rk", String(repeating: "a", count: 65),
    ]

    @Test(arguments: injectedNames)
    func anEnabledCaseWithABadNameGetsNoPlan(name: String) {
        for browser in BrowserFamily.allCases {
            let lookup = Lookup()
            let result = Self.plan(Self.enabled(browser, name), browser: browser.bundleIdentifiers[0], lookup: lookup)
            #expect(result == .failure(.actionNeedsReview), "\(browser) \(name.debugDescription)")
            #expect(lookup.asked.isEmpty)
        }
    }

    @Test(arguments: ["", "-x", "--a", "a=b", "a\nb", "a\0b", "a\tb", " a", "a ", "a\u{200B}b", "a\u{00A0}b", "a\u{2029}b"])
    func theArgumentBuilderRefusesValuesByItself(value: String) {
        // Independent of the grammar: even a value the grammar let through can't change the shape.
        for browser in BrowserFamily.allCases {
            #expect(Plan.profileArguments(browser: browser, profileName: value) == nil, "\(browser) \(value.debugDescription)")
        }
        #expect(!Plan.isSingleArgumentValue(value))
    }

    // MARK: - Address policy

    @Test(arguments: [
        "https://example.com", "https://example.com/path?q=1#top", "http://example.com", "https://localhost:8080",
        "https://192.168.1.10/admin", "HTTPS://Example.com/x",
    ])
    func webAddressesArePlanned(address: String) throws {
        let url = try #require(URL(string: address))
        let plan = try Self.plan(url: url).get()
        #expect(plan.url == url)
        #expect(!plan.arguments.contains { $0.contains(address) }, "the address is never an argument")
    }

    @Test(arguments: [
        "mailto:me@example.com", "file:///etc/passwd", "javascript:alert(1)", "data:text/html,<b>x</b>",
        "ftp://example.com", "chrome://settings", "about:blank", "x-apple-script://run", "https://user:pw@example.com",
        "https://user@example.com", "example.com", "https://", "https:///path", "https://exa mple.com",
        "https://example", "//example.com", "vnc://example.com",
    ])
    func otherAddressesAreRefused(address: String) {
        guard let url = URL(string: address) else { return }
        let lookup = Lookup()
        #expect(Self.plan(url: url, lookup: lookup) == .failure(.urlRejected), "\(address)")
        #expect(lookup.asked.isEmpty)
    }

    // MARK: - Shape: one element per argument, no shell, no environment

    @Test(arguments: BrowserFamily.allCases)
    func argumentsHaveTheTemplatesShapeOnly(browser: BrowserFamily) throws {
        for name in ["Work", "Default", "Profile 1", "Profile 12", "a b c d", "İş", "x"] {
            let plan = try Self.plan(Self.enabled(browser, name), browser: browser.bundleIdentifiers[0]).get()
            switch browser {
            case .chrome, .edge, .brave:
                #expect(plan.arguments.count == 1)
                let element = try #require(plan.arguments.first)
                #expect(element == Plan.chromiumProfileOption + name)
                #expect(element.filter { $0 == "=" }.count == 1)
            case .firefox:
                #expect(plan.arguments == [Plan.firefoxProfileOption, name])
                #expect(!plan.arguments[1].hasPrefix("-"))
            }
            for element in plan.arguments {
                #expect(Plan.isSingleArgument(element))
                #expect(!["sh", "/bin/sh", "/bin/zsh", "-c", "bash", "open", "/usr/bin/open", "--args"].contains(element))
                #expect(!element.contains("\n") && !element.contains("\0"))
            }
            #expect(!plan.arguments.contains { $0.hasPrefix("--user-data-dir") || $0 == "-profile" || $0.hasPrefix("--load-extension") })
        }
    }

    @Test func aPlanHoldsNoEnvironment() throws {
        let plan = try Self.plan().get()
        let fields = Mirror(reflecting: plan).children.compactMap(\.label)
        #expect(fields == ["executableBundleIdentifier", "arguments", "url"])
    }

    // MARK: - Source scan

    static let planFiles = [
        "DockGroupsCore/LaunchActions/LaunchActionArgumentPlan.swift",
        "DockGroupsCore/LaunchActions/LaunchActionPlanProbe.swift",
    ]

    /// What starting or opening something, or asking the system about apps, looks like.
    static let forbiddenTokens = [
        "NSWorkspace", "Process", "open(", "LaunchServices", "OpenConfiguration", "openApplication",
        "urlForApplication", "NSRunningApplication", "ApplicationWorkspace", "GroupLauncher", "NSAppleScript",
        "OSAScript", "AppleScript", "/bin/sh", "/bin/zsh", "import AppKit", "posix_spawn", "execv", "system(",
        "NSTask", "executableURL", "FileManager", "LSCopy", "LSOpen",
    ]

    @Test func thePlanAndItsDryRunStartAndOpenNothing() throws {
        let files = try LaunchActionExecutionScanTests.swiftFiles()
        for path in Self.planFiles {
            let file = try #require(files.first { $0.path == path }, "\(path) is missing")
            for token in Self.forbiddenTokens {
                #expect(!file.text.contains(token), "\(path) mentions \(token)")
            }
        }
    }

    @Test func onlyTheLauncherAndRunnerUseAPlanAndNoAppFile() throws {
        let using = try LaunchActionExecutionScanTests.swiftFiles()
            .filter { $0.text.contains("LaunchActionArgumentPlan") }
            .map(\.path)
        #expect(Set(using) == Set(Self.planFiles + [
            LaunchActionExecutionScanTests.runnerFile,
            "DockGroupsCore/Launching/GroupLauncher.swift",
        ]))
    }
}

/// The hidden `--launch-plan` dry run: inert without its variable, computing only with it.
@Suite("Launch actions: plan dry run")
@MainActor
struct LaunchActionPlanProbeTests {
    typealias Probe = LaunchActionPlanProbe

    nonisolated static let enabled = [Probe.environmentVariable: "1"]

    func run(_ arguments: [String], environment: [String: String] = enabled) async -> (CLIResult, resolved: Bool, runtime: Runtime) {
        let runtime = Runtime()
        var resolved = false
        let result = await DockGroupsCLI.run(
            arguments: arguments,
            application: { resolved = true; return nil },
            runtime: runtime,
            environment: environment,
            layoutProbe: { _ in CLIResult(exitCode: 99, output: "layout", errors: "") }
        )
        return (result, resolved, runtime)
    }

    static func json(_ result: CLIResult) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
    }

    @Test(arguments: [[String: String](), ["CYBOKRON_LAUNCH_PROBE": "0"], ["CYBOKRON_LAUNCH_PROBE": "true"],
                      ["CYBOKRON_LAUNCH_PROBE": ""], ["CYBOKRON_LAUNCH_PROBE": " 1"], ["cybokron_launch_probe": "1"],
                      ["CYBOKRON_LAYOUT_PROBE": "1"]])
    func withoutTheVariableTheOptionIsUnknown(environment: [String: String]) async {
        let (result, resolved, runtime) = await run([Probe.option, "chrome", "Work", "https://example.com"], environment: environment)
        #expect(result == CLIResult(exitCode: 2, output: "", errors: DockGroupsCLI.help))
        #expect(!resolved)
        #expect(runtime.urls.isEmpty && runtime.statusChecks == 0)
    }

    @Test func helpAndReadmeDoNotMentionTheDryRun() throws {
        for text in [DockGroupsCLI.help, try String(contentsOf: RepositoryScript.root.appending(path: "README.md"), encoding: .utf8)] {
            #expect(!text.contains(Probe.option))
            #expect(!text.contains(Probe.environmentVariable))
        }
    }

    @Test func aPlanIsPrintedAndNothingIsOpened() async throws {
        let (result, resolved, runtime) = await run([Probe.option, "chrome", "Work", "https://example.com"])
        #expect(result.exitCode == 0)
        #expect(result.errors == "Dry run: planned; nothing was opened.\n")
        #expect(!resolved && runtime.urls.isEmpty && runtime.statusChecks == 0)
        let json = try Self.json(result)
        #expect(json["status"] as? String == "planned")
        #expect(json["browser"] as? String == "chrome")
        #expect(json["executableBundleIdentifier"] as? String == "com.google.Chrome")
        #expect(json["arguments"] as? [String] == ["--profile-directory=Work"])
        #expect(json["url"] as? String == "https://example.com")
        #expect(json["dryRun"] as? Bool == true)
        #expect(json["installationChecked"] as? Bool == false)
        #expect(json["formatVersion"] as? Int == 1)
        #expect(json["refusal"] == nil)
        #expect(Set(json.keys) == ["formatVersion", "dryRun", "installationChecked", "status", "browser", "executableBundleIdentifier", "arguments", "url"])
    }

    @Test func firefoxGetsTwoElements() async throws {
        let (result, _, _) = await run([Probe.option, "firefox", "Profile 1", "https://example.com/a"])
        let json = try Self.json(result)
        #expect(json["arguments"] as? [String] == ["-P", "Profile 1"])
        #expect(json["executableBundleIdentifier"] as? String == "org.mozilla.firefox")
    }

    @Test(arguments: [
        (["safari", "Work", "https://example.com"], "unsupportedBrowser"),
        (["Chrome", "Work", "https://example.com"], "unsupportedBrowser"),
        (["chrome", "--load-extension=/tmp/evil", "https://example.com"], "actionNeedsReview"),
        (["edge", "Work;id", "https://example.com"], "actionNeedsReview"),
        (["brave", "Work", "mailto:secret@example.com"], "urlRejected"),
        (["firefox", "Work", "file:///etc/hosts"], "urlRejected"),
    ])
    func refusalsPrintOnlyTheReason(arguments: [String], refusal: String) async throws {
        let (result, resolved, runtime) = await run([Probe.option] + arguments)
        #expect(result.exitCode == 3)
        #expect(result.errors == "Dry run: refused (\(refusal)); nothing was opened.\n")
        #expect(!resolved && runtime.urls.isEmpty)
        let json = try Self.json(result)
        #expect(json["status"] as? String == "refused")
        #expect(json["refusal"] as? String == refusal)
        #expect(json["arguments"] == nil && json["url"] == nil && json["executableBundleIdentifier"] == nil)
        if BrowserFamily(rawValue: arguments[0]) == nil {
            #expect(!result.output.contains(arguments[0]))
        }
        #expect(!result.output.contains(arguments[1]))
        #expect(!result.output.contains(arguments[2]))
    }

    @Test func aPrivateWindowPlanShowsTemplateArgumentsAndNoExtraAddress() async throws {
        let (result, resolved, runtime) = await run([Probe.option, "chrome", "--private", "https://example.com"])
        #expect(result.exitCode == 0)
        #expect(result.errors == "Dry run: planned; nothing was opened.\n")
        #expect(!resolved && runtime.urls.isEmpty && runtime.statusChecks == 0)
        let json = try Self.json(result)
        #expect(json["status"] as? String == "planned")
        #expect(json["template"] as? String == "browserPrivate")
        #expect(json["arguments"] as? [String] == ["--incognito", "https://example.com"])
        #expect(json["urlsToOpen"] as? [String] == [])
        #expect(json["executableBundleIdentifier"] as? String == "com.google.Chrome")
        #expect(json["url"] as? String == "https://example.com")
        #expect(json["dryRun"] as? Bool == true && json["installationChecked"] as? Bool == false)
        #expect(json["refusal"] == nil)
    }

    @Test func aProfilePlanHasNoTemplateOrAddressList() async throws {
        let (result, _, _) = await run([Probe.option, "chrome", "Work", "https://example.com"])
        let json = try Self.json(result)
        #expect(json["template"] == nil && json["urlsToOpen"] == nil)
    }

    @Test(arguments: [[String: String](), ["CYBOKRON_LAUNCH_PROBE": "0"], ["CYBOKRON_LAUNCH_PROBE": "true"]])
    func thePrivateModeIsUnknownWithoutTheVariable(environment: [String: String]) async {
        let (result, resolved, runtime) = await run([Probe.option, "chrome", "--private", "https://example.com"], environment: environment)
        #expect(result == CLIResult(exitCode: 2, output: "", errors: DockGroupsCLI.help))
        #expect(!resolved && runtime.urls.isEmpty && runtime.statusChecks == 0)
    }

    @Test(arguments: [
        (["safari", "--private", "https://example.com"], "unsupportedBrowser"),
        (["brave", "--private", "mailto:secret@example.com"], "urlRejected"),
        (["firefox", "--private", "file:///etc/hosts"], "urlRejected"),
    ])
    func privateRefusalsPrintOnlyTheReason(arguments: [String], refusal: String) async throws {
        let (result, resolved, runtime) = await run([Probe.option] + arguments)
        #expect(result.exitCode == 3)
        #expect(result.errors == "Dry run: refused (\(refusal)); nothing was opened.\n")
        #expect(!resolved && runtime.urls.isEmpty)
        let json = try Self.json(result)
        #expect(json["refusal"] as? String == refusal)
        #expect(json["arguments"] == nil && json["urlsToOpen"] == nil && json["template"] == nil)
        #expect(!result.output.contains(arguments[2]))
    }

    @Test(arguments: [[String](), ["chrome"], ["chrome", "Work"], ["chrome", "Work", "https://example.com", "extra"]])
    func badArgumentsPrintUsage(rest: [String]) async {
        let (result, resolved, _) = await run([Probe.option] + rest)
        #expect(result == CLIResult(exitCode: 2, output: "", errors: Probe.usage))
        #expect(!resolved)
    }

    @MainActor final class Runtime: CLIRuntime {
        var statusChecks = 0
        var urls: [URL] = []
        func isRunning(_ application: CLIApplication) -> Bool { statusChecks += 1; return false }
        func dispatch(_ url: URL, to application: CLIApplication) async -> Bool { urls.append(url); return true }
    }
}
