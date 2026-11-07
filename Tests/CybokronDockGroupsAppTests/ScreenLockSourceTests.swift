import CoreGraphics
import Foundation
import Testing
@testable import CybokronDockGroups
@testable import DockGroupsCore

/// The lock source's baseline (TS-11): the undocumented session key only decides what the next
/// notification is compared with; anything it can't read is unknown. No test posts the real
/// distributed notifications: they would reach every app on this Mac.
@MainActor
struct ScreenLockSourceTests {
    private let onConsole = kCGSessionOnConsoleKey as String

    @Test func theBaselineComesFromAConsoleSessionOnly() {
        #expect(ScreenLockSource.baseline(fromSession: [onConsole: true]) == false)
        #expect(ScreenLockSource.baseline(fromSession: [onConsole: true, "CGSSessionScreenIsLocked": true]) == true)
        #expect(ScreenLockSource.baseline(fromSession: [onConsole: NSNumber(value: 1), "CGSSessionScreenIsLocked": NSNumber(value: 1)]) == true)
        #expect(ScreenLockSource.baseline(fromSession: [onConsole: true, "CGSSessionScreenIsLocked": false]) == false)
        // Not on the console (another user's session is), or not told: unknown.
        #expect(ScreenLockSource.baseline(fromSession: [onConsole: false, "CGSSessionScreenIsLocked": true]) == nil)
        #expect(ScreenLockSource.baseline(fromSession: ["CGSSessionScreenIsLocked": true]) == nil)
        #expect(ScreenLockSource.baseline(fromSession: [:]) == nil)
        // A value it can't read is unknown, never "unlocked".
        #expect(ScreenLockSource.baseline(fromSession: [onConsole: true, "CGSSessionScreenIsLocked": "yes"]) == nil)
    }

    @Test func startingReadsABaselineAndStoppingForgetsIt() {
        var sent: [TriggerSignal] = []
        var reading: Bool? = false
        let source = ScreenLockSource(send: { sent.append($0) }, readBaseline: { reading })
        source.start()
        #expect(source.isRunning)
        #expect(sent == [.screenLock(locked: nil), .screenLock(locked: false)])
        // Started again while running: nothing new.
        source.start()
        #expect(sent.count == 2)
        source.stop()
        #expect(!source.isRunning)
        #expect(sent.last == .screenLock(locked: nil))
        source.stop()
        #expect(sent.count == 3)

        // A baseline that can't be read leaves the lock unknown.
        sent = []
        reading = nil
        source.start()
        #expect(sent == [.screenLock(locked: nil)])
        source.stop()
    }

    @Test func aLockSourceBaselineThenARealChangeFires() async {
        // Through the coordinator: the source's baseline, then the notifications' readings.
        let group = DockGroup(name: "Work")
        let unlock = GroupTrigger(groupID: group.id, event: .screenUnlocks, action: .openAll, runMode: .immediately)
        let coordinator = TriggerCoordinator(state: TriggerState(), rules: { [unlock] }, activeGroups: { [group.id] })
        coordinator.start()
        let source = ScreenLockSource(send: { coordinator.receive($0) }, readBaseline: { true })
        source.start()
        #expect(coordinator.environment.screenLocked == true)
        coordinator.receive(.screenLock(locked: false))
        #expect(coordinator.waitingFirings.isEmpty)
        #expect(!coordinator.isIdle)
        source.stop()
        #expect(coordinator.environment.screenLocked == nil)
    }
}
