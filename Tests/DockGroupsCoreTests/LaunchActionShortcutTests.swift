import Foundation
import Testing
@testable import DockGroupsCore

// The "Run a Shortcut" template, slice 1 (docs/design/launch-action-shortcut.md §3.1, §3.2, §5):
// the model, the name grammar, the strict decoder, the item rule and the approval digest. Nothing
// runs it yet: the launcher refuses it as a template without a runner. Every workspace is a fake.

@Suite("Launch actions: the shortcut template (model)")
@MainActor
struct LaunchActionShortcutTests {
    typealias T = LaunchActionTests

    nonisolated static let shortcuts = AppReference(bundleIdentifier: "com.apple.shortcuts", name: "Shortcuts")
    nonisolated static let workSetup = LaunchAction.shortcut(name: "Work Setup")

    nonisolated static func action(_ name: Any = "Work Setup") -> [String: Any] {
        ["template": "shortcut", "name": name]
    }

    nonisolated static func shortcutsItem(_ action: LaunchAction? = workSetup, identity: String = "com.apple.shortcuts") -> GroupItem {
        var item = AppReference(bundleIdentifier: identity, name: "Shortcuts")
        item.setLaunchAction(action)
        return item
    }

    // MARK: - Name grammar

    nonisolated static let refusedNames: [(String, ShortcutNameRejection)] = [
        ("", .empty),
        (String(repeating: "a", count: 129), .tooLong),
        (String(repeating: "é", count: 129), .tooLong),
        ("Wo\u{0}rk", .controlCharacter),
        ("Work\r", .controlCharacter),
        ("Work\nSetup", .controlCharacter),
        ("Work\tSetup", .controlCharacter),
        ("Work\u{7F}", .controlCharacter),
        ("Work\u{2028}Setup", .controlCharacter),
        ("Work\u{2029}Setup", .controlCharacter),
        ("\u{202E}puteS kroW", .bidiCharacter),
        ("Work\u{200F}", .bidiCharacter),
        ("Work\u{2066}Setup\u{2069}", .bidiCharacter),
        ("Work\u{200B}Setup", .invisibleCharacter),
        ("👩\u{200D}💻", .invisibleCharacter),
        ("\u{FEFF}Work", .invisibleCharacter),
        ("Work\u{00A0}Setup", .invisibleCharacter),
        ("Work\u{3000}Setup", .invisibleCharacter),
        ("Work\u{E000}", .invisibleCharacter),
        ("Caf\u{0065}\u{0301}", .notNormalized),
        ("A\u{030A}ngstr\u{006F}\u{0308}m", .notNormalized),
        (" Work", .surroundingWhitespace),
        ("Work ", .surroundingWhitespace),
        (" ", .surroundingWhitespace),
        ("-x", .leadingHyphen),
        ("--help", .leadingHyphen),
        ("a/b", .pathSeparator),
        ("/Work", .pathSeparator),
        ("a\\b", .pathSeparator),
    ]

    @Test(arguments: refusedNames)
    func refusedNamesAreRefusedForTheirFirstReason(_ name: String, _ reason: ShortcutNameRejection) {
        #expect(ShortcutName.rejection(for: name) == reason, "\(name.debugDescription)")
        #expect(LaunchAction.shortcut(name: name).rejection == .shortcutName(reason))
    }

    nonisolated static let acceptedNames = [
        "Work Setup", "A&B", "a+b", "x#y", "q?r", "50%", "Work: start", "a=b", "x;y", "~home", "..",
        "Çalışma Düzeni", "İş başı", "تشغيل العمل", "工作设置", "🚀", "❤️ Morning", "👍🏽",
        "Café", "Wo-rk", "a", String(repeating: "a", count: 128), String(repeating: "é", count: 128),
    ]

    @Test(arguments: acceptedNames)
    func acceptedNamesPass(_ name: String) {
        #expect(ShortcutName.rejection(for: name) == nil, "\(name.debugDescription)")
        #expect(LaunchAction.shortcut(name: name).rejection == nil)
    }

    @Test func theLengthIsCountedInScalars() {
        #expect(ShortcutName.maximumLength == 128)
        // 64 flags are 128 scalars; one more scalar is too many.
        let flags = String(repeating: "🇹🇷", count: 64)
        #expect(flags.unicodeScalars.count == 128 && ShortcutName.rejection(for: flags) == nil)
        #expect(ShortcutName.rejection(for: flags + "a") == .tooLong)
    }

    @Test func everyRejectionOfTheGrammarIsReachable() {
        #expect(Set(Self.refusedNames.map(\.1)) == Set(ShortcutNameRejection.allCases))
    }

    @Test func anNFDNameIsRefusedNotNormalized() throws {
        let nfd = "Caf\u{0065}\u{0301}"
        #expect(nfd == "Café", "Swift equality ignores the difference")
        let item = try T.decode(T.saved(Self.shortcuts, launchAction: Self.action(nfd)))
        #expect(item.launchActionSetting == .needsReview(.invalid(.shortcutName(.notNormalized))))
        #expect(item.launchAction == nil)
        // The NFC spelling is a different name and is accepted.
        let nfc = try T.decode(T.saved(Self.shortcuts, launchAction: Self.action("Caf\u{00E9}")))
        #expect(nfc.launchAction == .shortcut(name: "Caf\u{00E9}"))
    }

    // MARK: - On-disk form

    @Test func itIsWrittenWithItsNameOnly() throws {
        let item = Self.shortcutsItem()
        #expect(item.launchAction == Self.workSetup)
        let written = try #require(try T.object(item)["launchAction"] as? [String: String])
        #expect(written == ["status": "enabled", "template": "shortcut", "name": "Work Setup"])
    }

    @Test(arguments: acceptedNames)
    func itRoundTrips(_ name: String) throws {
        let item = Self.shortcutsItem(.shortcut(name: name))
        let read = try T.decode(JSONEncoder().encode(item))
        #expect(read == item)
        #expect(read.launchAction == .shortcut(name: name))
        let unicodeScalars = { (s: String) in Array(s.unicodeScalars) }
        if case .shortcut(let readName)? = read.launchAction {
            #expect(unicodeScalars(readName) == unicodeScalars(name), "byte for byte, never normalized")
        }
    }

    @Test func itIsReadFromTheFile() throws {
        for status: String? in [nil, "enabled"] {
            var object = Self.action()
            object["status"] = status
            let item = try T.decode(T.saved(Self.shortcuts, launchAction: object))
            #expect(item.launchActionSetting == .enabled(Self.workSetup))
            #expect(item.launchAction == Self.workSetup)
        }
    }

    @Test func anImportedOneStaysOff() throws {
        let item = try T.decode(T.saved(Self.shortcuts, launchAction: Self.action().merging(["status": "review", "reason": "imported"]) { $1 }))
        #expect(item.launchActionSetting == .needsReview(.imported(Self.workSetup)))
        #expect(item.launchAction == nil)
        let written = try #require(try T.object(item)["launchAction"] as? [String: String])
        #expect(written == ["status": "review", "reason": "imported", "template": "shortcut", "name": "Work Setup"])
        // A backup brings it in so as well.
        #expect(Self.shortcutsItem().launchActionSetting?.disabledForImport == .needsReview(.imported(Self.workSetup)))
    }

    nonisolated static let forbiddenKeys = ["input", "text", "url", "identifier", "x-success", "x-error", "x-cancel", "Input", "X-Success", "URL"]

    @Test(arguments: forbiddenKeys)
    func forbiddenKeysMakeItInvalidAndArentWritten(_ key: String) throws {
        var action = Self.action()
        action[key] = "cybokron-pwned://clipboard"
        try T.expectRefused(action, .forbiddenKey, item: Self.shortcuts)
        let written = String(decoding: try JSONEncoder().encode(T.decode(T.saved(Self.shortcuts, launchAction: action))), as: UTF8.self)
        #expect(!written.contains("cybokron-pwned"))
        #expect(!written.lowercased().contains("\"\(key.lowercased())\""))
        // Alone, or on a browser template, likewise.
        try T.expectRefused([key: "x"], .forbiddenKey, item: Self.shortcuts)
        try T.expectRefused(T.action().merging([key: "x"]) { $1 }, .forbiddenKey)
        #expect(LaunchActionCoding.isForbidden(key))
    }

    @Test func unknownAndOtherTemplatesKeysMakeItInvalid() throws {
        for key in ["browser", "profile", "shortcut", "Name", "callback", "x-source", "enabled", ""] {
            try T.expectRefused(Self.action().merging([key: "x"]) { $1 }, .unknownKey, item: Self.shortcuts)
        }
        // A browser template has no name.
        try T.expectRefused(T.action().merging(["name": "Work Setup"]) { $1 }, .unknownKey)
        try T.expectRefused(["template": "browserPrivate", "browser": "chrome", "name": "x"], .unknownKey)
    }

    @Test func badObjectsAreRefused() throws {
        try T.expectRefused(["template": "shortcut"], .missingName, item: Self.shortcuts)
        for value: Any in [NSNull(), 1, true, ["Work Setup"], ["name": "Work Setup"]] {
            try T.expectRefused(Self.action(value), .wrongValueType, item: Self.shortcuts)
        }
        for template in ["Shortcut", "shortcuts", "runShortcut", "run-shortcut", "x-callback-url"] {
            // Only the shortcut template has a name, so a misspelled one's name is an unknown key.
            try T.expectRefused(["template": template, "name": "Work Setup"], .unknownKey, item: Self.shortcuts)
            try T.expectRefused(["template": template], .unknownTemplate, item: Self.shortcuts)
        }
        try T.expectRefused(Self.action("a/b"), .shortcutName(.pathSeparator), item: Self.shortcuts)
        try T.expectRefused(Self.action("-x"), .shortcutName(.leadingHyphen), item: Self.shortcuts)
        try T.expectRefused(Self.action(""), .shortcutName(.empty), item: Self.shortcuts)
    }

    @Test func aRefusedNameIsNeverWritten() throws {
        var item = Self.shortcuts
        item.setLaunchAction(.shortcut(name: "--secret\u{0}"))
        #expect(item.launchActionSetting == .needsReview(.invalid(.shortcutName(.controlCharacter))))
        #expect(try T.object(item)["launchAction"] as? [String: String] == ["status": "review", "reason": "invalid"])
        item.launchActionSetting = .enabled(.shortcut(name: "a/secret"))
        #expect(item.launchAction == nil)
        #expect(!String(decoding: try JSONEncoder().encode(item), as: UTF8.self).contains("secret"))
        #expect(throws: EncodingError.self) {
            try JSONEncoder().encode(LaunchActionCoding(.shortcut(name: " x")))
        }
    }

    // MARK: - Which item carries it

    @Test func onlyTheShortcutsAppsItemTakesIt() throws {
        #expect(Self.workSetup.isAllowed(for: .application, identity: "com.apple.shortcuts"))
        #expect(Self.workSetup.isAllowed(for: .application, identity: "com.apple.Shortcuts"), "bundle identifiers ignore case")
        let others: [GroupItem] = [
            T.website, T.app, T.folder,
            GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Notes.txt"), kind: .file),
            AppReference(bundleIdentifier: "com.apple.mail", name: "Mail"),
            AppReference(bundleIdentifier: "com.apple.shortcuts.helper", name: "Shortcuts helper"),
            AppReference(bundleIdentifier: "/System/Applications/Shortcuts.app", name: "Shortcuts"),
        ]
        for item in others {
            #expect(!Self.workSetup.isAllowed(for: item.kind, identity: item.bundleIdentifier))
            try T.expectRefused(Self.action(), .unsupportedItemKind, item: item)
            var set = item
            set.setLaunchAction(Self.workSetup)
            #expect(set.launchActionSetting == .needsReview(.invalid(.unsupportedItemKind)))
            #expect(set.launchAction == nil)
            #expect(try T.object(set)["launchAction"] as? [String: String] == ["status": "review", "reason": "invalid"])
        }
        // Without the item's identity it's never allowed; the browser templates are as before.
        for kind in AppReference.Kind.allCases {
            #expect(!Self.workSetup.isAllowed(for: kind))
        }
        #expect(LaunchAction.browserPrivate(browser: .chrome).isAllowed(for: .website, identity: "https://example.com/"))
        #expect(!LaunchAction.browserProfile(browser: .chrome, profileName: "Work").isAllowed(for: .application, identity: "com.apple.shortcuts"))
    }

    @Test func aBrowserTemplateOnTheShortcutsItemIsRefused() throws {
        try T.expectRefused(T.action(), .unsupportedItemKind, item: Self.shortcuts)
        try T.expectRefused(["template": "browserPrivate", "browser": "chrome"], .unsupportedItemKind, item: Self.shortcuts)
    }

    @Test func changingTheItemsIdentityTurnsItOff() throws {
        var item = Self.shortcutsItem()
        item.bundleIdentifier = "com.example.fake-shortcuts"
        #expect(item.launchAction == nil)
        #expect(item.launchActionStatus == .invalid)
        #expect(try T.object(item)["launchAction"] as? [String: String] == ["status": "review", "reason": "invalid"])
    }

    // MARK: - Approval digest

    @Test func theCanonicalTextBindsTheName() throws {
        let text = try #require(LaunchActionApprovalDigest.canonical(for: Self.shortcutsItem()))
        #expect(text == """
        cybokron-dock-groups/launch-action-approval/1
        item=19:com.apple.shortcuts
        kind=11:application
        url=0:
        template=8:shortcut
        shortcut=10:Work Setup
        opener=0:

        """)
        let digest = try #require(LaunchActionApprovalDigest.digest(for: Self.shortcutsItem()))
        #expect(LaunchActionApprovalDigest.isWellFormed(digest))
        #expect(digest == LaunchActionApprovalDigest.digest(for: Self.shortcutsItem()))
        // The length counts UTF-8 bytes.
        let turkish = try #require(LaunchActionApprovalDigest.canonical(for: Self.shortcutsItem(.shortcut(name: "İş"))))
        #expect(turkish.contains("\nshortcut=4:İş\n"))
    }

    @Test func everyFieldChangesTheDigest() throws {
        let base = try #require(LaunchActionApprovalDigest.digest(for: Self.shortcutsItem()))
        let changed = [
            Self.shortcutsItem(.shortcut(name: "Work setup")),
            Self.shortcutsItem(.shortcut(name: "Work Setup 2")),
            Self.shortcutsItem(.shortcut(name: "Caf\u{00E9}")),
        ]
        var digests: Set<String> = [base]
        for item in changed {
            let digest = try #require(LaunchActionApprovalDigest.digest(for: item))
            #expect(digest != base)
            digests.insert(digest)
        }
        #expect(digests.count == changed.count + 1)
        // No action that's on, no digest.
        #expect(LaunchActionApprovalDigest.digest(for: Self.shortcutsItem(nil)) == nil)
        #expect(LaunchActionApprovalDigest.digest(for: Self.shortcutsItem(identity: "com.apple.mail")) == nil)
        // A browser profile named like the shortcut never has its digest.
        #expect(LaunchActionApprovalDigest.digest(for: LaunchActionFixtures.website(profile: "Work Setup")) != base)
    }

    @Test func renamingTheShortcutNeedsANewApproval() throws {
        let approvals = LaunchActionApprovalStore.inMemory()
        let item = Self.shortcutsItem()
        try approvals.approve(item)
        #expect(approvals.check(item) == .approved)
        var renamed = item
        renamed.setLaunchAction(.shortcut(name: "Work Setup (old)"))
        #expect(approvals.check(renamed) == .mismatch)
        #expect(approvals.check(Self.shortcutsItem(.shortcut(name: "Café"))) == .mismatch)
        // Another Mac (an empty approval file) has none.
        #expect(LaunchActionApprovalStore.inMemory().check(item) == .missing)
    }

    @Test func anImportedOneHasNoApproval() throws {
        let approvals = LaunchActionApprovalStore.inMemory()
        var item = Self.shortcutsItem()
        try approvals.approve(item)
        item.launchActionSetting = item.launchActionSetting?.disabledForImport
        #expect(item.launchAction == nil)
        #expect(LaunchActionApprovalDigest.digest(for: item) == nil)
    }

    // MARK: - Nothing runs it yet

    @Test func theLauncherRefusesItAsATemplateWithoutARunner() async throws {
        let item = Self.shortcutsItem()
        let workspace = LaunchActionFakeWorkspace(installed: ["com.apple.shortcuts"])
        let launcher = GroupLauncher(workspace: workspace, approvals: LaunchActionFixtures.approving(item))
        let group = DockGroup(name: "Work", apps: [item])
        let one = await launcher.open(item, inGroup: group, source: .userAction)
        let all = await launcher.openAll(group, source: .userAction)
        for report in [one, all] {
            #expect(report.entries == [LaunchReport.Entry(app: item, outcome: .failed(reason: LaunchActionFixtures.notOpened), launchActionRefusal: .templateNotSupported)])
        }
        #expect(!workspace.openedAnything, "Shortcuts isn't even brought forward")
        #expect(workspace.runningQueries.isEmpty)
        #expect(LaunchActionItemRefusal.templateNotSupported.code == "template.notSupported")
    }

    @Test func anUnattendedSourceIsStillRefusedFirst() async {
        let item = Self.shortcutsItem()
        for source in LaunchActionFixtures.unattendedSources {
            let workspace = LaunchActionFakeWorkspace(installed: ["com.apple.shortcuts"])
            let report = await GroupLauncher(workspace: workspace, approvals: LaunchActionFixtures.approving(item))
                .open(item, inGroup: DockGroup(name: "Work", apps: [item]), source: source)
            #expect(report.entries.map(\.launchActionRefusal) == [.unattendedSource(source)])
            #expect(!workspace.openedAnything)
        }
    }

    @Test func noPlanIsEverMadeForIt() {
        let plan = LaunchActionArgumentPlan.make(
            setting: .enabled(Self.workSetup), itemKind: .application, url: LaunchActionFixtures.url,
            browserBundleIdentifier: "com.apple.shortcuts", isInstalled: { _ in true }
        )
        #expect(plan == .failure(.itemKindMismatch))
        #expect(Self.workSetup.preferredBrowserBundleIdentifier == nil)
        #expect(!Self.workSetup.hasRunner)
        #expect(Self.workSetup.browser == nil && Self.workSetup.profileName == nil && Self.workSetup.shortcutName == "Work Setup")
        #expect(Self.shortcutsItem().launchActionBrowserBundleIdentifier == nil)
        #expect(LaunchActionSummary(Self.workSetup, for: Self.shortcutsItem())?.shortcutName == "Work Setup")
    }
}
