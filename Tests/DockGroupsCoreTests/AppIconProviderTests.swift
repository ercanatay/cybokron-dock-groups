import AppKit
import Testing
@testable import DockGroupsCore

@Suite("Group items: icons")
@MainActor
struct AppIconProviderTests {
    private static let report = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Q3 Report.pdf"), kind: .file)
    private static let projects = GroupItem(fileURL: URL(fileURLWithPath: "/Users/me/Projects"), kind: .folder)
    private static let mail = AppReference(bundleIdentifier: "com.apple.mail", name: "Mail")
    private static let github = AppReference(websiteURL: URL(string: "https://github.com")!)
    private static let reportLocation = URL(fileURLWithPath: "/Users/me/Q3 Report.pdf")

    /// A provider whose disk icons are fresh images, with the locations they were read for.
    @MainActor
    private final class Harness {
        let locator = ScriptedLocator()
        private(set) var iconReads: [String] = []
        lazy var provider = WorkspaceAppIconProvider(workspace: .shared, locator: locator) { [unowned self] url in
            iconReads.append(url.path)
            return NSImage(size: NSSize(width: 8, height: 8))
        }
    }

    @Test func aFoundItemsIconIsReadOnceAndRemembered() {
        let harness = Harness()
        let found = ItemPresence.available(Self.reportLocation)

        let first = harness.provider.icon(for: Self.report, presence: found)
        let second = harness.provider.icon(for: Self.report, presence: found)

        #expect(first === second)
        #expect(harness.iconReads == [Self.reportLocation.path])
        #expect(harness.provider.cachedIconCount == 1)
    }

    /// An item that isn't there gets the icon of its kind, without a look at the disk, and isn't
    /// remembered; one seen missing is forgotten, so a stale icon is never shown again.
    @Test func missingItemsAreNeverRememberedAndStaleIconsAreDropped() {
        let harness = Harness()
        let found = ItemPresence.available(Self.reportLocation)
        let remembered = harness.provider.icon(for: Self.report, presence: found)

        let missing = harness.provider.icon(for: Self.report, presence: .missing)
        #expect(missing !== remembered)
        #expect(harness.provider.cachedIconCount == 0)

        // Found again: read afresh.
        _ = harness.provider.icon(for: Self.report, presence: found)
        #expect(harness.iconReads.count == 2)

        _ = harness.provider.icon(for: Self.projects, presence: .volumeUnavailable(name: "Backup"))
        _ = harness.provider.icon(for: Self.projects, presence: .missing)
        #expect(harness.iconReads.count == 2)
        #expect(harness.provider.cachedIconCount == 1)
    }

    /// Not checked (privacy settings): an icon from before stays; none is read from the disk.
    @Test func anUncheckedItemKeepsItsIconButNoneIsRead() {
        let harness = Harness()
        let unchecked = harness.provider.icon(for: Self.report, presence: .unverified)
        #expect(harness.iconReads.isEmpty)
        #expect(harness.provider.cachedIconCount == 0)

        let found = harness.provider.icon(for: Self.report, presence: .available(Self.reportLocation))
        #expect(harness.provider.icon(for: Self.report, presence: .unverified) === found)
        #expect(found !== unchecked)
    }

    @Test func iconWithoutAPresenceChecksOnlyWhatIsntRemembered() {
        let harness = Harness()
        harness.locator.set(.available(Self.reportLocation), for: Self.report)

        _ = harness.provider.icon(for: Self.report)
        _ = harness.provider.icon(for: Self.report)
        #expect(harness.locator.presenceChecks.count == 1)
        #expect(harness.iconReads.count == 1)

        // Websites are never checked; a missing app gets the generic app icon.
        #expect(harness.provider.icon(for: Self.github) === WebsiteIcon.image)
        _ = harness.provider.icon(for: Self.mail)
        #expect(harness.locator.presenceChecks == [Self.report.bundleIdentifier, Self.mail.bundleIdentifier])
        #expect(harness.iconReads.count == 1)
    }

    @Test func installedMeansWorthOpening() {
        let harness = Harness()
        harness.locator.set(.unverified, for: Self.report)
        harness.locator.set(.volumeUnavailable(name: "Backup"), for: Self.projects)

        #expect(harness.provider.isInstalled(Self.report))
        #expect(!harness.provider.isInstalled(Self.projects))
        #expect(!harness.provider.isInstalled(Self.mail))
        #expect(harness.provider.isInstalled(Self.github))
    }

    @Test func genericIconsComeFromTheKindAndTheExtension() {
        let harness = Harness()
        let workspace = NSWorkspace.shared
        let provider = harness.provider
        #expect(provider.genericIcon(for: Self.mail).tiffRepresentation == workspace.icon(for: .applicationBundle).tiffRepresentation)
        #expect(provider.genericIcon(for: Self.projects).tiffRepresentation == workspace.icon(for: .folder).tiffRepresentation)
        #expect(provider.genericIcon(for: Self.report).tiffRepresentation == workspace.icon(for: .pdf).tiffRepresentation)
        #expect(harness.iconReads.isEmpty)
    }
}
