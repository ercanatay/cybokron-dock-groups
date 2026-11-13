import Foundation
import Testing

extension Process {
    /// Default ceiling for a test's child process; generous so a loaded machine never trips it.
    static let testExitTimeout: Duration = .seconds(60)

    /// Launches the process and awaits its exit; see `waitForExit(timeout:)`.
    @discardableResult
    func runToExit(timeout: Duration = Process.testExitTimeout, sourceLocation: SourceLocation = #_sourceLocation) async throws -> Bool {
        try run()
        return await waitForExit(timeout: timeout, sourceLocation: sourceLocation)
    }

    /// Awaits the exit of a launched process without holding a thread: the wait is the
    /// `terminationHandler`, raced against `Task.sleep`, so a slow child never ties up a
    /// cooperative-pool thread other tests need. On timeout it logs the child's `ps` line,
    /// terminates it (SIGTERM, then SIGKILL after 2 s) and records a test failure instead of
    /// hanging the suite. Returns `false` when the ceiling was hit. Replaces any
    /// `terminationHandler` already set.
    @discardableResult
    func waitForExit(timeout: Duration = Process.testExitTimeout, sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        if await terminated(within: timeout) { return true }
        let pid = processIdentifier
        let snapshot = await Process.psSnapshot(pid: pid)
        terminate()
        if !(await terminated(within: .seconds(2))) {
            kill(pid, SIGKILL)
            _ = await terminated(within: .seconds(2))
        }
        Issue.record("Child process \(pid) did not exit within \(timeout) and was killed. ps: \(snapshot)", sourceLocation: sourceLocation)
        return false
    }

    /// `true` once the process has exited, `false` when `timeout` passed first.
    private func terminated(within timeout: Duration) async -> Bool {
        let signal = TerminationSignal()
        terminationHandler = { _ in signal.fire() }
        // The handler is not called for a process that exited before it was set.
        if !isRunning { signal.fire() }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await signal.wait()
                return !Task.isCancelled
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// The child's `ps` line, written to a file so nothing waits on a pipe's end.
    private static func psSnapshot(pid: Int32) async -> String {
        let file = FileManager.default.temporaryDirectory.appending(path: "CybokronDockGroupsTests-ps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        guard FileManager.default.createFile(atPath: file.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: file) else { return "<ps unavailable>" }
        defer { try? handle.close() }
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "pid,ppid,state,etime,command", "-p", String(pid)]
        ps.standardOutput = handle
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return "<ps unavailable>" }
        guard await ps.terminated(within: .seconds(5)) else {
            ps.terminate()
            return "<ps did not answer>"
        }
        return (try? String(contentsOf: file, encoding: .utf8)) ?? "<ps output unreadable>"
    }
}

/// A one-shot latch: `wait()` returns once `fire()` was called (before or after) or the waiting
/// task is cancelled.
private final class TerminationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fire() {
        lock.lock()
        fired = true
        let pending = waiters
        waiters = []
        lock.unlock()
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if fired {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
        } onCancel: {
            fire()
        }
    }
}

/// Child processes a test starts and must not leave behind.
final class ChildProcesses {
    private(set) var all: [Process] = []

    /// Registers `process` for cleanup and returns it.
    @discardableResult
    func adopt(_ process: Process) -> Process {
        all.append(process)
        return process
    }

    /// Terminates every child still running and awaits each exit.
    func stopAll(sourceLocation: SourceLocation = #_sourceLocation) async {
        for process in all {
            if process.isRunning { process.terminate() }
            await process.waitForExit(sourceLocation: sourceLocation)
        }
    }
}

/// Runs `body`, then stops and awaits every child it adopted, also when `body` throws: the async
/// replacement for a `defer` that waits on children.
func withChildProcesses<T>(isolation: isolated (any Actor)? = #isolation, sourceLocation: SourceLocation = #_sourceLocation, _ body: (ChildProcesses) async throws -> T) async throws -> T {
    let children = ChildProcesses()
    let result: Result<T, Error>
    do {
        result = .success(try await body(children))
    } catch {
        result = .failure(error)
    }
    await children.stopAll(sourceLocation: sourceLocation)
    return try result.get()
}

/// A fresh directory under the temporary directory (or under `base`), removed by `remove()`.
struct TemporaryDirectory {
    let url: URL

    init(base: URL = FileManager.default.temporaryDirectory) throws {
        url = base.appending(path: "CybokronDockGroupsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Creates a minimal `.app` bundle whose Info.plist contains `info`.
    func makeAppBundle(named name: String, info: [String: String]) throws -> URL {
        let appURL = url.appending(path: "\(name).app", directoryHint: .isDirectory)
        let contents = appURL.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appending(path: "Info.plist"))
        return appURL
    }

    /// Creates an `.app` bundle with no Info.plist at all, only a shell script as its executable, as
    /// hand-made wrapper apps often are.
    func makeScriptAppBundle(named name: String) throws -> URL {
        let appURL = url.appending(path: "\(name).app", directoryHint: .isDirectory)
        let macOS = appURL.appending(components: "Contents", "MacOS", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let executable = macOS.appending(path: name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return appURL
    }
}

/// The child-process wait itself: it returns at the child's exit, and a child that outlives the
/// ceiling is killed and fails the test.
@Suite("Test support: child-process waits")
struct ChildProcessWaitTests {
    private func process(_ script: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardInput = FileHandle.nullDevice
        return process
    }

    @Test func returnsAtTheExitAlsoForAChildThatExitedBeforeTheWait() async throws {
        let child = process("exit 3")
        #expect(try await child.runToExit())
        #expect(child.terminationStatus == 3)
        // Long gone by now: the handler set at this point is never called.
        #expect(await child.waitForExit(timeout: .seconds(5)))
    }

    @Test func aChildPastTheCeilingIsTerminatedAndFailsTheTest() async throws {
        let child = process("exec /bin/sleep 30")
        let clock = ContinuousClock()
        let start = clock.now
        try child.run()
        await withKnownIssue {
            #expect(await child.waitForExit(timeout: .milliseconds(200)) == false)
        } matching: { $0.description.contains("did not exit within") }
        #expect(!child.isRunning)
        #expect(child.terminationReason == .uncaughtSignal)
        #expect(child.terminationStatus == SIGTERM)
        // The child sleeps 30 s, so a kill (not a natural exit) is proven by finishing well short of that.
        // The margin is wide because a loaded CI runner can stretch the 200 ms ceiling by many seconds.
        #expect(clock.now - start < .seconds(25))
    }

    @Test func aChildIgnoringSIGTERMIsKilled() async throws {
        // An ignored signal stays ignored across exec.
        let child = process("trap '' TERM; exec /bin/sleep 30")
        try child.run()
        await withKnownIssue {
            #expect(await child.waitForExit(timeout: .milliseconds(200)) == false)
        } matching: { $0.description.contains("did not exit within") }
        #expect(!child.isRunning)
        #expect(child.terminationStatus == SIGKILL)
    }
}
