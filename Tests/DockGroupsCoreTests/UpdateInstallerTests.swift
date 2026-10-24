import Foundation
import Testing
@testable import DockGroupsCore

/// Stands in for hdiutil and ditto: "attaching" puts a copy of `diskImageApp` (and an Applications
/// link, like the real disk image) at the mount point, ditto copies with FileManager.
final class FakeDiskImageTools: ToolRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    private let diskImageApp: URL?

    init(diskImageApp: URL?) {
        self.diskImageApp = diskImageApp
    }

    var calls: [[String]] { lock.withLock { _calls } }

    func run(_ tool: URL, arguments: [String]) async throws -> ToolResult {
        lock.withLock { _calls.append([tool.lastPathComponent] + arguments) }
        let fileManager = FileManager.default
        switch (tool.lastPathComponent, arguments.first) {
        case ("hdiutil", "attach"):
            guard let index = arguments.firstIndex(of: "-mountpoint") else { return ToolResult(status: 1, output: "no mount point") }
            let mountPoint = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            try fileManager.createSymbolicLink(at: mountPoint.appending(path: "Applications"), withDestinationURL: URL(fileURLWithPath: "/Applications"))
            if let diskImageApp {
                try fileManager.copyItem(at: diskImageApp, to: mountPoint.appending(path: diskImageApp.lastPathComponent))
            }
            return ToolResult(status: 0, output: "")
        case ("hdiutil", "detach"):
            // Unmounting leaves the mount point empty.
            let mountPoint = URL(fileURLWithPath: arguments[1], isDirectory: true)
            for item in (try? fileManager.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)) ?? [] {
                try fileManager.removeItem(at: item)
            }
            return ToolResult(status: 0, output: "")
        case ("ditto", _):
            try fileManager.copyItem(at: URL(fileURLWithPath: arguments[0]), to: URL(fileURLWithPath: arguments[1]))
            return ToolResult(status: 0, output: "")
        default:
            return ToolResult(status: 1, output: "unexpected tool")
        }
    }
}

/// Runs tools through `base`, but tries a failed `hdiutil attach` again after each of `delays`: on a
/// busy CI machine attaching sometimes fails at first with "Resource temporarily unavailable". Other
/// tools and other failures pass straight through; once every retry failed, the last failure is
/// returned as it is. Only for the tests that use the real hdiutil.
struct DiskImageAttachRetryingRunner: ToolRunning {
    static let defaultDelays: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2)]

    let base: ToolRunning
    let delays: [Duration]
    let sleep: @Sendable (Duration) async -> Void

    init(
        base: ToolRunning = SystemToolRunner(),
        delays: [Duration] = DiskImageAttachRetryingRunner.defaultDelays,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.base = base
        self.delays = delays
        self.sleep = sleep
    }

    func run(_ tool: URL, arguments: [String]) async throws -> ToolResult {
        var result = try await base.run(tool, arguments: arguments)
        guard tool.lastPathComponent == "hdiutil", arguments.first == "attach" else { return result }
        for delay in delays where !result.succeeded {
            await sleep(delay)
            result = try await base.run(tool, arguments: arguments)
        }
        return result
    }
}

/// Fails `hdiutil attach` the first `failures` times, then succeeds; records every call.
final class FlakyAttachTools: ToolRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var remainingFailures: Int
    private var _calls: [[String]] = []

    init(failures: Int) {
        remainingFailures = failures
    }

    var calls: [[String]] { lock.withLock { _calls } }

    func run(_ tool: URL, arguments: [String]) async throws -> ToolResult {
        lock.withLock {
            _calls.append([tool.lastPathComponent] + arguments)
            guard remainingFailures > 0 else { return ToolResult(status: 0, output: "") }
            remainingFailures -= 1
            return ToolResult(status: 1, output: "hdiutil: attach failed - Resource temporarily unavailable")
        }
    }
}

/// Records the delays it was asked to wait, without waiting.
final class RecordedSleeps: @unchecked Sendable {
    private let lock = NSLock()
    private var _delays: [Duration] = []

    var delays: [Duration] { lock.withLock { _delays } }

    func sleep(_ delay: Duration) async {
        lock.withLock { _delays.append(delay) }
    }
}

@Suite("Disk image attach retries (test support)")
struct DiskImageAttachRetryTests {
    private let attach = ["attach", "-readonly", "-nobrowse", "/tmp/x.dmg"]

    @Test func transientFailuresAreRetriedUntilAttachSucceeds() async throws {
        let tools = FlakyAttachTools(failures: 2)
        let sleeps = RecordedSleeps()
        let runner = DiskImageAttachRetryingRunner(base: tools, sleep: sleeps.sleep)

        let result = try await runner.run(UpdateInstaller.hdiutil, arguments: attach)

        #expect(result.succeeded)
        #expect(tools.calls.count == 3)
        #expect(sleeps.delays == [.milliseconds(500), .seconds(1)])
    }

    @Test func persistentFailureIsReportedAfterThreeRetries() async throws {
        let tools = FlakyAttachTools(failures: 10)
        let sleeps = RecordedSleeps()
        let runner = DiskImageAttachRetryingRunner(base: tools, sleep: sleeps.sleep)

        let result = try await runner.run(UpdateInstaller.hdiutil, arguments: attach)

        #expect(!result.succeeded)
        #expect(result.output.contains("Resource temporarily unavailable"))
        #expect(tools.calls.count == 4)
        #expect(sleeps.delays == [.milliseconds(500), .seconds(1), .seconds(2)])
    }

    @Test func persistentFailureStillFailsStaging() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let sleeps = RecordedSleeps()
        let runner = DiskImageAttachRetryingRunner(base: FlakyAttachTools(failures: 10), sleep: sleeps.sleep)
        let installer = UpdateInstaller(directories: UpdateDirectories(root: temporary.url.appending(path: "updates")), tools: runner)

        await #expect(throws: UpdateInstallError.mountFailed("hdiutil: attach failed - Resource temporarily unavailable")) {
            try await installer.stageApp(fromDiskImage: temporary.url.appending(path: "update.dmg"), appName: "Any", expectedTeamIdentifier: nil)
        }
        #expect(sleeps.delays.count == 3)
    }

    @Test func otherToolsAndDetachAreNotRetried() async throws {
        let sleeps = RecordedSleeps()
        let tools = FlakyAttachTools(failures: 10)
        let runner = DiskImageAttachRetryingRunner(base: tools, sleep: sleeps.sleep)

        let detach = try await runner.run(UpdateInstaller.hdiutil, arguments: ["detach", "/tmp/mount"])
        let ditto = try await runner.run(UpdateInstaller.ditto, arguments: ["a", "b"])

        #expect(!detach.succeeded && !ditto.succeeded)
        #expect(tools.calls.count == 2)
        #expect(sleeps.delays.isEmpty)
    }
}

@Suite("Update installer")
struct UpdateInstallerTests {
    static let appName = "Cybokron Dock Groups"
    static let bundleIdentifier = "com.cybokron.dockgroups"

    /// A minimal app bundle with an executable, in `folder`.
    private func makeApp(in folder: URL, version: String, identifier: String = UpdateInstallerTests.bundleIdentifier) throws -> URL {
        let app = folder.appending(path: "\(Self.appName).app", directoryHint: .isDirectory)
        let macOS = app.appending(components: "Contents", "MacOS", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleShortVersionString": version,
            "CFBundleExecutable": Self.appName,
            "CFBundlePackageType": "APPL",
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: app.appending(components: "Contents", "Info.plist"))
        let executable = macOS.appending(path: Self.appName)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return app
    }

    /// Read from the Info.plist directly: `Bundle` caches bundles by path.
    private func version(ofAppAt url: URL) -> String? {
        guard let data = try? Data(contentsOf: url.appending(components: "Contents", "Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }

    private func folder(_ name: String, in temporary: TemporaryDirectory) throws -> URL {
        let url = temporary.url.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Replacing and rolling back

    @Test func replaceMovesTheOldAppToBackupsAndTheNewOneInPlace() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let installed = try makeApp(in: folder("Applications", in: temporary), version: "0.5.0")
        let staged = try makeApp(in: folder("staged", in: temporary), version: "0.6.0")
        let installer = UpdateInstaller(directories: UpdateDirectories(root: temporary.url.appending(path: "updates")))

        let backup = try installer.replace(installedApp: installed, with: staged, now: Date(timeIntervalSince1970: 0))

        #expect(version(ofAppAt: installed) == "0.6.0")
        #expect(version(ofAppAt: backup) == "0.5.0")
        #expect(backup.deletingLastPathComponent().standardizedFileURL == installer.directories.backups.standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test func failedReplaceRollsBackToTheOldApp() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let installed = try makeApp(in: folder("Applications", in: temporary), version: "0.5.0")
        let missing = temporary.url.appending(path: "staged/\(Self.appName).app", directoryHint: .isDirectory)
        let installer = UpdateInstaller(directories: UpdateDirectories(root: temporary.url.appending(path: "updates")))

        #expect(throws: UpdateInstallError.self) { try installer.replace(installedApp: installed, with: missing) }

        #expect(version(ofAppAt: installed) == "0.5.0")
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: installer.directories.backups.path)) ?? []
        #expect(backups.isEmpty)
    }

    @Test func installLocationProblemsAreReported() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let installed = try makeApp(in: folder("Applications", in: temporary), version: "0.5.0")

        #expect(UpdateInstaller.installLocationProblem(for: installed) == nil)
        #expect(UpdateInstaller.installLocationProblem(for: temporary.url.appending(path: "Nowhere.app")) != nil)
        let translocated = URL(fileURLWithPath: "/private/var/folders/xy/T/AppTranslocation/1234/d/\(Self.appName).app")
        #expect(UpdateInstaller.installLocationProblem(for: translocated)?.contains("Applications folder") == true)
    }

    // MARK: - Checking the download and the staged app

    @Test func stagedAppMustBeThisAppInTheReleasedVersion() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let expected = try #require(SemanticVersion("v0.6.0"))
        let good = try makeApp(in: folder("good", in: temporary), version: "0.6.0")
        let otherApp = try makeApp(in: folder("other", in: temporary), version: "0.6.0", identifier: "com.example.other")
        let oldVersion = try makeApp(in: folder("old", in: temporary), version: "0.5.0")
        let noExecutable = try makeApp(in: folder("broken", in: temporary), version: "0.6.0")
        try FileManager.default.removeItem(at: noExecutable.appending(components: "Contents", "MacOS", Self.appName))

        #expect(throws: Never.self) { try UpdateInstaller.validateStagedApp(good, bundleIdentifier: Self.bundleIdentifier, version: expected) }
        #expect(throws: UpdateInstallError.wrongApp("com.example.other")) {
            try UpdateInstaller.validateStagedApp(otherApp, bundleIdentifier: Self.bundleIdentifier, version: expected)
        }
        #expect(throws: UpdateInstallError.versionMismatch(expected: "0.6.0", found: "0.5.0")) {
            try UpdateInstaller.validateStagedApp(oldVersion, bundleIdentifier: Self.bundleIdentifier, version: expected)
        }
        #expect(throws: UpdateInstallError.appNotFound) {
            try UpdateInstaller.validateStagedApp(noExecutable, bundleIdentifier: Self.bundleIdentifier, version: expected)
        }
    }

    @Test func downloadIsCheckedAgainstSizeAndChecksum() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let file = temporary.url.appending(path: "update.dmg")
        try Data("disk image".utf8).write(to: file)
        let sha = try UpdateInstaller.sha256(ofFileAt: file)
        let url = URL(string: "https://example.com/update.dmg")!

        #expect(sha == "0bb2f0f3ed953c47d835a7adaefd95afa328e30a5c80fdce417dd12b014ad602")
        #expect(throws: Never.self) { try UpdateInstaller.verify(file, against: ReleaseAsset(name: "u", downloadURL: url, size: 10, digest: "sha256:\(sha)")) }
        #expect(throws: UpdateInstallError.sizeMismatch(expected: 11, actual: 10)) {
            try UpdateInstaller.verify(file, against: ReleaseAsset(name: "u", downloadURL: url, size: 11))
        }
        #expect(throws: UpdateInstallError.checksumMismatch) {
            try UpdateInstaller.verify(file, against: ReleaseAsset(name: "u", downloadURL: url, size: 10, digest: "sha256:\(String(repeating: "0", count: 64))"))
        }
    }

    @Test func downloadsOverHTTPSOnlyAndVerifiesTheFile() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let body = Data(repeating: 0x5A, count: 4096)
        let bodyFile = temporary.url.appending(path: "body")
        try body.write(to: bodyFile)
        let sha = try UpdateInstaller.sha256(ofFileAt: bodyFile)
        let url = StubURLProtocol.register(.init(body: body), fileName: "Cybokron-Dock-Groups-0.6.0-universal.dmg")
        let installer = UpdateInstaller(directories: UpdateDirectories(root: temporary.url.appending(path: "updates")))

        let downloaded = try await installer.download(
            ReleaseAsset(name: "../Cybokron-Dock-Groups-0.6.0-universal.dmg", downloadURL: url, size: body.count, digest: "sha256:\(sha)"),
            session: StubURLProtocol.makeSession()
        )

        #expect(downloaded.lastPathComponent == "Cybokron-Dock-Groups-0.6.0-universal.dmg")
        #expect(downloaded.deletingLastPathComponent().standardizedFileURL == installer.directories.downloads.standardizedFileURL)
        #expect(try Data(contentsOf: downloaded) == body)

        await #expect(throws: UpdateInstallError.insecureDownloadURL("http://example.com/x-universal.dmg")) {
            try await installer.download(ReleaseAsset(name: "x-universal.dmg", downloadURL: URL(string: "http://example.com/x-universal.dmg")!, size: 1))
        }
        #expect(UpdateInstaller.isAllowedDownloadURL(URL(string: "http://127.0.0.1:8765/x.dmg")!))
        #expect(!UpdateInstaller.isAllowedDownloadURL(URL(string: "file:///tmp/x.dmg")!))
    }

    // MARK: - Staging from the disk image

    @Test func stagingCopiesTheAppOutOfTheMountedImage() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let imageApp = try makeApp(in: folder("image", in: temporary), version: "0.6.0")
        let tools = FakeDiskImageTools(diskImageApp: imageApp)
        let installer = UpdateInstaller(directories: UpdateDirectories(root: temporary.url.appending(path: "updates")), tools: tools)

        let staged = try await installer.stageApp(fromDiskImage: temporary.url.appending(path: "update.dmg"), appName: Self.appName, expectedTeamIdentifier: nil)

        #expect(staged.lastPathComponent == "\(Self.appName).app")
        #expect(version(ofAppAt: staged) == "0.6.0")
        let attach = try #require(tools.calls.first)
        #expect(Array(attach.prefix(5)) == ["hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen"])
        #expect(tools.calls.contains { $0.starts(with: ["hdiutil", "detach"]) })
        // The mount point is gone once the image is detached.
        let mounts = (try? FileManager.default.contentsOfDirectory(atPath: installer.directories.mounts.path)) ?? []
        #expect(mounts.isEmpty)

        let empty = UpdateInstaller(directories: UpdateDirectories(root: temporary.url.appending(path: "updates2")), tools: FakeDiskImageTools(diskImageApp: nil))
        await #expect(throws: UpdateInstallError.appNotFound) {
            try await empty.stageApp(fromDiskImage: temporary.url.appending(path: "update.dmg"), appName: Self.appName, expectedTeamIdentifier: nil)
        }
    }

    @Test func realDiskImageIsMountedCopiedAndDetached() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let source = try folder("dmg-source", in: temporary)
        _ = try makeApp(in: source, version: "0.6.0")
        try FileManager.default.createSymbolicLink(at: source.appending(path: "Applications"), withDestinationURL: URL(fileURLWithPath: "/Applications"))
        let image = temporary.url.appending(path: "test-universal.dmg")
        let created = try await SystemToolRunner().run(UpdateInstaller.hdiutil, arguments: [
            "create", "-quiet", "-volname", "Cybokron Update Test", "-srcfolder", source.path, "-format", "UDZO", "-ov", image.path,
        ])
        try #require(created.succeeded, "hdiutil create: \(created.output)")
        // Attaching can fail transiently on a busy machine ("Resource temporarily unavailable").
        let installer = UpdateInstaller(
            directories: UpdateDirectories(root: temporary.url.appending(path: "updates")),
            tools: DiskImageAttachRetryingRunner()
        )

        let staged = try await installer.stageApp(fromDiskImage: image, appName: Self.appName, expectedTeamIdentifier: nil)

        #expect(version(ofAppAt: staged) == "0.6.0")
        #expect(throws: Never.self) {
            try UpdateInstaller.validateStagedApp(staged, bundleIdentifier: Self.bundleIdentifier, version: SemanticVersion(major: 0, minor: 6, patch: 0))
        }
        let mounts = (try? FileManager.default.contentsOfDirectory(atPath: installer.directories.mounts.path)) ?? []
        #expect(mounts.isEmpty)
    }

    // MARK: - Relaunch and cleanup

    @Test func relaunchScriptRefusesAnEmptyAppPath() async throws {
        // Without a path, `open` would show a Finder window; the script stops before waiting.
        let result = try await SystemToolRunner().run(UpdateInstaller.shell, arguments: ["-c", UpdateInstaller.relaunchScript, "cybokron-relaunch", "1", "", ""])
        #expect(result.status == 64)
    }

    @Test func relaunchPassesPathsAsArguments() {
        let app = URL(fileURLWithPath: "/Applications/\(Self.appName).app")
        let backup = URL(fileURLWithPath: "/tmp/it's \"odd\"/\(Self.appName).app")

        let arguments = UpdateInstaller.relaunchArguments(processID: 4242, appURL: app, backupURL: backup)

        #expect(arguments.count == 6)
        #expect(arguments[0] == "-c")
        #expect(Array(arguments[2...]) == ["cybokron-relaunch", "4242", app.path, backup.path])
        #expect(!UpdateInstaller.relaunchScript.contains(app.path))
        #expect(UpdateInstaller.relaunchArguments(processID: 1, appURL: app, backupURL: nil).last == "")
    }

    @Test func leftoversAreRemovedButTheNewestBackupIsKept() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let directories = UpdateDirectories(root: temporary.url.appending(path: "updates"))
        let fileManager = FileManager.default
        for folder in [directories.downloads, directories.staging, directories.mounts.appending(path: "stale"), directories.backups] {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data("dmg".utf8).write(to: directories.downloads.appending(path: "old.dmg"))
        let older = directories.backups.appending(path: "\(Self.appName) 20261001-000000.app")
        let newer = directories.backups.appending(path: "\(Self.appName) 20261017-000000.app")
        try fileManager.createDirectory(at: older, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: newer, withIntermediateDirectories: true)
        try fileManager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: older.path)
        try fileManager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: newer.path)

        UpdateInstaller(directories: directories).removeLeftovers(keepingBackups: 1)

        #expect(!fileManager.fileExists(atPath: directories.downloads.path))
        #expect(!fileManager.fileExists(atPath: directories.staging.path))
        #expect(!fileManager.fileExists(atPath: directories.mounts.path))
        #expect(fileManager.fileExists(atPath: newer.path))
        #expect(!fileManager.fileExists(atPath: older.path))
    }

    // MARK: - Remembered state and settings

    @Test func updateStateSurvivesARoundTrip() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let persistence = JSONFileUpdateStatePersistence(fileURL: temporary.url.appending(path: "update-state.json"))
        #expect(persistence.load() == UpdateState())

        let state = UpdateState(lastCheckDate: Date(timeIntervalSince1970: 1_800_000_000), skippedVersions: ["0.6.0"])
        try persistence.save(state)
        #expect(persistence.load() == state)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: persistence.fileURL)) as? [String: Any]
        #expect(object?["lastCheckDate"] as? Double == 1_800_000_000)

        try Data("not json".utf8).write(to: persistence.fileURL)
        #expect(persistence.load() == UpdateState())
    }

    @Test @MainActor func automaticChecksSettingIsSavedButNotGivenToAgents() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let persistence = JSONFilePreferencesPersistence(fileURL: temporary.url.appending(path: "preferences.json"))
        #expect(PopupPreferences().automaticallyChecksForUpdates)

        let store = PreferencesStore(persistence: persistence, saveDelay: .zero)
        store.update { $0.automaticallyChecksForUpdates = false }

        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: persistence.fileURL)) as? [String: Any]
        #expect(object?["automaticallyChecksForUpdates"] as? Bool == false)
        #expect(try persistence.loadPreferences()?.automaticallyChecksForUpdates == false)
        // Older files without the key keep checking.
        try Data(#"{"formatVersion": 1, "panelTheme": "light"}"#.utf8).write(to: persistence.fileURL)
        #expect(try persistence.loadPreferences()?.automaticallyChecksForUpdates == true)

        let group = DockGroup(name: "Work", isStandalone: true)
        #expect(AgentConfiguration(group: group, preferences: PopupPreferences(automaticallyChecksForUpdates: false))
            == AgentConfiguration(group: group, preferences: PopupPreferences()))
    }
}

/// Going back to a version without group items from Other Versions…: the groups file is copied
/// aside first (`groups.pre-downgrade-<timestamp>.json`, three kept), and the question warns only
/// when the groups hold files, folders or item details (`DowngradeProtection`).
@Suite("Update installer: copy of the groups before going back")
@MainActor
struct PreDowngradeCopyTests {
    private static func version(_ text: String) -> SemanticVersion { SemanticVersion(text)! }

    private static let report = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Documents/Q3 Report.pdf"), kind: .file)
    private static let mail = AppReference(bundleIdentifier: "com.apple.mail", name: "Mail")
    private static let github = AppReference(websiteURL: URL(string: "https://github.com")!)

    @Test func appliesOnlyGoingBackBeforeGroupItems() {
        #expect(ReleaseHistory.firstGroupItemsVersion == Self.version("0.6.8"))
        #expect(DowngradeProtection.applies(installing: Self.version("0.6.7"), over: Self.version("0.6.8")))
        #expect(DowngradeProtection.applies(installing: Self.version("0.6.5"), over: Self.version("0.7.0")))
        #expect(DowngradeProtection.applies(installing: Self.version("0.6.7"), over: nil))
        // Versions with group items, upgrades and reinstalls don't need it.
        #expect(!DowngradeProtection.applies(installing: Self.version("0.6.8"), over: Self.version("0.6.9")))
        #expect(!DowngradeProtection.applies(installing: Self.version("0.6.9"), over: Self.version("0.6.8")))
        #expect(!DowngradeProtection.applies(installing: Self.version("0.6.7"), over: Self.version("0.6.7")))
        #expect(!DowngradeProtection.applies(installing: Self.version("0.6.7"), over: Self.version("0.6.6")))
    }

    @Test func warnsOnlyAboutWhatThatVersionCantShow() {
        let appsAndWebsites = [DockGroup(name: "Work", apps: [Self.mail, Self.github])]
        var tagged = Self.mail
        tagged.details = ItemDetails(tags: ["mail"])
        let withFile = [DockGroup(name: "Finance", apps: [Self.mail, Self.report])]
        let withDetails = [DockGroup(name: "Work", apps: [tagged])]
        let folder = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Projects"), kind: .folder)
        let back = (target: Self.version("0.6.7"), current: Self.version("0.6.8"))

        #expect(!DowngradeProtection.usesGroupItems(appsAndWebsites))
        #expect(!DowngradeProtection.usesGroupItems([]))
        #expect(DowngradeProtection.usesGroupItems(withFile))
        #expect(DowngradeProtection.usesGroupItems(withDetails))
        #expect(DowngradeProtection.usesGroupItems([DockGroup(name: "Code", apps: [folder])]))

        #expect(!DowngradeProtection.warns(installing: back.target, over: back.current, groups: appsAndWebsites))
        #expect(DowngradeProtection.warns(installing: back.target, over: back.current, groups: withFile))
        #expect(!DowngradeProtection.warns(installing: Self.version("0.6.9"), over: back.current, groups: withFile))
    }

    /// The copy holds what's on screen (a pending change is written first), byte for byte the
    /// groups file, file items and all; at most three are kept.
    @Test func goingBackCopiesTheGroupsFileWithItsFileItems() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let fileURL = temporary.url.appending(path: "groups.json")
        let store = GroupStore(persistence: JSONFileGroupPersistence(fileURL: fileURL), saveDelay: .seconds(60))
        let group = store.addGroup(named: "Finance")
        #expect(store.addItems([Self.mail, Self.report], toGroup: group.id) == 2)

        let copy = try #require(try DowngradeProtection.preserveGroups(
            of: store,
            installing: Self.version("0.6.7"),
            over: Self.version("0.6.8")
        ))

        #expect(copy.deletingLastPathComponent().standardizedFileURL == temporary.url.standardizedFileURL)
        #expect(copy.lastPathComponent.hasPrefix("groups.pre-downgrade-"))
        #expect(copy.pathExtension == "json")
        #expect(try Data(contentsOf: copy) == Data(contentsOf: fileURL))
        let copied = try JSONFileGroupPersistence(fileURL: copy).loadGroups()
        #expect(copied.first?.apps.map(\.kind) == [.application, .file])
        #expect(copied.first?.apps.last?.bundleIdentifier == "file:///Users/me/Documents/Q3%20Report.pdf")

        for _ in 0..<3 {
            _ = try DowngradeProtection.preserveGroups(of: store, installing: Self.version("0.6.6"), over: Self.version("0.6.8"))
        }
        let copies = try FileManager.default.contentsOfDirectory(atPath: temporary.url.path).filter { $0.hasPrefix("groups.pre-downgrade-") }
        #expect(copies.count == JSONFileSupport.keptCopies)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func noCopyWhenNotGoingBackOrNothingIsSaved() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let fileURL = temporary.url.appending(path: "groups.json")
        let store = GroupStore(persistence: JSONFileGroupPersistence(fileURL: fileURL), saveDelay: .zero)

        // Nothing saved yet.
        #expect(try DowngradeProtection.preserveGroups(of: store, installing: Self.version("0.6.7"), over: Self.version("0.6.8")) == nil)

        store.addGroup(named: "Work")
        #expect(try DowngradeProtection.preserveGroups(of: store, installing: Self.version("0.6.9"), over: Self.version("0.6.8")) == nil)
        #expect(try DowngradeProtection.preserveGroups(of: store, installing: Self.version("0.6.8"), over: Self.version("0.6.9")) == nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: temporary.url.path)
        #expect(names == ["groups.json"])
    }
}

/// Going back to a version without Start and Finish from Other Versions…: the settings are copied
/// aside with the groups (`preferences.pre-downgrade-<timestamp>.json`), and the question warns only
/// when Start and Finish settings, launch options or protected apps are in use.
@Suite("Update installer: copies of the groups and settings before going back past switching")
@MainActor
struct PreDowngradeSwitchingTests {
    private static func version(_ text: String) -> SemanticVersion { SemanticVersion(text)! }

    private static let mail = AppReference(bundleIdentifier: "com.apple.mail", name: "Mail")
    private static let music = AppReference(bundleIdentifier: "com.apple.Music", name: "Music")
    private static let back = (target: version("0.7.0"), current: version("0.8.0"))

    private struct FailingPreferencesCopy: PreferencesPersisting {
        struct Failure: Error {}
        func loadPreferences() throws -> PopupPreferences? { nil }
        func savePreferences(_ preferences: PopupPreferences) throws {}
        func preserveUnreadableData() throws -> URL? { nil }
        func preserveCopy(label: String) throws -> URL? { throw Failure() }
    }

    @Test func firstVersionIsThisWave() {
        #expect(ReleaseHistory.firstContextSwitchingVersion == Self.version("0.8.0"))
        #expect(ReleaseHistory.lacksContextSwitching(Self.version("0.7.0")))
        #expect(!ReleaseHistory.lacksContextSwitching(Self.version("0.8.0")))
        #expect(DowngradeProtection.appliesToContextSwitching(installing: Self.back.target, over: Self.back.current))
        #expect(DowngradeProtection.appliesToContextSwitching(installing: Self.version("0.7.0"), over: nil))
        #expect(!DowngradeProtection.appliesToContextSwitching(installing: Self.version("0.8.0"), over: Self.version("0.8.1")))
        #expect(!DowngradeProtection.appliesToContextSwitching(installing: Self.version("0.9.0"), over: Self.version("0.8.0")))
        #expect(!DowngradeProtection.appliesToContextSwitching(installing: Self.version("0.7.0"), over: Self.version("0.6.9")))
    }

    @Test func warnsForEachNewSettingOnItsOwnAndOnlyThen() {
        var withLaunch = Self.mail
        withLaunch.launch = ItemLaunchOptions(delay: 3)
        let plain = [DockGroup(name: "Work", apps: [Self.mail])]
        let delayed = [DockGroup(name: "Work", apps: [withLaunch])]
        var switching = DockGroup(name: "Work", apps: [Self.mail])
        switching.switching = GroupSwitching(onStart: .quitPreviousGroup)
        let protected = PopupPreferences(protectedApps: ProtectedApps([Self.music]))
        let none = PopupPreferences()

        func warns(_ groups: [DockGroup], _ preferences: PopupPreferences, installing: String = "0.7.0", over: String = "0.8.0") -> Bool {
            DowngradeProtection.warnsAboutContextSwitching(
                installing: Self.version(installing), over: Self.version(over), groups: groups, preferences: preferences
            )
        }
        #expect(!warns(plain, none))
        #expect(!warns([], none))
        #expect(warns(delayed, none))
        #expect(warns([switching], none))
        #expect(warns(plain, protected))
        // Not going back past 0.8.0: no warning, whatever is used.
        #expect(!warns(delayed, protected, installing: "0.9.0", over: "0.8.0"))
        #expect(!warns(delayed, protected, installing: "0.8.0", over: "0.8.1"))
    }

    @Test func goingBackCopiesGroupsAndSettings() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let groupsURL = temporary.url.appending(path: "groups.json")
        let preferencesURL = temporary.url.appending(path: "preferences.json")
        let groups = GroupStore(persistence: JSONFileGroupPersistence(fileURL: groupsURL), saveDelay: .seconds(60))
        let preferences = PreferencesStore(persistence: JSONFilePreferencesPersistence(fileURL: preferencesURL), saveDelay: .seconds(60))
        let group = groups.addGroup(named: "Coding")
        groups.addItems([Self.mail], toGroup: group.id)
        preferences.update { $0.protectedApps = ProtectedApps([Self.music]) }

        let copies = try DowngradeProtection.preserveCopies(
            of: groups, and: preferences, installing: Self.back.target, over: Self.back.current
        )

        #expect(copies.count == 2)
        let names = copies.map(\.lastPathComponent)
        #expect(names.contains { $0.hasPrefix("groups.pre-downgrade-") && $0.hasSuffix(".json") })
        #expect(names.contains { $0.hasPrefix("preferences.pre-downgrade-") && $0.hasSuffix(".json") })
        let copiedPreferences = try #require(copies.first { $0.lastPathComponent.hasPrefix("preferences.") })
        #expect(try Data(contentsOf: copiedPreferences) == Data(contentsOf: preferencesURL))
        #expect(try JSONFilePreferencesPersistence(fileURL: copiedPreferences).loadPreferences()?.protectedApps.apps.map(\.bundleIdentifier) == ["com.apple.Music"])

        for _ in 0..<4 {
            try DowngradeProtection.preserveCopies(of: groups, and: preferences, installing: Self.back.target, over: Self.back.current)
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: temporary.url.path)
        #expect(files.filter { $0.hasPrefix("groups.pre-downgrade-") }.count == JSONFileSupport.keptCopies)
        #expect(files.filter { $0.hasPrefix("preferences.pre-downgrade-") }.count == JSONFileSupport.keptCopies)
        #expect(files.contains("groups.json") && files.contains("preferences.json"))
    }

    @Test func noCopiesWhenNotGoingBackPastSwitching() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let groups = GroupStore(persistence: JSONFileGroupPersistence(fileURL: temporary.url.appending(path: "groups.json")), saveDelay: .zero)
        let preferences = PreferencesStore(persistence: JSONFilePreferencesPersistence(fileURL: temporary.url.appending(path: "preferences.json")), saveDelay: .zero)
        groups.addGroup(named: "Work")
        preferences.update { $0.protectedApps = ProtectedApps([Self.music]) }

        #expect(try DowngradeProtection.preserveCopies(of: groups, and: preferences, installing: Self.version("0.9.0"), over: Self.version("0.8.0")).isEmpty)
        #expect(try DowngradeProtection.preserveCopies(of: groups, and: preferences, installing: Self.version("0.8.0"), over: Self.version("0.8.0")).isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: temporary.url.path).sorted()
        #expect(names == ["groups.json", "preferences.json"])
    }

    @Test func installIsBlockedWhenTheSettingsCantBeCopied() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let groups = GroupStore(persistence: JSONFileGroupPersistence(fileURL: temporary.url.appending(path: "groups.json")), saveDelay: .zero)
        groups.addGroup(named: "Work")
        let preferences = PreferencesStore(persistence: FailingPreferencesCopy(), saveDelay: .zero)

        #expect(throws: (any Error).self) {
            try DowngradeProtection.preserveCopies(of: groups, and: preferences, installing: Self.back.target, over: Self.back.current)
        }
    }
}

/// Going back to a version without group shortcuts, archived groups and templates: both files are
/// copied aside, and the question warns when any of them is in use.
@Suite("Update installer: copies of the groups before going back past group shortcuts")
@MainActor
struct PreDowngradeShortcutsTests {
    private static func version(_ text: String) -> SemanticVersion { SemanticVersion(text)! }
    private static let back = (target: version("0.8.0"), current: version("0.9.0"))
    private static let shortcut = GroupShortcut(keys: KeyCombination(keyCode: 8, modifiers: [.control, .option]))!

    private struct FailingPreferencesCopy: PreferencesPersisting {
        struct Failure: Error {}
        func loadPreferences() throws -> PopupPreferences? { nil }
        func savePreferences(_ preferences: PopupPreferences) throws {}
        func preserveUnreadableData() throws -> URL? { nil }
        func preserveCopy(label: String) throws -> URL? { throw Failure() }
    }

    @Test func firstVersionIsThisWave() {
        #expect(ReleaseHistory.firstGroupShortcutsVersion == Self.version("0.9.0"))
        #expect(ReleaseHistory.lacksGroupShortcuts(Self.version("0.8.0")))
        #expect(!ReleaseHistory.lacksGroupShortcuts(Self.version("0.9.0")))
        #expect(DowngradeProtection.appliesToGroupShortcuts(installing: Self.back.target, over: Self.back.current))
        #expect(DowngradeProtection.appliesToGroupShortcuts(installing: Self.back.target, over: nil))
        #expect(!DowngradeProtection.appliesToGroupShortcuts(installing: Self.version("0.9.0"), over: Self.version("0.9.1")))
        #expect(!DowngradeProtection.appliesToGroupShortcuts(installing: Self.version("0.8.0"), over: Self.version("0.7.0")))
    }

    @Test func warnsForEachKindOfDataOnItsOwnAndOnlyThen() {
        let plain = [DockGroup(name: "Work")]
        var shortcutGroup = DockGroup(name: "Work")
        shortcutGroup.shortcut = Self.shortcut

        func warns(_ groups: [DockGroup], archived: Int = 0, templates: Int = 0, installing: String = "0.8.0", over: String = "0.9.0") -> Bool {
            DowngradeProtection.warnsAboutGroupLibrary(
                installing: Self.version(installing), over: Self.version(over),
                groups: groups, archivedCount: archived, templateCount: templates
            )
        }
        #expect(!warns(plain))
        #expect(!warns([]))
        #expect(warns([shortcutGroup]))
        #expect(warns(plain, archived: 1))
        #expect(warns(plain, templates: 1))
        #expect(!warns([shortcutGroup], archived: 2, templates: 2, installing: "0.9.0", over: "0.9.1"))
        #expect(!warns([shortcutGroup], archived: 2, templates: 2, installing: "0.7.0", over: "0.6.0"))
    }

    @Test func goingBackFromNineCopiesGroupsAndPreferences() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let groupsURL = temporary.url.appending(path: "groups.json")
        let preferencesURL = temporary.url.appending(path: "preferences.json")
        let groups = GroupStore(persistence: JSONFileGroupPersistence(fileURL: groupsURL), saveDelay: .seconds(60))
        let preferences = PreferencesStore(persistence: JSONFilePreferencesPersistence(fileURL: preferencesURL), saveDelay: .seconds(60))
        let group = groups.addGroup(named: "Coding")
        _ = groups.setShortcut(Self.shortcut, forGroup: group.id)
        _ = groups.archiveGroup(groups.addGroup(named: "Old").id)
        preferences.update { $0.protectedApps = ProtectedApps([AppReference(bundleIdentifier: "com.apple.Music", name: "Music")]) }
        groups.flushPendingSave()
        preferences.flushPendingSave()

        let copies = try DowngradeProtection.preserveCopies(
            of: groups, and: preferences, installing: Self.back.target, over: Self.back.current
        )

        #expect(copies.count == 2)
        let copiedGroups = try #require(copies.first { $0.lastPathComponent.hasPrefix("groups.pre-downgrade-") })
        let copiedPreferences = try #require(copies.first { $0.lastPathComponent.hasPrefix("preferences.pre-downgrade-") })
        #expect(try Data(contentsOf: copiedGroups) == Data(contentsOf: groupsURL))
        #expect(try Data(contentsOf: copiedPreferences) == Data(contentsOf: preferencesURL))
        #expect(try String(contentsOf: copiedGroups, encoding: .utf8).contains("\"shortcut\""))
        #expect(try String(contentsOf: copiedGroups, encoding: .utf8).contains("\"archived\""))
    }

    @Test func noCopiesWhenNotGoingBackPastShortcuts() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let groups = GroupStore(persistence: JSONFileGroupPersistence(fileURL: temporary.url.appending(path: "groups.json")), saveDelay: .zero)
        let preferences = PreferencesStore(persistence: JSONFilePreferencesPersistence(fileURL: temporary.url.appending(path: "preferences.json")), saveDelay: .zero)
        groups.addGroup(named: "Work")
        preferences.update { $0.protectedApps = ProtectedApps([AppReference(bundleIdentifier: "com.apple.Music", name: "Music")]) }

        #expect(try DowngradeProtection.preserveCopies(of: groups, and: preferences, installing: Self.version("0.9.0"), over: Self.version("0.9.1")).isEmpty)
        #expect(try DowngradeProtection.preserveCopies(of: groups, and: preferences, installing: Self.version("0.9.1"), over: Self.version("0.9.1")).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.url.path).sorted() == ["groups.json", "preferences.json"])
    }

    @Test func installIsBlockedWhenTheCopyFails() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let groups = GroupStore(persistence: JSONFileGroupPersistence(fileURL: temporary.url.appending(path: "groups.json")), saveDelay: .zero)
        groups.addGroup(named: "Work")
        let preferences = PreferencesStore(persistence: FailingPreferencesCopy(), saveDelay: .zero)

        #expect(throws: (any Error).self) {
            try DowngradeProtection.preserveCopies(of: groups, and: preferences, installing: Self.back.target, over: Self.back.current)
        }
    }
}
