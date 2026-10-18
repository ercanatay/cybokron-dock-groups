import Foundation

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
