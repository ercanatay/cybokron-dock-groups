import Foundation
import Testing
@testable import CybokronDockGroups

@Test @MainActor func triggerPickerRejectsBundleWithoutExecutable() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dg-picker-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let app = dir.appendingPathComponent("NoExecutable.app", isDirectory: true)
    let contents = app.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let info: [String: String] = ["CFBundleIdentifier": "com.example.fixture", "CFBundleExecutable": "Missing", "CFBundlePackageType": "APPL"]
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))
    #expect(AppPicker.triggerApplication(at: app) == nil)
}

@Test @MainActor func triggerPickerChecksExecutablePermissions() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dg-picker-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    func makeBundle(_ name: String, permissions: Int) throws -> URL {
        let app = dir.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let binaryDirectory = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: binaryDirectory, withIntermediateDirectories: true)
        let info: [String: String] = ["CFBundleIdentifier": "com.example.\(name)", "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL"]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        let executable = binaryDirectory.appendingPathComponent("Fixture")
        try Data("test fixture, never executed".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: executable.path)
        return app
    }
    let nonExecutable = try makeBundle("NotExecutable", permissions: 0o644)
    let executable = try makeBundle("Valid", permissions: 0o755)
    let linked = try makeBundle("Linked", permissions: 0o755)
    let folderExecutable = try makeBundle("FolderExecutable", permissions: 0o755)
    let folderPath = folderExecutable.appendingPathComponent("Contents/MacOS/Fixture")
    try FileManager.default.removeItem(at: folderPath)
    try FileManager.default.createDirectory(at: folderPath, withIntermediateDirectories: false)
    let link = linked.appendingPathComponent("Contents/MacOS/Fixture")
    let target = linked.appendingPathComponent("Contents/MacOS/RealFixture")
    try FileManager.default.moveItem(at: link, to: target)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    #expect(AppPicker.triggerApplication(at: nonExecutable) == nil)
    #expect(AppPicker.triggerApplication(at: executable)?.bundleIdentifier == "com.example.Valid")
    #expect(AppPicker.triggerApplication(at: linked)?.bundleIdentifier == "com.example.Linked")
    #expect(AppPicker.triggerApplication(at: folderExecutable) == nil)
    #expect(AppPicker.triggerApplication(at: URL(string: "https://example.com/App.app")!) == nil)
}
