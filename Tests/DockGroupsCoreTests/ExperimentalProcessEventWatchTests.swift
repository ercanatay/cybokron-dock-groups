import Darwin
import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Experimental process-event watch", .serialized)
struct ExperimentalProcessEventWatchTests {
    @Test func rejectsInvalidPIDAndClosedWatchIsUnknown() throws {
        #expect(ExperimentalProcessEventWatch(pid: 0) == nil)
        #expect(ExperimentalProcessEventWatch(pid: -1) == nil)
        let watch = try #require(ExperimentalProcessEventWatch(pid: getpid()))
        #expect(watch.poll() == .idle)
        watch.close()
        watch.close()
        #expect(watch.poll() == .unknown)
    }

    @Test func cannotWatchAnAlreadyReapedChild() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        let pid = child.processIdentifier
        child.waitUntilExit()
        #expect(child.terminationStatus == 0)
        #expect(ExperimentalProcessEventWatch(pid: pid) == nil)
    }

    @Test func reportsExitOfOwnedChild() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["10"]
        try child.run()
        defer {
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }
        let watch = try #require(ExperimentalProcessEventWatch(pid: child.processIdentifier))
        #expect(watch.poll() == .idle)
        child.terminate()
        let deadline = Date().addingTimeInterval(3)
        var result: ExperimentalProcessEventWatch.PollResult = .idle
        while result == .idle && Date() < deadline {
            usleep(10_000)
            result = watch.poll()
        }
        #expect(result == .exit)
        #expect(watch.poll() == .unknown)
    }

    @Test func reportsExecOfOwnedChild() throws {
        let child = Process()
        let input = Pipe()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.standardInput = input
        try child.run()
        defer {
            try? input.fileHandleForWriting.close()
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }
        let watch = try #require(ExperimentalProcessEventWatch(pid: child.processIdentifier))
        #expect(watch.poll() == .idle)
        try input.fileHandleForWriting.write(contentsOf: Data("exec /bin/sleep 10\n".utf8))
        let deadline = Date().addingTimeInterval(3)
        var result: ExperimentalProcessEventWatch.PollResult = .idle
        while result == .idle && Date() < deadline {
            usleep(10_000)
            result = watch.poll()
        }
        #expect(result == .exec)
        #expect(watch.poll() == .unknown)
    }
}
