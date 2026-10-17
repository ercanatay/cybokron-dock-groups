import Foundation
import Testing
@testable import DockGroupsCore

@Suite("App references")
struct AppReferenceTests {
    @Test func readsIdentityFromBundle() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let appURL = try directory.makeAppBundle(
            named: "Sample",
            info: ["CFBundleIdentifier": "com.example.sample", "CFBundleName": "Sample App"]
        )

        let app = try AppReference(applicationURL: appURL)

        #expect(app.bundleIdentifier == "com.example.sample")
        #expect(app.name == "Sample App")
        #expect(app.path == appURL.standardizedFileURL.path)
    }

    @Test func fallsBackToFileNameWithoutBundleName() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let appURL = try directory.makeAppBundle(named: "Nameless", info: ["CFBundleIdentifier": "com.example.nameless"])

        #expect(try AppReference(applicationURL: appURL).name == "Nameless")
    }

    @Test func rejectsBundleWithoutIdentifier() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let appURL = try directory.makeAppBundle(named: "NoID", info: ["CFBundleName": "No ID"])

        #expect(throws: AppReferenceError.missingBundleIdentifier(path: appURL.standardizedFileURL.path)) {
            try AppReference(applicationURL: appURL)
        }
    }

    @Test func rejectsNonApplications() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let fileURL = directory.url.appending(path: "notes.txt")
        try Data("hi".utf8).write(to: fileURL)

        #expect(throws: AppReferenceError.notAnApplication(path: fileURL.standardizedFileURL.path)) {
            try AppReference(applicationURL: fileURL)
        }
    }
}
