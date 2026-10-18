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
        #expect(!app.isIdentifiedByPath)
        #expect(app.name == "Sample App")
        #expect(app.path == appURL.standardizedFileURL.path)
    }

    @Test func fallsBackToFileNameWithoutBundleName() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let appURL = try directory.makeAppBundle(named: "Nameless", info: ["CFBundleIdentifier": "com.example.nameless"])

        #expect(try AppReference(applicationURL: appURL).name == "Nameless")
    }

    @Test func bundleWithoutIdentifierIsIdentifiedByItsLocation() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let appURL = try directory.makeAppBundle(named: "NoID", info: ["CFBundleName": "No ID"])

        let app = try AppReference(applicationURL: appURL)

        #expect(app.isIdentifiedByPath)
        #expect(app.bundleIdentifier == appURL.resolvingSymlinksInPath().standardizedFileURL.path)
        #expect(app.name == "No ID")
        #expect(app.path == appURL.standardizedFileURL.path)
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
