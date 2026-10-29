import Foundation

/// Internal in-memory JSON encoder for an already-validated WindowLayoutDocument.
/// Produces the version-1 wire envelope only; never reads a file, decodes input,
/// or touches external state.
enum WindowLayoutJSONEncoder {
    enum EncodingError: Error, Equatable, Sendable {
        case exceedsByteLimit(byteCount: Int, limit: Int)
    }

    static let byteCap = 2 * 1024 * 1024

    static func encode(_ document: WindowLayoutDocument) throws -> Data {
        let root = RootEnvelope(
            formatVersion: document.formatVersion,
            groups: document.groups.map { GroupEnvelope(group: $0) }
        )
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .throw
        let data = try encoder.encode(root)
        guard data.count <= Self.byteCap else {
            throw EncodingError.exceedsByteLimit(byteCount: Int(data.count), limit: Int(Self.byteCap))
        }
        return data
    }

    // MARK: - Private typed envelope structs

    private struct RootEnvelope: Encodable {
        let formatVersion: Int
        let groups: [GroupEnvelope]
    }

    private struct GroupEnvelope: Encodable {
        let id: String
        let windows: [WindowEnvelope]

        init(group: WindowLayoutDocument.Group) {
            self.id = group.id.uuidString
            self.windows = group.windows.map { WindowEnvelope(window: $0) }
        }
    }

    private struct WindowEnvelope: Encodable {
        let bundleIdentifier: String
        let display: DisplayEnvelope
        let frame: FrameEnvelope

        init(window: WindowLayoutDocument.Window) {
            self.bundleIdentifier = window.bundleIdentifier
            self.display = DisplayEnvelope(display: window.display)
            self.frame = FrameEnvelope(frame: window.frame)
        }
    }

    private struct DisplayEnvelope: Encodable {
        let width: CGFloat
        let height: CGFloat

        init(display: WindowLayoutDocument.DisplaySize) {
            self.width = display.width
            self.height = display.height
        }
    }

    private struct FrameEnvelope: Encodable {
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat

        init(frame: RelativeWindowFrame) {
            self.x = frame.x
            self.y = frame.y
            self.width = frame.width
            self.height = frame.height
        }
    }
}
