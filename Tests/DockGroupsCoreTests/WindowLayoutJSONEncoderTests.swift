import Foundation
import Testing
@testable import DockGroupsCore

@Suite("WindowLayoutJSONEncoder")
struct WindowLayoutJSONEncoderTests {

    // MARK: - Privacy / key whitelist

    @Test func outputContainsOnlyAllowedKeysForDocument() throws {
        let doc = try makeDocument([makeGroup(windows: [makeWindow()])])
        let data = try WindowLayoutJSONEncoder.encode(doc)
        let obj = try #require(JSONSerialization.jsonObject(with: data, options: []) as? [String: Any])
        #expect(obj.keys.sorted() == ["formatVersion", "groups"])
    }

    @Test func outputContainsOnlyAllowedKeysForGroup() throws {
        let doc = try makeDocument([makeGroup(windows: [makeWindow()])])
        let data = try WindowLayoutJSONEncoder.encode(doc)
        let obj = try #require(JSONSerialization.jsonObject(with: data, options: []) as? [String: Any])
        let groups = try #require(obj["groups"] as? [[String: Any]])
        let firstGroup = try #require(groups.first)
        #expect(firstGroup.keys.sorted() == ["id", "windows"])
    }

    @Test func outputContainsOnlyAllowedKeysForWindow() throws {
        let doc = try makeDocument([makeGroup(windows: [makeWindow()])])
        let data = try WindowLayoutJSONEncoder.encode(doc)
        let obj = try #require(JSONSerialization.jsonObject(with: data, options: []) as? [String: Any])
        let groups = try #require(obj["groups"] as? [[String: Any]])
        let group = try #require(groups.first)
        let windows = try #require(group["windows"] as? [[String: Any]])
        let window = try #require(windows.first)
        #expect(window.keys.sorted() == ["bundleIdentifier", "display", "frame"])
    }

    @Test func outputContainsOnlyAllowedKeysForDisplay() throws {
        let doc = try makeDocument([makeGroup(windows: [makeWindow()])])
        let data = try WindowLayoutJSONEncoder.encode(doc)
        let obj = try #require(JSONSerialization.jsonObject(with: data, options: []) as? [String: Any])
        let groups = try #require(obj["groups"] as? [[String: Any]])
        let group = try #require(groups.first)
        let windows = try #require(group["windows"] as? [[String: Any]])
        let window = try #require(windows.first)
        let display = try #require(window["display"] as? [String: Any])
        #expect(display.keys.sorted() == ["height", "width"])
    }

    @Test func outputContainsOnlyAllowedKeysForFrame() throws {
        let doc = try makeDocument([makeGroup(windows: [makeWindow()])])
        let data = try WindowLayoutJSONEncoder.encode(doc)
        let obj = try #require(JSONSerialization.jsonObject(with: data, options: []) as? [String: Any])
        let groups = try #require(obj["groups"] as? [[String: Any]])
        let group = try #require(groups.first)
        let windows = try #require(group["windows"] as? [[String: Any]])
        let window = try #require(windows.first)
        let frame = try #require(window["frame"] as? [String: Any])
        #expect(frame.keys.sorted() == ["height", "width", "x", "y"])
    }

    @Test func noTitlePathOrLogFieldsAppearInOutput() throws {
        let doc = try makeDocument([makeGroup(windows: [makeWindow()])])
        let data = try WindowLayoutJSONEncoder.encode(doc)
        let jsonString = String(decoding: data, as: UTF8.self)
        #expect(!jsonString.contains("title"))
        #expect(!jsonString.contains("path"))
        #expect(!jsonString.contains("log"))
    }

    // MARK: - Empty and single fixtures

    @Test func emptyDocumentEncodesToVersionOneWithEmptyGroups() throws {
        let doc = try makeDocument([])
        let data = try WindowLayoutJSONEncoder.encode(doc)
        let obj = try #require(JSONSerialization.jsonObject(with: data, options: []) as? [String: Any])
        #expect(obj["formatVersion"] as? Int == 1)
        #expect((obj["groups"] as? [Any])?.isEmpty == true)
        #expect(obj.keys.sorted() == ["formatVersion", "groups"])
    }

    @Test func singleGroupSingleWindowPreservesOrderAndValues() throws {
        let id = UUID(uuidString: "12345678-1234-5678-1234-123456789abc")!
        let doc = try makeDocument([WindowLayoutDocument.Group(
            id: id,
            windows: [
                WindowLayoutDocument.Window(
                    bundleIdentifier: "com.apple.Safari",
                    display: WindowLayoutDocument.DisplaySize(width: 1920, height: 1080),
                    frame: RelativeWindowFrame(x: 0.1, y: 0.2, width: 0.5, height: 0.4)
                )
            ]
        )])
        let data = try WindowLayoutJSONEncoder.encode(doc)
        let obj = try #require(JSONSerialization.jsonObject(with: data, options: []) as? [String: Any])
        let groups = try #require(obj["groups"] as? [[String: Any]])
        #expect(groups.count == 1)
        let group = try #require(groups.first)
        #expect(group["id"] as? String == id.uuidString)
        let windows = try #require(group["windows"] as? [[String: Any]])
        #expect(windows.count == 1)
        let w = try #require(windows.first)
        #expect(w["bundleIdentifier"] as? String == "com.apple.Safari")
        let display = try #require(w["display"] as? [String: Any])
        #expect(display["width"] as? Double == 1920)
        #expect(display["height"] as? Double == 1080)
        let frame = try #require(w["frame"] as? [String: Any])
        #expect(frame["x"] as? Double == 0.1)
        #expect(frame["y"] as? Double == 0.2)
        #expect(frame["width"] as? Double == 0.5)
        #expect(frame["height"] as? Double == 0.4)
    }

    // MARK: - Multiple fixtures

    @Test func multipleGroupsAndWindowsPreserveOrder() throws {
        let ids = [UUID(), UUID(), UUID()]
        let windows = [
            makeWindow("com.a.App1"),
            makeWindow("com.a.App2"),
        ]
        let doc = try makeDocument([
            WindowLayoutDocument.Group(id: ids[0], windows: [windows[0]]),
            WindowLayoutDocument.Group(id: ids[1], windows: [windows[0], windows[1]]),
            WindowLayoutDocument.Group(id: ids[2], windows: [windows[1]]),
        ])
        let data = try WindowLayoutJSONEncoder.encode(doc)
        let obj = try #require(JSONSerialization.jsonObject(with: data, options: []) as? [String: Any])
        let groups = try #require(obj["groups"] as? [[String: Any]])
        #expect(groups.count == 3)
        #expect(groups[0]["id"] as? String == ids[0].uuidString)
        #expect(groups[1]["id"] as? String == ids[1].uuidString)
        #expect(groups[2]["id"] as? String == ids[2].uuidString)
        let group1Windows = try #require(groups[1]["windows"] as? [[String: Any]])
        #expect(group1Windows.count == 2)
    }

    // MARK: - Byte cap

    @Test func byteCountIsWithinCap() throws {
        let doc = try makeDocument([makeGroup(windows: [makeWindow()])])
        let data = try WindowLayoutJSONEncoder.encode(doc)
        #expect(data.count <= WindowLayoutJSONEncoder.byteCap)
        #expect(data.count == String(decoding: data, as: UTF8.self).utf8.count)
    }

    @Test func oversizedDocumentThrowsNonSensitiveError() throws {
        // Create a document with many groups, each with max windows, using long bundle identifiers.
        var groups: [WindowLayoutDocument.Group] = []
        for g in 0..<120 {
            var windows: [WindowLayoutDocument.Window] = []
            for w in 0..<64 {
                let id = String(repeating: "com.example.", count: 20) + String(g) + String(w)
                windows.append(WindowLayoutDocument.Window(
                    bundleIdentifier: String(id.prefix(255)),
                    display: WindowLayoutDocument.DisplaySize(width: 100_000, height: 100_000),
                    frame: RelativeWindowFrame(x: 0, y: 0, width: 1, height: 1)
                ))
            }
            groups.append(WindowLayoutDocument.Group(id: UUID(), windows: windows))
        }
        let doc = try makeDocument(groups)
        #expect(throws: WindowLayoutJSONEncoder.EncodingError.self) {
            try WindowLayoutJSONEncoder.encode(doc)
        }
    }

    // MARK: - Geometry and UUID validity

    @Test func validUUIDEncodedAsString() throws {
        let id = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let doc = try makeDocument([WindowLayoutDocument.Group(id: id, windows: [makeWindow()])])
        let data = try WindowLayoutJSONEncoder.encode(doc)
        let obj = try #require(JSONSerialization.jsonObject(with: data, options: []) as? [String: Any])
        let groups = try #require(obj["groups"] as? [[String: Any]])
        let group = try #require(groups.first)
        #expect(group["id"] as? String == "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")
    }

    @Test func finiteGeometryEncodedWithoutNaNOrInfinity() throws {
        let doc = try makeDocument([makeGroup(windows: [
            WindowLayoutDocument.Window(
                bundleIdentifier: "com.fin",
                display: WindowLayoutDocument.DisplaySize(width: 1, height: 1),
                frame: RelativeWindowFrame(x: 0, y: 0, width: 1, height: 1)
            )
        ])])
        let data = try WindowLayoutJSONEncoder.encode(doc)
        let jsonString = String(decoding: data, as: UTF8.self)
        #expect(!jsonString.contains("NaN"))
        #expect(!jsonString.contains("Infinity"))
        #expect(!jsonString.contains("-Infinity"))
    }

    // MARK: - Escaping

    @Test func specialCharactersInBundleIdentifierAreEncoded() throws {
        // Valid bundle identifiers per validation don't contain whitespace or control chars,
        // but can contain dots, dashes, etc. We verify encoding handles a standard one.
        let doc = try makeDocument([makeGroup(windows: [
            makeWindow("com.apple.Finder-Helper.App")
        ])])
        let data = try WindowLayoutJSONEncoder.encode(doc)
        let jsonString = String(decoding: data, as: UTF8.self)
        #expect(jsonString.contains("com.apple.Finder-Helper.App"))
    }

    // MARK: - Helpers (local, since WindowLayoutDocumentTests helpers are private)

    private func makeWindow(
        _ bundleIdentifier: String = "com.apple.Safari",
        display: WindowLayoutDocument.DisplaySize = WindowLayoutDocument.DisplaySize(width: 1710, height: 1079),
        frame: RelativeWindowFrame = RelativeWindowFrame(x: 0.1, y: 0.2, width: 0.5, height: 0.4)
    ) -> WindowLayoutDocument.Window {
        WindowLayoutDocument.Window(bundleIdentifier: bundleIdentifier, display: display, frame: frame)
    }

    private func makeGroup(
        id: UUID = UUID(),
        windows: [WindowLayoutDocument.Window] = []
    ) -> WindowLayoutDocument.Group {
        WindowLayoutDocument.Group(id: id, windows: windows.isEmpty ? [makeWindow()] : windows)
    }

    private func makeDocument(
        _ groups: [WindowLayoutDocument.Group],
        version: Int = WindowLayoutDocument.currentFormatVersion
    ) throws -> WindowLayoutDocument {
        try WindowLayoutDocument(formatVersion: version, groups: groups)
    }

    // MARK: - Non-sensitive error message

    @Test func oversizedErrorDoesNotContainBundleIdentifierOrPath() throws {
        var groups: [WindowLayoutDocument.Group] = []
        for g in 0..<150 {
            var windows: [WindowLayoutDocument.Window] = []
            for w in 0..<64 {
                windows.append(WindowLayoutDocument.Window(
                    bundleIdentifier: String(("com.sensitive.Secret" + String(repeating: "x", count: 220) + String(w)).prefix(255)),
                    display: WindowLayoutDocument.DisplaySize(width: 100_000, height: 100_000),
                    frame: RelativeWindowFrame(x: 0, y: 0, width: 1, height: 1)
                ))
            }
            groups.append(WindowLayoutDocument.Group(id: UUID(), windows: windows))
        }
        let doc = try makeDocument(groups)
        do {
            _ = try WindowLayoutJSONEncoder.encode(doc)
            Issue.record("Expected encoding to throw for oversized document")
        } catch let error as WindowLayoutJSONEncoder.EncodingError {
            let description = String(describing: error)
            #expect(!description.contains("Secret"))
            #expect(!description.contains("bundle"))
        }
    }
}
