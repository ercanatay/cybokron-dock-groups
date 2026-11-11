import Foundation
import Testing
@testable import DockGroupsCore

/// Launch actions, core slice (docs/design/launch-action-core-slice.md): the template model, the
/// strict decoder and the profile-name grammar. Nothing here opens anything.
@Suite("Launch actions: model, decoder and grammar")
struct LaunchActionTests {
    static let website = GroupItem(websiteURL: URL(string: "https://github.com/cybokron")!, name: "GitHub")
    static let app = AppReference(bundleIdentifier: "com.google.Chrome", name: "Google Chrome")
    static let folder = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Projects/cybokron", isDirectory: true), kind: .folder)

    static func object(_ item: GroupItem) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
    }

    /// `item` as saved, with `launchAction` set to `value` (any JSON value).
    static func saved(_ item: GroupItem = website, launchAction value: Any) throws -> Data {
        var object = try object(item)
        object["launchAction"] = value
        return try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
    }

    static func decode(_ data: Data) throws -> GroupItem {
        try JSONDecoder().decode(GroupItem.self, from: data)
    }

    static func action(_ browser: String = "chrome", _ profile: Any = "Work") -> [String: Any] {
        ["template": "browserProfile", "browser": browser, "profile": profile]
    }

    /// Decodes `value` as the website's launch action and checks that it was refused for
    /// `rejection`, that the item is otherwise as without one, and that nothing of it is written.
    static func expectRefused(_ value: Any, _ rejection: LaunchActionRejection, item base: GroupItem = website, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let item = try decode(saved(base, launchAction: value))
        #expect(item.launchActionSetting == .needsReview(.invalid(rejection)), sourceLocation: sourceLocation)
        #expect(item.launchAction == nil, sourceLocation: sourceLocation)
        #expect(item.launchActionNeedsReview, sourceLocation: sourceLocation)
        var withoutAction = item
        withoutAction.launchActionSetting = nil
        #expect(withoutAction == base, sourceLocation: sourceLocation)
        let written = try JSONEncoder().encode(item)
        #expect(try object(item)["launchAction"] == nil, sourceLocation: sourceLocation)
        #expect(Set(try object(item).keys) == Set(try object(base).keys), sourceLocation: sourceLocation)
        #expect(!String(decoding: written, as: UTF8.self).contains("launchAction"), sourceLocation: sourceLocation)
    }

    // MARK: - Valid actions

    static let validActions: [(browser: BrowserFamily, profile: String)] = [
        (.chrome, "Default"),
        (.chrome, "Profile 2"),
        (.edge, "Work"),
        (.edge, "Profile 12"),
        (.brave, "Personal"),
        (.brave, "Ünal’s profile"),
        (.firefox, "default-release"),
        (.firefox, "İş_2026"),
        (.firefox, String(repeating: "a", count: BrowserProfileName.maximumLength)),
    ]

    @Test(arguments: validActions)
    func validProfilesRoundTrip(_ browser: BrowserFamily, _ profile: String) throws {
        let item = try Self.decode(Self.saved(launchAction: Self.action(browser.rawValue, profile)))
        let expected = LaunchAction.browserProfile(browser: browser, profileName: profile)
        #expect(item.launchAction == expected)
        #expect(item.launchActionSetting == .enabled(expected))
        #expect(!item.launchActionNeedsReview)

        let saved = try Self.object(item)
        #expect(saved["launchAction"] as? [String: String] == ["template": "browserProfile", "browser": browser.rawValue, "profile": profile])
        #expect(try Self.decode(JSONEncoder().encode(item)) == item)

        var set = Self.website
        set.setLaunchAction(expected)
        #expect(set == item)
    }

    @Test func theBrowsersAreChromeEdgeBraveAndFirefox() {
        #expect(BrowserFamily.allCases.map(\.rawValue) == ["chrome", "edge", "brave", "firefox"])
    }

    @Test func removingTheActionWritesNothing() throws {
        var item = Self.website
        item.setLaunchAction(.browserProfile(browser: .chrome, profileName: "Work"))
        item.setLaunchAction(nil)
        #expect(item.launchActionSetting == nil)
        #expect(item == Self.website)
        #expect(try Self.object(item)["launchAction"] == nil)
    }

    // MARK: - Profile name grammar

    static let refusedNames: [(String, BrowserProfileNameRejection)] = [
        ("", .empty),
        (String(repeating: "a", count: BrowserProfileName.maximumLength + 1), .tooLong),
        (String(repeating: "é", count: 40) + String(repeating: "\u{301}", count: 25), .tooLong),
        ("-P", .leadingHyphen),
        ("--load-extension=/tmp/x", .leadingHyphen),
        ("--remote-debugging-port=9222", .leadingHyphen),
        ("a/b", .forbiddenCharacter),
        ("a\\b", .forbiddenCharacter),
        ("..", .parentReference),
        ("a..b", .parentReference),
        ("Work..", .parentReference),
        ("~", .looksLikePath),
        ("~/Library/Application Support/Google/Chrome", .looksLikePath),
        ("a~b", .forbiddenCharacter),
        ("$HOME", .forbiddenCharacter),
        ("a$(id)", .forbiddenCharacter),
        ("a;b", .forbiddenCharacter),
        ("a|b", .forbiddenCharacter),
        ("a&b", .forbiddenCharacter),
        ("a>b", .forbiddenCharacter),
        ("a<b", .forbiddenCharacter),
        ("a*b", .forbiddenCharacter),
        ("a?b", .forbiddenCharacter),
        ("a\"b", .forbiddenCharacter),
        ("a'b", .forbiddenCharacter),
        ("a`id`", .forbiddenCharacter),
        ("a=b", .forbiddenCharacter),
        ("a:b", .forbiddenCharacter),
        ("a\u{0}b", .controlCharacter),
        ("\u{0}", .controlCharacter),
        ("a\nb", .controlCharacter),
        ("a\rb", .controlCharacter),
        ("a\tb", .controlCharacter),
        ("a\u{7F}b", .controlCharacter),
        ("a\u{1B}[31m", .controlCharacter),
        ("a\u{2028}b", .controlCharacter),
        ("a\u{2029}b", .controlCharacter),
        ("\u{202E}kroW", .bidiCharacter),
        ("Work\u{202D}", .bidiCharacter),
        ("a\u{2066}b\u{2069}", .bidiCharacter),
        ("a\u{200F}", .bidiCharacter),
        ("a\u{200E}", .bidiCharacter),
        ("a\u{061C}", .bidiCharacter),
        ("a\u{202A}b", .bidiCharacter),
        ("a\u{200B}b", .invisibleCharacter),
        ("\u{FEFF}Work", .invisibleCharacter),
        ("a\u{00A0}b", .invisibleCharacter),
        ("a\u{E000}", .invisibleCharacter),
        ("/Users/me/Library/Firefox/Profiles/x", .looksLikePath),
        ("/", .looksLikePath),
        ("file:///tmp/profile", .looksLikePath),
        ("FILE:x", .looksLikePath),
        (" Work", .surroundingWhitespace),
        ("Work ", .surroundingWhitespace),
        (" ", .surroundingWhitespace),
    ]

    @Test(arguments: refusedNames)
    func refusedProfileNames(_ name: String, _ rejection: BrowserProfileNameRejection) throws {
        #expect(BrowserProfileName.rejection(for: name) == rejection)
        #expect(LaunchAction.browserProfile(browser: .chrome, profileName: name).rejection == .profileName(rejection))
        for browser in BrowserFamily.allCases {
            try Self.expectRefused(Self.action(browser.rawValue, name), .profileName(rejection))
        }
    }

    @Test func namesAreRefusedNotFixed() throws {
        // A trimmed, unescaped or shortened version of the name would be valid; none is kept.
        for name in [" Work ", "Wo\u{0}rk", "Work\n", "\u{202E}Work", String(repeating: "w", count: 65)] {
            let item = try Self.decode(Self.saved(launchAction: Self.action("chrome", name)))
            #expect(item.launchAction == nil, "\(name.debugDescription)")
            guard case .needsReview(.invalid(.profileName)) = item.launchActionSetting else {
                Issue.record("\(name.debugDescription) wasn't refused for its name")
                continue
            }
        }
    }

    @Test func everyRejectionOfTheGrammarIsReachable() {
        let reached = Set(Self.refusedNames.map(\.1))
        #expect(reached == Set(BrowserProfileNameRejection.allCases))
    }

    @Test func anInvalidActionSetInCodeIsKeptForReviewAndNotWritten() throws {
        var item = Self.website
        item.setLaunchAction(.browserProfile(browser: .chrome, profileName: "--load-extension=/tmp/x"))
        #expect(item.launchActionSetting == .needsReview(.invalid(.profileName(.leadingHyphen))))
        #expect(item.launchAction == nil)
        #expect(try Self.object(item)["launchAction"] == nil)
        // Even forced in as enabled, it's neither used nor written.
        item.launchActionSetting = .enabled(.browserProfile(browser: .chrome, profileName: "../x"))
        #expect(item.launchAction == nil)
        #expect(try Self.object(item)["launchAction"] == nil)
        #expect(throws: EncodingError.self) {
            try JSONEncoder().encode(LaunchActionCoding(.browserProfile(browser: .edge, profileName: "a;b")))
        }
    }

    // MARK: - Strict decoder

    static let forbiddenKeys = ["command", "args", "path", "environment", "script", "executable", "shell", "env", "argv", "arguments", "Command", "ENVIRONMENT"]

    @Test(arguments: forbiddenKeys)
    func forbiddenKeysMakeTheActionInvalidAndArentWritten(_ key: String) throws {
        let payload: [Any] = [
            "/bin/zsh -c 'touch /tmp/cybokron-pwned'",
            ["--load-extension=/tmp/cybokron-pwned"],
            ["DYLD_INSERT_LIBRARIES": "/tmp/cybokron-pwned.dylib"],
        ]
        for value in payload {
            var action = Self.action("chrome", "Work")
            action[key] = value
            try Self.expectRefused(action, .forbiddenKey)
            let written = String(decoding: try JSONEncoder().encode(Self.decode(Self.saved(launchAction: action))), as: UTF8.self)
            #expect(!written.contains("cybokron-pwned"))
            #expect(!written.lowercased().contains("\"\(key.lowercased())\""))
        }
        // Alone, without a template, likewise.
        try Self.expectRefused([key: "/bin/sh"], .forbiddenKey)
    }

    @Test func unknownKeysMakeTheActionInvalid() throws {
        for key in ["profileDirectory", "userDataDir", "url", "enabled", "disabled", "Template", ""] {
            var action = Self.action()
            action[key] = "x"
            try Self.expectRefused(action, .unknownKey)
        }
    }

    @Test func unknownTemplatesAndBrowsersAreInvalid() throws {
        for template in ["browser.chromium.profile", "shellCommand", "terminal", "BrowserProfile", ""] {
            try Self.expectRefused(["template": template, "browser": "chrome", "profile": "Work"], .unknownTemplate)
        }
        for browser in ["safari", "vivaldi", "arc", "Chrome", "com.google.Chrome", ""] {
            try Self.expectRefused(Self.action(browser), .unknownBrowser)
        }
    }

    @Test func missingParametersAreInvalid() throws {
        try Self.expectRefused([String: Any](), .missingTemplate)
        try Self.expectRefused(["browser": "chrome", "profile": "Work"], .missingTemplate)
        try Self.expectRefused(["template": "browserProfile", "profile": "Work"], .missingBrowser)
        try Self.expectRefused(["template": "browserProfile", "browser": "chrome"], .missingProfile)
    }

    @Test func wrongTypesAreInvalid() throws {
        try Self.expectRefused(["template": 1, "browser": "chrome", "profile": "Work"], .wrongValueType)
        try Self.expectRefused(["template": "browserProfile", "browser": ["chrome"], "profile": "Work"], .wrongValueType)
        try Self.expectRefused(Self.action("chrome", ["Work"]), .wrongValueType)
        try Self.expectRefused(Self.action("chrome", 2), .wrongValueType)
        try Self.expectRefused(Self.action("chrome", NSNull()), .wrongValueType)
        for value: Any in ["chrome:Work", ["chrome", "Work"], 1, true, NSNull()] {
            try Self.expectRefused(value, .notAnObject)
        }
    }

    @Test func onlyWebsitesTakeABrowserProfile() throws {
        for item in [Self.app, Self.folder] {
            try Self.expectRefused(Self.action(), .unsupportedItemKind, item: item)
            var set = item
            set.setLaunchAction(.browserProfile(browser: .chrome, profileName: "Work"))
            #expect(set.launchActionSetting == .needsReview(.invalid(.unsupportedItemKind)))
            #expect(set.launchAction == nil)
            #expect(try Self.object(set)["launchAction"] == nil)
        }
    }

    // MARK: - Compatibility

    @Test func itemsWithoutTheKeyAreAsBefore() throws {
        for item in [Self.website, Self.app, Self.folder, Self.website.launching(after: 3, with: .app("com.google.Chrome", "Google Chrome"))] {
            let read = try Self.decode(JSONEncoder().encode(item))
            #expect(read.launchActionSetting == nil)
            #expect(!read.launchActionNeedsReview)
            #expect(read == item)
            #expect(try Self.object(read)["launchAction"] == nil)
        }
        #expect(Set(try Self.object(Self.website).keys) == ["bundleIdentifier", "kind", "name", "url"])
    }

    @Test func anInvalidActionDoesntMakeTheItemOrGroupUnreadable() throws {
        // As written by a newer version: a template this one doesn't know.
        let newer: [String: Any] = ["template": "browserProfile.v2", "browser": "chrome", "profile": "Work", "container": "Banking"]
        let item = try Self.decode(Self.saved(launchAction: newer))
        #expect(item.kind == .website)
        #expect(item.websiteURL == Self.website.websiteURL)
        #expect(item.launchAction == nil)

        let group = DockGroup(name: "Work", apps: [Self.website, Self.app])
        var groupObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(group)) as? [String: Any])
        var apps = try #require(groupObject["apps"] as? [[String: Any]])
        apps[0]["launchAction"] = newer
        apps[1]["launchAction"] = ["command": "/bin/sh"]
        groupObject["apps"] = apps
        let read = try JSONDecoder().decode(DockGroup.self, from: JSONSerialization.data(withJSONObject: groupObject))
        #expect(read.apps.map(\.bundleIdentifier) == group.apps.map(\.bundleIdentifier))
        #expect(read.apps.allSatisfy { $0.launchActionNeedsReview })
        #expect(!String(decoding: try JSONEncoder().encode(read), as: UTF8.self).contains("launchAction"))
    }

    @Test func theGroupsFileKeepsItsFormatVersionAndAValidAction() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let fileURL = directory.url.appending(path: "groups.json")
        let persistence = JSONFileGroupPersistence(fileURL: fileURL)
        var website = Self.website
        website.setLaunchAction(.browserProfile(browser: .firefox, profileName: "default-release"))
        try persistence.saveGroups([DockGroup(name: "Work", apps: [website, Self.app])])

        let file = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        #expect(file["formatVersion"] as? Int == 1)
        #expect(try persistence.loadGroups().first?.apps == [website, Self.app])

        // A version without launch actions drops the key on its next save; the item stays.
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        var object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        var groups = try #require(object["groups"] as? [[String: Any]])
        var apps = try #require(groups[0]["apps"] as? [[String: Any]])
        #expect(apps[0].removeValue(forKey: "launchAction") != nil)
        groups[0]["apps"] = apps
        object["groups"] = groups
        try JSONSerialization.data(withJSONObject: object).write(to: fileURL)
        #expect(try persistence.loadGroups().first?.apps == [Self.website, Self.app])
    }

    @Test func anInvalidActionInTheGroupsFileIsDroppedOnTheNextSave() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let fileURL = directory.url.appending(path: "groups.json")
        let persistence = JSONFileGroupPersistence(fileURL: fileURL)
        try persistence.saveGroups([DockGroup(name: "Work", apps: [Self.website])])
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        var groups = try #require(object["groups"] as? [[String: Any]])
        var apps = try #require(groups[0]["apps"] as? [[String: Any]])
        apps[0]["launchAction"] = ["template": "browserProfile", "browser": "chrome", "profile": "Work", "shell": "/bin/zsh"]
        groups[0]["apps"] = apps
        object["groups"] = groups
        try JSONSerialization.data(withJSONObject: object).write(to: fileURL)

        let loaded = try persistence.loadGroups()
        #expect(loaded.first?.apps.first?.launchActionSetting == .needsReview(.invalid(.forbiddenKey)))
        try persistence.saveGroups(loaded)
        let rewritten = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(!rewritten.contains("launchAction"))
        #expect(!rewritten.contains("/bin/zsh"))
    }
}

/// Proof that this slice executes nothing: launch actions appear only in the model, its coding
/// and the import paths that turn them off — never next to a launcher, a workspace call or a
/// process. A source scan of this checkout, like `LayoutPlannerSourceScanTests`.
@Suite("Launch actions: nothing executes them")
struct LaunchActionExecutionScanTests {
    static let sources = LocalizationTests.root.appending(path: "Sources", directoryHint: .isDirectory)

    /// Words that name the launch action types or the item field.
    static let actionTokens = ["LaunchAction", "launchAction", "BrowserFamily", "BrowserProfileName"]

    /// The only files that may mention launch actions: the model and its coding (slice 2), the
    /// argument plan and its dry run, and the CLI line that gates the dry run (slice 3, computing
    /// part). No launcher, app or CLI executable file.
    static let allowedFiles: Set<String> = [
        "DockGroupsCore/Model/LaunchAction.swift",
        "DockGroupsCore/Model/AppReference.swift",
        "DockGroupsCore/Persistence/SettingsBackup.swift",
        "DockGroupsCore/Standalone/AgentConfiguration.swift",
        "DockGroupsCore/LaunchActions/LaunchActionArgumentPlan.swift",
        "DockGroupsCore/LaunchActions/LaunchActionPlanProbe.swift",
        "DockGroupsCore/Commands/DockGroupsCLI.swift",
    ]

    /// What running or opening something looks like.
    static let executionTokens = [
        "Process(", "Process.", "posix_spawn", "execv", "system(", "NSTask", "executableURL",
        "NSWorkspace", "OpenConfiguration", "openApplication", "open(_:", "ApplicationWorkspace",
        "GroupLauncher", "NSAppleScript", "OSAScript", "/bin/sh", "/bin/zsh", "import AppKit",
    ]

    static func swiftFiles() throws -> [(path: String, text: String)] {
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var files: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = String(url.standardizedFileURL.path.dropFirst(sources.standardizedFileURL.path.count + 1))
            files.append((relative, try String(contentsOf: url, encoding: .utf8)))
        }
        return files.sorted { $0.0 < $1.0 }
    }

    @Test func onlyTheModelCodingAndImportMentionLaunchActions() throws {
        let files = try Self.swiftFiles()
        #expect(files.count > 100, "the scan should see the whole Sources tree")
        let mentioning = Set(files.filter { file in Self.actionTokens.contains { file.text.contains($0) } }.map(\.path))
        #expect(mentioning == Self.allowedFiles)
        #expect(!mentioning.contains { $0.hasPrefix("CybokronDockGroups/") || $0.contains("/Launching/") || $0.hasPrefix("CybokronDockGroupsCLI/") })
    }

    @Test func noLineWithALaunchActionRunsOrOpensAnything() throws {
        for file in try Self.swiftFiles() where Self.allowedFiles.contains(file.path) {
            for line in file.text.split(separator: "\n", omittingEmptySubsequences: false)
            where Self.actionTokens.contains(where: { line.contains($0) }) {
                for token in Self.executionTokens {
                    #expect(!line.contains(token), "\(file.path): \(line)")
                }
            }
        }
    }

    @Test func theModelFileRunsAndOpensNothing() throws {
        let files = try Self.swiftFiles()
        let model = try #require(files.first(where: { $0.path == "DockGroupsCore/Model/LaunchAction.swift" }))
        for token in Self.executionTokens {
            #expect(!model.text.contains(token), "LaunchAction.swift mentions \(token)")
        }
    }
}
