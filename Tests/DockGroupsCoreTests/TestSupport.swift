import Foundation
import Testing

extension Process {
    /// Default ceiling for a test's child process; generous so a loaded machine never trips it.
    static let testExitTimeout: TimeInterval = 60

    /// `waitUntilExit()` with a ceiling. On timeout it logs the child's `ps` line, terminates it
    /// (SIGTERM, then SIGKILL) and records a test failure instead of hanging the suite.
    /// Returns `false` when the ceiling was hit.
    @discardableResult
    func waitForExit(timeout: TimeInterval = Process.testExitTimeout) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while isRunning && Date() < deadline { usleep(5_000) }
        guard isRunning else { return true }
        let pid = processIdentifier
        let snapshot = Process.psSnapshot(pid: pid)
        terminate()
        let grace = Date().addingTimeInterval(2)
        while isRunning && Date() < grace { usleep(5_000) }
        if isRunning { kill(pid, SIGKILL) }
        let final = Date().addingTimeInterval(2)
        while isRunning && Date() < final { usleep(5_000) }
        Issue.record("Child process \(pid) did not exit within \(Int(timeout)) s and was killed. ps: \(snapshot)")
        return false
    }

    private static func psSnapshot(pid: Int32) -> String {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "pid,ppid,state,etime,command", "-p", String(pid)]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return "<ps unavailable>" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }
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
