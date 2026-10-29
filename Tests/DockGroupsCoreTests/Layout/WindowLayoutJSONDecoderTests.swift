import Foundation
import Testing
@testable import DockGroupsCore

@Suite("WindowLayoutJSONDecoder")
struct WindowLayoutJSONDecoderTests {
    // MARK: - Valid documents

    @Test func acceptsEmptyGroups() throws {
        let json = #"{"formatVersion":1,"groups":[]}"#
        let doc = try WindowLayoutJSONDecoder.decode(Data(json.utf8))
        #expect(doc.formatVersion == 1)
        #expect(doc.groups.isEmpty)
    }

    @Test func acceptsSingleGroupWithOneWindow() throws {
        let json = #"{"formatVersion":1,"groups":[{"id":"12345678-1234-1234-1234-123456789abc","windows":[{"bundleIdentifier":"com.example.App","display":{"width":1920,"height":1080},"frame":{"x":0.1,"y":0.2,"width":0.5,"height":0.4}}]}]}"#
        let doc = try WindowLayoutJSONDecoder.decode(Data(json.utf8))
        #expect(doc.groups.count == 1)
        #expect(doc.groups.first!.windows.count == 1)
    }

    @Test func acceptsUnknownKeyAtRootRejected() {
        let json = #"{"formatVersion":1,"groups":[],"extra":1}"#
        #expect(throws: WindowLayoutJSONDecodeError.unknownKeys) {
            _ = try WindowLayoutJSONDecoder.decode(Data(json.utf8))
        }
    }

    @Test func acceptsUnknownKeyAtGroupRejected() {
        let json = #"{"formatVersion":1,"groups":[{"id":"12345678-1234-1234-1234-123456789abc","windows":[],"bad":1}]}"#
        #expect(throws: WindowLayoutJSONDecodeError.unknownKeys) {
            _ = try WindowLayoutJSONDecoder.decode(Data(json.utf8))
        }
    }

    @Test func acceptsUnknownKeyAtWindowRejected() {
        let json = #"{"formatVersion":1,"groups":[{"id":"12345678-1234-1234-1234-123456789abc","windows":[{"bundleIdentifier":"com.example.App","display":{"width":1920,"height":1080},"frame":{"x":0,"y":0,"width":1,"height":1},"bad":1}]}]}"#
        #expect(throws: WindowLayoutJSONDecodeError.unknownKeys) {
            _ = try WindowLayoutJSONDecoder.decode(Data(json.utf8))
        }
    }

    @Test func acceptsUnknownKeyAtDisplayRejected() {
        let json = #"{"formatVersion":1,"groups":[{"id":"12345678-1234-1234-1234-123456789abc","windows":[{"bundleIdentifier":"com.example.App","display":{"width":1920,"height":1080,"bad":1},"frame":{"x":0,"y":0,"width":1,"height":1}}]}]}"#
        #expect(throws: WindowLayoutJSONDecodeError.unknownKeys) {
            _ = try WindowLayoutJSONDecoder.decode(Data(json.utf8))
        }
    }

    @Test func acceptsUnknownKeyAtFrameRejected() {
        let json = #"{"formatVersion":1,"groups":[{"id":"12345678-1234-1234-1234-123456789abc","windows":[{"bundleIdentifier":"com.example.App","display":{"width":1920,"height":1080},"frame":{"x":0,"y":0,"width":1,"height":1,"bad":1}}]}]}"#
        #expect(throws: WindowLayoutJSONDecodeError.unknownKeys) {
            _ = try WindowLayoutJSONDecoder.decode(Data(json.utf8))
        }
    }

    @Test func missingRootFormatVersionRejected() {
        let json = #"{"groups":[]}"#
        #expect(throws: WindowLayoutJSONDecodeError.missingFields) {
            _ = try WindowLayoutJSONDecoder.decode(Data(json.utf8))
        }
    }

    @Test func missingRootGroupsRejected() {
        let json = #"{"formatVersion":1}"#
        #expect(throws: WindowLayoutJSONDecodeError.missingFields) {
            _ = try WindowLayoutJSONDecoder.decode(Data(json.utf8))
        }
    }

    @Test func unsupportedVersionRejected() {
        let json = #"{"formatVersion":2,"groups":[]}"#
        #expect(throws: WindowLayoutJSONDecodeError.unsupportedFormatVersion) {
            _ = try WindowLayoutJSONDecoder.decode(Data(json.utf8))
        }
    }

    @Test func badUTF8Rejected() {
        let data = Data([0x7B, 0x22, 0x66, 0x6F, 0x72, 0x6D, 0x61, 0x74, 0x56, 0x65, 0x72, 0x73, 0x69, 0x6F, 0x6E, 0x22, 0x3A, 0x31, 0x2C, 0x22, 0x67, 0x72, 0x6F, 0x75, 0x70, 0x73, 0x22, 0x3A, 0x5B, 0x5D, 0x7D])
        // Actually use invalid UTF-8 byte
        let bad = Data([0xC3, 0x28])
        #expect(throws: WindowLayoutJSONDecodeError.preflightFailed) {
            _ = try WindowLayoutJSONDecoder.decode(bad)
        }
    }

    @Test func duplicateKeysAtRootRejected() {
        let json = #"{"formatVersion":1,"formatVersion":1,"groups":[]}"#
        #expect(throws: WindowLayoutJSONDecodeError.preflightFailed) {
            _ = try WindowLayoutJSONDecoder.decode(Data(json.utf8))
        }
    }

    @Test func escapedDuplicateKeyRejected() {
        let json = #"{"formatVersion":1,"groups":[],"\u0067roups":[]}"#
        #expect(throws: WindowLayoutJSONDecodeError.preflightFailed) {
            _ = try WindowLayoutJSONDecoder.decode(Data(json.utf8))
        }
    }

    @Test func malformedJSONRejected() {
        let json = #"{"formatVersion":1,"groups":[,]}"#
        #expect(throws: WindowLayoutJSONDecodeError.malformedJSON) {
            _ = try WindowLayoutJSONDecoder.decode(Data(json.utf8))
        }
    }

    @Test func booleanAsNumberRejected() {
        let json = #"{"formatVersion":true,"groups":[]}"#
        #expect(throws: WindowLayoutJSONDecodeError.malformedJSON) {
            _ = try WindowLayoutJSONDecoder.decode(Data(json.utf8))
        }
    }

    @Test func excessiveInputRejected() {
        var bytes = [UInt8](repeating: 0x20, count: 2 * 1024 * 1024 + 1)
        bytes[0] = 0x7B; bytes[1] = 0x22; bytes[bytes.count-2] = 0x22; bytes[bytes.count-1] = 0x7D
        #expect(throws: WindowLayoutJSONDecodeError.preflightFailed) {
            _ = try WindowLayoutJSONDecoder.decode(Data(bytes))
        }
    }

    @Test func tooManyGroupsRejected() throws {
        let window: [String: Any] = ["bundleIdentifier": "com.example.App", "display": ["width": 100, "height": 100], "frame": ["x": 0, "y": 0, "width": 1, "height": 1]]
        let groups: [[String: Any]] = (0...WindowLayoutDocument.maximumGroupCount).map { _ in ["id": UUID().uuidString, "windows": [window]] }
        let data = try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "groups": groups])
        #expect(throws: WindowLayoutJSONDecodeError.tooManyGroups) { try WindowLayoutJSONDecoder.decode(data) }
    }

    @Test func tooManyWindowsRejected() throws {
        let windows: [[String: Any]] = (0...WindowLayoutDocument.maximumWindowCountPerGroup).map { i in ["bundleIdentifier": "com.example.App\(i)", "display": ["width": 100, "height": 100], "frame": ["x": 0, "y": 0, "width": 1, "height": 1]] }
        let group: [String: Any] = ["id": UUID().uuidString, "windows": windows]
        let data = try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "groups": [group]])
        #expect(throws: WindowLayoutJSONDecodeError.tooManyWindows) { try WindowLayoutJSONDecoder.decode(data) }
    }

    @Test func duplicateGroupIDRejectedByValidator() throws {
        let id = UUID().uuidString
        let json = #"{"formatVersion":1,"groups":[{"id":"\#(id)","windows":[{"bundleIdentifier":"com.example.App","display":{"width":100,"height":100},"frame":{"x":0,"y":0,"width":1,"height":1}}]},{"id":"\#(id)","windows":[{"bundleIdentifier":"com.example.App","display":{"width":100,"height":100},"frame":{"x":0,"y":0,"width":1,"height":1}}]}]}"#
        #expect(throws: WindowLayoutJSONDecodeError.invalidDocument) {
            _ = try WindowLayoutJSONDecoder.decode(Data(json.utf8))
        }
    }

    @Test func invalidBundlePathRejectedByValidator() throws {
        let json = #"{"formatVersion":1,"groups":[{"id":"12345678-1234-1234-1234-123456789abc","windows":[{"bundleIdentifier":"/Applications/Safari.app","display":{"width":100,"height":100},"frame":{"x":0,"y":0,"width":1,"height":1}}]}]}"#
        #expect(throws: WindowLayoutJSONDecodeError.invalidDocument) {
            _ = try WindowLayoutJSONDecoder.decode(Data(json.utf8))
        }
    }

    @Test func errorDoesNotLeakUntrustedData() throws {
        let badId = "/Users/secret/file.pdf"
        let json = #"{"formatVersion":1,"groups":[{"id":"12345678-1234-1234-1234-123456789abc","windows":[{"bundleIdentifier":"\#(badId)","display":{"width":100,"height":100},"frame":{"x":0,"y":0,"width":1,"height":1}}]}]}"#
        do {
            _ = try WindowLayoutJSONDecoder.decode(Data(json.utf8))
            Issue.record("expected failure")
        } catch let error as WindowLayoutJSONDecodeError {
            let desc = String(describing: error)
            #expect(!desc.contains("/Users/secret"))
            #expect(!desc.contains(badId))
        }
    }

    @Test func depthSafetyRejected() {
        let deep = String(repeating: "[[", count: 33) + "{}" + String(repeating: "]]", count: 33)
        #expect(throws: WindowLayoutJSONDecodeError.preflightFailed) {
            _ = try WindowLayoutJSONDecoder.decode(Data(deep.utf8))
        }
    }
    @Test func acceptsMaximumNumberOfGroups() throws {
        let window: [String: Any] = ["bundleIdentifier": "com.example.App", "display": ["width": 100, "height": 100], "frame": ["x": 0, "y": 0, "width": 1, "height": 1]]
        let groups: [[String: Any]] = (0..<WindowLayoutDocument.maximumGroupCount).map { _ in ["id": UUID().uuidString, "windows": [window]] }
        let data = try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "groups": groups])
        let decoded = try WindowLayoutJSONDecoder.decode(data)
        #expect(decoded.groups.count == WindowLayoutDocument.maximumGroupCount)
    }

    @Test func acceptsMaximumWindowsInOneGroup() throws {
        let windows: [[String: Any]] = (0..<WindowLayoutDocument.maximumWindowCountPerGroup).map { i in ["bundleIdentifier": "com.example.App\(i)", "display": ["width": 100, "height": 100], "frame": ["x": 0, "y": 0, "width": 1, "height": 1]] }
        let group: [String: Any] = ["id": UUID().uuidString, "windows": windows]
        let data = try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "groups": [group]])
        let decoded = try WindowLayoutJSONDecoder.decode(data)
        #expect(decoded.groups.first?.windows.count == WindowLayoutDocument.maximumWindowCountPerGroup)
    }

    @Test func escapedUnknownKeyIsRejected() {
        let data = Data(#"{"formatVersion":1,"groups":[],"\u0073ecret":1}"#.utf8)
        #expect(throws: WindowLayoutJSONDecodeError.unknownKeys) { try WindowLayoutJSONDecoder.decode(data) }
    }

    @Test func nestedEscapedDuplicateIsRejected() {
        let data = Data(#"{"formatVersion":1,"groups":[{"id":"12345678-1234-1234-1234-123456789abc","windows":[{"bundleIdentifier":"com.example.App","display":{"width":100,"\u0077idth":100,"height":100},"frame":{"x":0,"y":0,"width":1,"height":1}}]}]}"#.utf8)
        #expect(throws: WindowLayoutJSONDecodeError.preflightFailed) { try WindowLayoutJSONDecoder.decode(data) }
    }

    @Test func unpairedSurrogateIsRejected() {
        let data = Data(#"{"formatVersion":1,"groups":[],"\uD800":1}"#.utf8)
        #expect(throws: WindowLayoutJSONDecodeError.preflightFailed) { try WindowLayoutJSONDecoder.decode(data) }
    }

    @Test func oversizedGroupArrayFailsBeforeDecodingElements() throws {
        let data = try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "groups": Array(repeating: "invalid", count: WindowLayoutDocument.maximumGroupCount + 1)])
        #expect(throws: WindowLayoutJSONDecodeError.tooManyGroups) { try WindowLayoutJSONDecoder.decode(data) }
    }

    @Test func oversizedWindowArrayFailsBeforeDecodingElements() throws {
        let group: [String: Any] = ["id": UUID().uuidString, "windows": Array(repeating: "invalid", count: WindowLayoutDocument.maximumWindowCountPerGroup + 1)]
        let data = try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "groups": [group]])
        #expect(throws: WindowLayoutJSONDecodeError.tooManyWindows) { try WindowLayoutJSONDecoder.decode(data) }
    }

    @Test func nonFiniteOrOverflowNumberIsRejected() {
        let data = Data(#"{"formatVersion":1,"groups":[{"id":"12345678-1234-1234-1234-123456789abc","windows":[{"bundleIdentifier":"com.example.App","display":{"width":1e999,"height":100},"frame":{"x":0,"y":0,"width":1,"height":1}}]}]}"#.utf8)
        #expect(throws: (any Error).self) { try WindowLayoutJSONDecoder.decode(data) }
    }

    @Test func encoderDecoderRoundTripPreservesValidatedModel() throws {
        let id = UUID()
        let windows = [
            WindowLayoutDocument.Window(bundleIdentifier: "com.example.Alpha", display: .init(width: 1920, height: 1080), frame: .init(x: -0.1, y: 0.1, width: 0.8, height: 0.6)),
            WindowLayoutDocument.Window(bundleIdentifier: "com.example.Beta", display: .init(width: 1440, height: 900), frame: .init(x: 0, y: 0, width: 1, height: 1))
        ]
        let original = try WindowLayoutDocument(groups: [.init(id: id, windows: windows)])
        let data = try WindowLayoutJSONEncoder.encode(original)
        #expect(try WindowLayoutJSONDecoder.decode(data) == original)
    }

    @Test func encoderDecoderRoundTripPreservesEmptyDocument() throws {
        let original = try WindowLayoutDocument(groups: [])
        #expect(try WindowLayoutJSONDecoder.decode(WindowLayoutJSONEncoder.encode(original)) == original)
    }

    @Test func variedValidModelsRoundTrip() throws {
        for i in 0..<200 {
            let x = CGFloat(i % 17) / 100 - 0.08
            let y = CGFloat(i % 13) / 100
            let width = CGFloat(41 + i % 23) / 100
            let height = CGFloat(52 + i % 19) / 100
            let window = WindowLayoutDocument.Window(
                bundleIdentifier: "com.example.RoundTrip\(i)",
                display: .init(width: CGFloat(800 + i), height: CGFloat(600 + i)),
                frame: .init(x: x, y: y, width: width, height: height)
            )
            let original = try WindowLayoutDocument(groups: [.init(id: UUID(), windows: [window])])
            let data = try WindowLayoutJSONEncoder.encode(original)
            #expect(try WindowLayoutJSONDecoder.decode(data) == original)
        }
    }

    @Test func newerVersionWithDifferentStructureIsRecognized() {
        let data = Data(#"{"formatVersion":99,"futureField":{"layout":"new"},"groups":{"future":"shape"}}"#.utf8)
        #expect(throws: WindowLayoutJSONDecodeError.unsupportedFormatVersion) { try WindowLayoutJSONDecoder.decode(data) }
    }

}
