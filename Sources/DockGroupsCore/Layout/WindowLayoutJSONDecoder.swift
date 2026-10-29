import CoreGraphics
import Foundation

internal enum WindowLayoutJSONDecodeError: Error, Equatable, Sendable {
    case preflightFailed
    case malformedJSON
    case badUTF8
    case invalidUnicode
    case numberOverflow
    case excessiveInput
    case unknownKeys
    case missingFields
    case unsupportedFormatVersion
    case tooManyGroups
    case tooManyWindows
    case invalidDocument
}

internal enum WindowLayoutJSONDecoder {
    static func decode(_ data: Data) throws -> WindowLayoutDocument {
        switch JSONDuplicateKeyPreflight.check(data: data) {
        case .pass:
            break
        case .fail:
            throw WindowLayoutJSONDecodeError.preflightFailed
        }
        let decoder = JSONDecoder()
        do {
            let document = try decoder.decode(RootDocumentDecoder.self, from: data)
            return try WindowLayoutDocument(formatVersion: document.formatVersion, groups: document.groups)
        } catch let error as WindowLayoutJSONDecodeError {
            throw error
        } catch let error as DecodingError {
            switch error {
            case .keyNotFound(_, _), .valueNotFound(_, _):
                throw WindowLayoutJSONDecodeError.missingFields
            default:
                throw WindowLayoutJSONDecodeError.malformedJSON
            }
        } catch is WindowLayoutDocument.ValidationError {
            throw WindowLayoutJSONDecodeError.invalidDocument
        } catch {
            throw WindowLayoutJSONDecodeError.invalidDocument
        }
    }
}

private struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(stringValue: String) {
        self.stringValue = stringValue
    }
    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private struct RootDocumentDecoder: Decodable {
    let formatVersion: Int
    let groups: [WindowLayoutDocument.Group]

    enum CodingKeys: String, CodingKey {
        case formatVersion, groups
    }

    init(from decoder: Decoder) throws {
        let dynamic = try decoder.container(keyedBy: AnyCodingKey.self)
        let allowed = Set(["formatVersion", "groups"])
        let keys = Set(dynamic.allKeys.map { $0.stringValue })
        if !keys.isSubset(of: allowed) {
            throw WindowLayoutJSONDecodeError.unknownKeys
        }
        let required = Set(["formatVersion", "groups"])
        if !required.isSubset(of: keys) {
            throw WindowLayoutJSONDecodeError.missingFields
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        if formatVersion != WindowLayoutDocument.currentFormatVersion {
            throw WindowLayoutJSONDecodeError.unsupportedFormatVersion
        }

        var groupsArray = try container.nestedUnkeyedContainer(forKey: .groups)
        var groups: [WindowLayoutDocument.Group] = []
        while !groupsArray.isAtEnd {
            if let c = groupsArray.count, c > WindowLayoutDocument.maximumGroupCount {
                throw WindowLayoutJSONDecodeError.tooManyGroups
            }
            if groups.count >= WindowLayoutDocument.maximumGroupCount {
                throw WindowLayoutJSONDecodeError.tooManyGroups
            }
            let group = try groupsArray.decode(GroupDocumentDecoder.self).toModel()
            groups.append(group)
        }
        self.groups = groups
    }
}

private struct GroupDocumentDecoder: Decodable {
    func toModel() throws -> WindowLayoutDocument.Group {
        let groupID = try UUID(uuidString: id) ?? { throw WindowLayoutJSONDecodeError.missingFields }()
        return WindowLayoutDocument.Group(id: groupID, windows: windows)
    }

    let id: String
    let windows: [WindowLayoutDocument.Window]

    enum CodingKeys: String, CodingKey {
        case id, windows
    }

    init(from decoder: Decoder) throws {
        let dynamic = try decoder.container(keyedBy: AnyCodingKey.self)
        let allowed = Set(["id", "windows"])
        let keys = Set(dynamic.allKeys.map { $0.stringValue })
        if !keys.isSubset(of: allowed) {
            throw WindowLayoutJSONDecodeError.unknownKeys
        }
        let required = Set(["id", "windows"])
        if !required.isSubset(of: keys) {
            throw WindowLayoutJSONDecodeError.missingFields
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)

        var windowsArray = try container.nestedUnkeyedContainer(forKey: .windows)
        var windows: [WindowLayoutDocument.Window] = []
        while !windowsArray.isAtEnd {
            if let c = windowsArray.count, c > WindowLayoutDocument.maximumWindowCountPerGroup {
                throw WindowLayoutJSONDecodeError.tooManyWindows
            }
            if windows.count >= WindowLayoutDocument.maximumWindowCountPerGroup {
                throw WindowLayoutJSONDecodeError.tooManyWindows
            }
            let window = try windowsArray.decode(WindowDocumentDecoder.self).toModel()
            windows.append(window)
        }
        self.windows = windows
    }
}

private struct WindowDocumentDecoder: Decodable {
    func toModel() throws -> WindowLayoutDocument.Window {
        let width = display.width
        let height = display.height
        guard width.isFinite && height.isFinite else {
            throw WindowLayoutJSONDecodeError.malformedJSON
        }
        let x = frame.x
        let y = frame.y
        let fw = frame.width
        let fh = frame.height
        guard fw.isFinite && fh.isFinite else {
            throw WindowLayoutJSONDecodeError.malformedJSON
        }
        return WindowLayoutDocument.Window(
            bundleIdentifier: bundleIdentifier,
            display: WindowLayoutDocument.DisplaySize(width: width, height: height),
            frame: RelativeWindowFrame(x: x, y: y, width: fw, height: fh)
        )
    }

    let bundleIdentifier: String
    let display: WindowLayoutDocument.DisplaySize
    let frame: RelativeWindowFrame

    enum CodingKeys: String, CodingKey {
        case bundleIdentifier, display, frame
    }

    init(from decoder: Decoder) throws {
        let dynamic = try decoder.container(keyedBy: AnyCodingKey.self)
        let allowed = Set(["bundleIdentifier", "display", "frame"])
        let keys = Set(dynamic.allKeys.map { $0.stringValue })
        if !keys.isSubset(of: allowed) {
            throw WindowLayoutJSONDecodeError.unknownKeys
        }
        let required = Set(["bundleIdentifier", "display", "frame"])
        if !required.isSubset(of: keys) {
            throw WindowLayoutJSONDecodeError.missingFields
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        display = try container.decode(DisplayDocumentDecoder.self, forKey: .display).toModel()
        frame = try container.decode(FrameDocumentDecoder.self, forKey: .frame).toModel()
    }
}

private struct DisplayDocumentDecoder: Decodable {
    func toModel() throws -> WindowLayoutDocument.DisplaySize {
        return WindowLayoutDocument.DisplaySize(width: width, height: height)
    }

    let width: CGFloat
    let height: CGFloat

    enum CodingKeys: String, CodingKey {
        case width, height
    }

    init(from decoder: Decoder) throws {
        let dynamic = try decoder.container(keyedBy: AnyCodingKey.self)
        let allowed = Set(["width", "height"])
        let keys = Set(dynamic.allKeys.map { $0.stringValue })
        if !keys.isSubset(of: allowed) {
            throw WindowLayoutJSONDecodeError.unknownKeys
        }
        let required = Set(["width", "height"])
        if !required.isSubset(of: keys) {
            throw WindowLayoutJSONDecodeError.missingFields
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        width = try container.decode(CGFloat.self, forKey: .width)
        height = try container.decode(CGFloat.self, forKey: .height)
    }
}

private struct FrameDocumentDecoder: Decodable {
    func toModel() throws -> RelativeWindowFrame {
        return RelativeWindowFrame(x: x, y: y, width: width, height: height)
    }

    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    enum CodingKeys: String, CodingKey {
        case x, y, width, height
    }

    init(from decoder: Decoder) throws {
        let dynamic = try decoder.container(keyedBy: AnyCodingKey.self)
        let allowed = Set(["x", "y", "width", "height"])
        let keys = Set(dynamic.allKeys.map { $0.stringValue })
        if !keys.isSubset(of: allowed) {
            throw WindowLayoutJSONDecodeError.unknownKeys
        }
        let required = Set(["x", "y", "width", "height"])
        if !required.isSubset(of: keys) {
            throw WindowLayoutJSONDecodeError.missingFields
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        x = try container.decode(CGFloat.self, forKey: .x)
        y = try container.decode(CGFloat.self, forKey: .y)
        width = try container.decode(CGFloat.self, forKey: .width)
        height = try container.decode(CGFloat.self, forKey: .height)
    }
}
