import AppKit
import ImageIO
import Testing
@testable import DockGroupsCore

/// Records tool runs and answers them with a fixed status, instead of running codesign and
/// lsregister.
final class RecordingToolRunner: ToolRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(tool: URL, arguments: [String])] = []
    private let statuses: [String: Int32]

    /// - Parameter statuses: Exit status per first argument (e.g. `"--verify"`); 0 otherwise.
    init(statuses: [String: Int32] = [:]) {
        self.statuses = statuses
    }

    var calls: [(tool: URL, arguments: [String])] {
        lock.withLock { _calls }
    }

    func run(_ tool: URL, arguments: [String]) async throws -> ToolResult {
        lock.withLock { _calls.append((tool, arguments)) }
        return ToolResult(status: statuses[arguments.first ?? ""] ?? 0, output: "")
    }
}

@Suite("Agent bundle installer")
@MainActor
struct AgentInstallerTests {
    private func makeHost(in directory: TemporaryDirectory) throws -> AgentHost {
        let executable = directory.url.appending(path: "host-executable")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return AgentHost(executableURL: executable, version: "0.5.0", build: "1", minimumSystemVersion: "14.0", executableDigest: "d1")
    }

    private func input(for group: DockGroup, host: AgentHost) -> AgentInstaller.Input {
        AgentInstaller.Input(
            configuration: AgentConfiguration(group: group, preferences: PopupPreferences()),
            folderName: AgentIdentity.folderNames(for: [group])[group.id]!,
            host: host,
            // The installer copies the icon as it is; `AgentIconTests` cover drawing it.
            icns: Data("icns".utf8)
        )
    }

    @Test func installedBundleHasEverything() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let agents = temporary.url.appending(path: "Agents", directoryHint: .isDirectory)
        let tools = RecordingToolRunner()
        let installer = AgentInstaller(directory: agents, tools: tools, simulatesSigningFailure: false)
        let group = DockGroup(name: "Work Stuff", emoji: "💼", apps: [AppReference(bundleIdentifier: "com.apple.Safari", name: "Safari")], isStandalone: true)
        let host = try makeHost(in: temporary)

        let url = try await installer.install(input(for: group, host: host))

        #expect(url == agents.appending(path: "work-stuff.app", directoryHint: .isDirectory))
        let layout = AgentBundleLayout(bundleURL: url)
        let fileManager = FileManager.default
        #expect(fileManager.isExecutableFile(atPath: layout.executableURL.path))
        #expect(fileManager.contentsEqual(atPath: layout.executableURL.path, andPath: host.executableURL.path))
        #expect(try String(contentsOf: layout.pkgInfoURL, encoding: .utf8) == "APPL????")
        #expect(try AgentConfiguration.load(from: layout.configurationURL).group == group)
        #expect(fileManager.fileExists(atPath: layout.iconURL.path))
        #expect(fileManager.fileExists(atPath: layout.localizedStringsURL.path))

        let agent = InstalledAgent(bundleURL: url)
        #expect(agent.bundleIdentifier == AgentIdentity.bundleIdentifier(for: group.id))
        #expect(agent.groupID == group.id)
        #expect(agent.sourceDigest == "d1")
        let bundle = try #require(Bundle(url: url))
        #expect(bundle.bundleIdentifier == AgentIdentity.bundleIdentifier(for: group.id))
        #expect(bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true)

        // Signed ad hoc, then verified, before it was moved into place; no staging left over.
        let codesign = tools.calls.filter { $0.tool == SystemTools.codesign }.map(\.arguments)
        #expect(codesign.count == 2)
        #expect(codesign.first?.starts(with: ["--force", "--sign", "-"]) == true)
        #expect(codesign.last?.starts(with: ["--verify", "--strict"]) == true)
        #expect(codesign.allSatisfy { $0.last?.contains("/.staging-") == true })
        #expect(AgentDirectory.stagingLeftovers(in: agents).isEmpty)
        #expect(AgentDirectory.scan(agents).map(\.bundleURL.lastPathComponent) == ["work-stuff.app"])
    }

    @Test func reinstallingReplacesTheBundle() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let agents = temporary.url.appending(path: "Agents", directoryHint: .isDirectory)
        let installer = AgentInstaller(directory: agents, tools: RecordingToolRunner(), simulatesSigningFailure: false)
        var group = DockGroup(name: "Work", emoji: "💼", isStandalone: true)
        let host = try makeHost(in: temporary)
        try await installer.install(input(for: group, host: host))

        group.emoji = "🧪"
        let url = try await installer.install(input(for: group, host: host))

        #expect(InstalledAgent(bundleURL: url).configuration?.group.emoji == "🧪")
        #expect(AgentDirectory.scan(agents).count == 1)
        #expect(AgentDirectory.stagingLeftovers(in: agents).isEmpty)
    }

    @Test func failedSigningInstallsNothing() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let agents = temporary.url.appending(path: "Agents", directoryHint: .isDirectory)
        let group = DockGroup(name: "Work", isStandalone: true)
        let host = try makeHost(in: temporary)

        let failingSign = AgentInstaller(directory: agents, tools: RecordingToolRunner(statuses: ["--force": 1]), simulatesSigningFailure: false)
        await #expect(throws: AgentInstallError.signingFailed("")) {
            try await failingSign.install(input(for: group, host: host))
        }
        let failingVerify = AgentInstaller(directory: agents, tools: RecordingToolRunner(statuses: ["--verify": 3]), simulatesSigningFailure: false)
        await #expect(throws: AgentInstallError.verificationFailed("")) {
            try await failingVerify.install(input(for: group, host: host))
        }
        let simulated = AgentInstaller(directory: agents, tools: RecordingToolRunner(), simulatesSigningFailure: true)
        await #expect(throws: (any Error).self) {
            try await simulated.install(input(for: group, host: host))
        }

        #expect(AgentDirectory.scan(agents).isEmpty)
        #expect(AgentDirectory.stagingLeftovers(in: agents).isEmpty)
        #expect(AgentInstallError.signingFailed("").errorDescription?.contains("code-signed") == true)
    }

    @Test func missingHostExecutableIsReported() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let installer = AgentInstaller(directory: temporary.url, tools: RecordingToolRunner(), simulatesSigningFailure: false)
        let group = DockGroup(name: "Work", isStandalone: true)
        let host = AgentHost(executableURL: temporary.url.appending(path: "nope"), version: "1", build: "1", minimumSystemVersion: "14.0", executableDigest: "x")
        await #expect(throws: (any Error).self) {
            try await installer.install(input(for: group, host: host))
        }
        #expect(AgentDirectory.scan(temporary.url).isEmpty)
    }

    @Test func registeringAndRemoving() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let tools = RecordingToolRunner()
        let installer = AgentInstaller(directory: temporary.url, tools: tools, simulatesSigningFailure: false)
        let url = try await installer.install(input(for: DockGroup(name: "Work", isStandalone: true), host: makeHost(in: temporary)))

        try await installer.register(url)
        await installer.unregister(url)
        try installer.remove(url)

        let lsregister = tools.calls.filter { $0.tool == SystemTools.lsregister }.map(\.arguments)
        #expect(lsregister == [["-f", url.path], ["-u", url.path]])
        #expect(!FileManager.default.fileExists(atPath: url.path))

        let refusing = AgentInstaller(directory: temporary.url, tools: RecordingToolRunner(statuses: ["-f": 1]), simulatesSigningFailure: false)
        await #expect(throws: (any Error).self) { try await refusing.register(url) }
    }

    @Test func realCodesignSignsAndVerifiesTheBundle() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        // Any real executable will do; the bundle is signed, not run.
        let host = AgentHost(executableURL: URL(fileURLWithPath: "/usr/bin/true"), version: "1", build: "1", minimumSystemVersion: "14.0", executableDigest: "x")
        let installer = AgentInstaller(directory: temporary.url, tools: SystemToolRunner(), simulatesSigningFailure: false)
        let url = try await installer.install(input(for: DockGroup(name: "Signed", isStandalone: true), host: host))

        let result = try await SystemToolRunner().run(SystemTools.codesign, arguments: ["--verify", "--strict", "--verbose", url.path])
        #expect(result.succeeded, "\(result.output)")
    }

    @Test func scanSkipsEverythingButAppFolders() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let fileManager = FileManager.default
        for name in ["b.app", "a.app", ".staging-123", "notes.txt.app"] {
            try fileManager.createDirectory(at: temporary.url.appending(path: name), withIntermediateDirectories: true)
        }
        try fileManager.removeItem(at: temporary.url.appending(path: "notes.txt.app"))
        try Data().write(to: temporary.url.appending(path: "notes.txt.app"))
        try fileManager.createDirectory(at: temporary.url.appending(path: "folder"), withIntermediateDirectories: true)

        let agents = AgentDirectory.scan(temporary.url)
        #expect(agents.map(\.folderName) == ["a.app", "b.app"])
        #expect(agents.allSatisfy { $0.configuration == nil && $0.groupID == nil })
        #expect(AgentDirectory.stagingLeftovers(in: temporary.url).map(\.lastPathComponent) == [".staging-123"])
        #expect(AgentDirectory.scan(temporary.url.appending(path: "missing")).isEmpty)
    }
}

@Suite("Agent icon")
@MainActor
struct AgentIconTests {
    @Test func icnsHoldsEverySizeFrom16To1024Pixels() throws {
        let group = DockGroup(name: "Work", emoji: "💼")
        let data = try AgentIcon.icnsData(for: group, icons: [])

        #expect(data.prefix(4) == Data("icns".utf8))
        let declaredLength = data.subdata(in: 4..<8).reduce(0) { $0 << 8 | Int($1) }
        #expect(declaredLength == data.count)

        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let widths = Set((0..<CGImageSourceGetCount(source)).compactMap { CGImageSourceCreateImageAtIndex(source, $0, nil)?.width })
        #expect(widths.isSuperset(of: [16, 32, 64, 128, 256]))
        #expect(widths.contains(1024))
    }

    @Test func iconLeavesTheAppIconMargin() throws {
        let group = DockGroup(name: "Work", tile: TileAppearance(kind: .emoji, backgroundStyle: .solid, backgroundColor: TileColor(red: 200, green: 30, blue: 40)))
        let image = try #require(AgentIcon.image(for: group, pixelSize: 256, icons: []))
        #expect(image.width == 256 && image.height == 256)

        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var pixels = [UInt8](repeating: 0, count: 256 * 256 * 4)
        pixels.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 256 * 4,
                                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: 256, height: 256))
        }
        func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[(y * 256 + x) * 4 + 3] }
        // About 10 % margin, as in macOS app icons: transparent at 8 %, painted at 12 %.
        #expect(alpha(20, 128) == 0)
        #expect(alpha(31, 128) > 0)
    }

    @Test func iconChangesAreNoticed() {
        let group = DockGroup(name: "Work", emoji: "💼")
        var renamed = group
        renamed.name = "Office"
        var newEmoji = group
        newEmoji.emoji = "🚀"
        var recolored = group
        recolored.tile.backgroundColor = TileColor(red: 1, green: 2, blue: 3)
        #expect(!AgentIcon.differs(group, from: renamed))
        #expect(AgentIcon.differs(group, from: newEmoji))
        #expect(AgentIcon.differs(group, from: recolored))
    }

    @Test func dockIconCacheLivesInTheUserCacheFolder() throws {
        let cache = try #require(DockRestarter.iconCacheURL)
        #expect(cache.lastPathComponent == "com.apple.dock.iconcache")
        #expect(cache.path.contains("/var/folders/") && cache.deletingLastPathComponent().lastPathComponent == "C")
    }

    @Test func gridTilesUseTheAppIcons() throws {
        let apps = (0..<4).map { AppReference(bundleIdentifier: "com.example.app\($0)", name: "App \($0)") }
        let grid = DockGroup(name: "Grid", apps: apps, tile: TileAppearance(kind: .grid))
        let icon = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor.green.setFill()
            rect.fill()
            return true
        }
        let withIcons = try #require(AgentIcon.image(for: grid, pixelSize: 64, icons: Array(repeating: icon, count: 4)))
        let withoutIcons = try #require(AgentIcon.image(for: grid, pixelSize: 64, icons: []))
        #expect(withIcons.dataProvider?.data as Data? != withoutIcons.dataProvider?.data as Data?)
    }
}
