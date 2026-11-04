import Darwin
import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Experimental process-event watch", .serialized)
struct ExperimentalProcessEventWatchTests {
    @Test func malformedOrFailedPollPermanentlyInvalidatesWatch() throws {
        let pid = getpid()
        var valid = kevent()
        valid.ident = UInt(pid)
        valid.filter = Int16(EVFILT_PROC)
        valid.fflags = UInt32(NOTE_EXEC)
        var wrongPID = valid
        wrongPID.ident = UInt(pid) + 1
        var wrongFilter = valid
        wrongFilter.filter = Int16(EVFILT_READ)
        var errorFlag = valid
        errorFlag.flags = UInt16(EV_ERROR)
        var unsupportedEventFlag = valid
        unsupportedEventFlag.flags = UInt16(EV_DELETE)
        var unknownFlags = valid
        unknownFlags.fflags = 1
        var missingFlags = valid
        missingFlags.fflags = 0
        for (count, event) in [(-1, valid), (2, valid), (1, wrongPID), (1, wrongFilter), (1, errorFlag), (1, unsupportedEventFlag), (1, unknownFlags), (1, missingFlags)] {
            let watch = try #require(ExperimentalProcessEventWatch(pid: pid))
            #expect(watch.consumePollResult(count: Int32(count), event: event) == .unknown)
            #expect(watch.poll() == .unknown)
        }
    }

    @Test func combinedExecExitNotificationIsTerminal() throws {
        let pid = getpid()
        let watch = try #require(ExperimentalProcessEventWatch(pid: pid))
        var event = kevent()
        event.ident = UInt(pid)
        event.filter = Int16(EVFILT_PROC)
        event.fflags = UInt32(NOTE_EXEC) | UInt32(NOTE_EXIT)
        #expect(watch.consumePollResult(count: 1, event: event) == .execAndExit)
        #expect(watch.poll() == .unknown)
    }

    @Test func rejectsInvalidPIDAndClosedWatchIsUnknown() throws {
        #expect(ExperimentalProcessEventWatch(pid: 0) == nil)
        #expect(ExperimentalProcessEventWatch(pid: -1) == nil)
        let watch = try #require(ExperimentalProcessEventWatch(pid: getpid()))
        #expect(watch.poll() == .idle)
        watch.close()
        watch.close()
        #expect(watch.poll() == .unknown)
        #expect(watch.consumePollResult(count: 0, event: kevent()) == .unknown)
    }

    @Test func cannotWatchAnAlreadyReapedChild() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        let pid = child.processIdentifier
        await child.waitForExit()
        #expect(child.terminationStatus == 0)
        #expect(ExperimentalProcessEventWatch(pid: pid) == nil)
    }

    @Test func reportsExitOfOwnedChild() async throws {
        try await withChildProcesses { children in
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/sleep")
            child.arguments = ["10"]
            try child.run()
            children.adopt(child)
            let watch = try #require(ExperimentalProcessEventWatch(pid: child.processIdentifier))
            #expect(watch.poll() == .idle)
            child.terminate()
            #expect(await Self.firstEvent(of: watch) == .exit)
            #expect(watch.poll() == .unknown)
        }
    }

    @Test func reportsExecOfOwnedChild() async throws {
        let input = Pipe()
        defer { try? input.fileHandleForWriting.close() }
        try await withChildProcesses { children in
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/sh")
            child.standardInput = input
            try child.run()
            children.adopt(child)
            let watch = try #require(ExperimentalProcessEventWatch(pid: child.processIdentifier))
            #expect(watch.poll() == .idle)
            try input.fileHandleForWriting.write(contentsOf: Data("exec /bin/sleep 10\n".utf8))
            #expect(await Self.firstEvent(of: watch) == .exec)
            #expect(watch.poll() == .unknown)
        }
    }

    /// Polls `watch` every 10 ms, sleeping in between without holding a thread, until it reports
    /// something other than `.idle` or 3 s have passed.
    private static func firstEvent(of watch: ExperimentalProcessEventWatch) async -> ExperimentalProcessEventWatch.PollResult {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(3)
        var result: ExperimentalProcessEventWatch.PollResult = .idle
        while result == .idle && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
            result = watch.poll()
        }
        return result
    }
}
