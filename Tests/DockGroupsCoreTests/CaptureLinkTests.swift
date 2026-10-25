import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Capture: links")
struct CaptureLinkTests {
    private func command(_ string: String) -> URLCommand? {
        URL(string: string).flatMap(URLCommand.init(url:))
    }

    @Test func captureLinksAreParsed() {
        #expect(command("cybokrondockgroups://capture") == .captureNewGroup)
        #expect(command("cybokrondockgroups://capture/") == .captureNewGroup)
        #expect(command("CybokronDockGroups://CAPTURE") == .captureNewGroup)
        #expect(command("cybokrondockgroups:capture") == .captureNewGroup)
        #expect(command("cybokrondockgroups://capture?x=1") == .captureNewGroup)
        #expect(command("cybokrondockgroups://capture/work") == .captureOpenApps("work"))
        #expect(command("cybokrondockgroups://capture/Deep%20Work") == .captureOpenApps("Deep Work"))
        #expect(command("cybokrondockgroups://capture/a/b") == .captureOpenApps("a/b"))
        #expect(command("cybokrondockgroups://capture/Dev%2FOps") == .captureOpenApps("Dev/Ops"))
        #expect(command("cybokrondockgroups://capture/work?mode=force") == .captureOpenApps("work"))
        #expect(LinkCommand(url: URL(string: "cybokrondockgroups://capture/work")!) == .command(.captureOpenApps("work")))
    }

    /// The links only show a sheet: they're limited per link, like `groups` and `settings`, not
    /// with the links that open or hide a group's apps.
    @Test func captureLinksAreGatedPerLinkOnly() {
        #expect(URLCommand.captureNewGroup.groupActionKey == nil)
        #expect(URLCommand.captureOpenApps("work").groupActionKey == nil)
        #expect(URLCommand.captureNewGroup.throttleKey == "capture")
        #expect(URLCommand.captureOpenApps("Deep Work").throttleKey == URLCommand.captureOpenApps("deep-work").throttleKey)
        #expect(URLCommand.captureOpenApps("work").throttleKey != URLCommand.captureNewGroup.throttleKey)
        #expect(URLCommand.captureOpenApps("work").throttleKey != URLCommand.showGroup("work").throttleKey)

        var gate = URLCommandGate()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(gate.accept(URLCommand.captureNewGroup, at: now) == .accepted)
        #expect(gate.accept(URLCommand.captureNewGroup, at: now.addingTimeInterval(1)) == .repeated)
        // A capture link doesn't take the group-apps cooldown away from Open All…
        #expect(gate.accept(URLCommand.launchGroup("work"), at: now.addingTimeInterval(1)) == .accepted)
        // …nor does Open All's cooldown hold capture links back.
        #expect(gate.accept(URLCommand.captureOpenApps("work"), at: now.addingTimeInterval(2)) == .accepted)
        #expect(gate.accept(URLCommand.captureNewGroup, at: now.addingTimeInterval(6)) == .accepted)
    }

    @Test func theAddOpenAppsLinkNamesTheGroupAsTheOtherLinksDo() throws {
        let work = DockGroup(name: "Deep Work")
        let games = DockGroup(name: "🎮")
        let groups = [work, games]

        let link = GroupInvocations.captureLink(for: work, in: groups)
        #expect(link.title == "Add Open Apps")
        #expect(link.text == "cybokrondockgroups://capture/deep-work")
        #expect(GroupInvocations.captureLink(for: games, in: groups).text == "cybokrondockgroups://capture/\(games.id.uuidString)")

        // The link finds its group again.
        let parsed = try #require(URL(string: link.text).flatMap(URLCommand.init(url:)))
        guard case .captureOpenApps(let token) = parsed else {
            Issue.record("Expected captureOpenApps, got \(parsed)")
            return
        }
        #expect(GroupLookup.group(matching: token, in: groups)?.id == work.id)
    }
}

/// Capturing needs no permission (spec CP-6, §2.3): its code never touches the Accessibility API,
/// Screen Recording, window names or Apple Events, and never asks for access.
@Suite("Capture: no permission")
struct CapturePermissionTests {
    private static let captureSources = [
        "Sources/DockGroupsCore/Capture/OpenApps.swift",
        "Sources/DockGroupsCore/Capture/ActivationHistory.swift",
        "Sources/DockGroupsCore/Capture/CapturePlanner.swift",
        "Sources/DockGroupsCore/Model/CaptureSettings.swift",
        "Sources/DockGroupsCore/Model/AppItemPolicy.swift",
    ]

    private static let forbidden = [
        // Accessibility
        "AXIsProcessTrusted", "AXUIElement", "kAXTrustedCheckOptionPrompt", "ApplicationServices",
        // Screen Recording, window names and pictures
        "kCGWindowName", "CGRequestScreenCaptureAccess", "CGPreflightScreenCaptureAccess",
        "CGWindowListCreateImage", "ScreenCaptureKit", "SCShareableContent",
        // Automation
        "NSAppleScript", "NSAppleEventDescriptor", "AEDeterminePermissionToAutomateTarget", "OSAScript",
        // Input Monitoring
        "CGEventTapCreate", "addGlobalMonitorForEvents", "IOHIDRequestAccess",
    ]

    @Test func captureCodeUsesNoPermissionAPI() throws {
        for path in Self.captureSources {
            let text = try String(contentsOf: LocalizationTests.root.appending(path: path), encoding: .utf8)
            for name in Self.forbidden {
                #expect(!text.contains(name), "\(path) uses \(name)")
            }
        }
    }

    /// The system reader asks the window server for its list and NSWorkspace for the running apps,
    /// nothing else.
    @Test func theReaderReadsTheWindowListAndTheRunningAppsOnly() throws {
        let text = try String(contentsOf: LocalizationTests.root.appending(path: "Sources/DockGroupsCore/Capture/OpenApps.swift"), encoding: .utf8)
        #expect(text.components(separatedBy: "CGWindowListCopyWindowInfo(").count - 1 == 2)
        #expect(text.contains("workspace.runningApplications"))
        let readKeys = try NSRegularExpression(pattern: #"kCGWindow[A-Za-z]+ as String"#)
        let range = NSRange(text.startIndex..., in: text)
        let used = Set(readKeys.matches(in: text, range: range).map { String(text[Range($0.range, in: text)!]) })
        #expect(used == ["kCGWindowOwnerPID as String", "kCGWindowLayer as String", "kCGWindowAlpha as String", "kCGWindowBounds as String", "kCGWindowIsOnscreen as String"])
    }
}
