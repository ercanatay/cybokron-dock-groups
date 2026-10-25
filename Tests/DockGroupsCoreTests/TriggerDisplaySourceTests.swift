import Foundation
import Testing

/// The display source as the app's sources write it (triggers spec §1.4, §5, TS-6): the app target
/// isn't linked into the tests.
@Suite("Triggers: the display source")
struct TriggerDisplaySourceTests {
    static func source() throws -> String {
        try TriggerAppSourceTests.source("CybokronDockGroups", "Triggers", "DisplaySource.swift")
    }

    @Test func displaysSettleBeforeTheyreRead() throws {
        let text = try Self.source()
        #expect(text.contains("static let settle: Duration = .seconds(2)"))
        #expect(text.contains("static let wakeSettle: Duration = .seconds(5)"))
        #expect(text.contains("NSApplication.didChangeScreenParametersNotification"))
        // Notifications only: no timer, no polling.
        for polling in ["Timer(", "scheduledTimer", "repeats:", "DispatchSource"] {
            #expect(!text.contains(polling), "the display source uses \(polling)")
        }
    }

    /// Nothing is read while the screens or the Mac sleep, and the first reading after a wake waits
    /// for the wake to settle, so monitors that leave the list while asleep make no edge.
    @Test func nothingIsReadWhileTheScreensSleep() throws {
        let text = try Self.source()
        #expect(text.contains("for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification]"))
        #expect(text.contains("for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification]"))
        #expect(text.contains("guard let self, !Task.isCancelled, !self.isAsleep else { return }"))
        #expect(text.contains("notBefore = .now + Self.wakeSettle"))
    }

    /// The identity is what CoreGraphics and NSScreen report without a permission (spec §2.3).
    @Test func identitiesNeedNoPermission() throws {
        let text = try Self.source()
        for call in ["CGDisplayVendorNumber(id)", "CGDisplayModelNumber(id)", "CGDisplaySerialNumber(id)", "CGDisplayIsBuiltin(id)", "screen.localizedName"] {
            #expect(text.contains(call))
        }
        for gated in ["CGDisplayStream", "CGWindowListCreateImage", "SCShareableContent", "IOServiceGetMatchingService"] {
            #expect(!text.contains(gated))
        }
        #expect(text.contains("return displays.isEmpty ? nil : displays"), "no display read is unknown, not \"all disconnected\"")
    }

    @Test func theControllerStartsTheSourceOnlyWhenNeeded() throws {
        let controller = try TriggerAppSourceTests.source("CybokronDockGroups", "Triggers", "TriggerController.swift")
        #expect(controller.contains("if needs.contains(.displays) { displaySource.start() } else { displaySource.stop() }"))
        #expect(controller.components(separatedBy: "updateSources()").count >= 4, "after launch, rule changes and group changes")
    }
}
