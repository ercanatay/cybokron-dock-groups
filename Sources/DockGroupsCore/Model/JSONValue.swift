import Foundation

/// Any JSON value, as read. Triggers keep what a newer version wrote that this one doesn't
/// understand in this form, so it's written back unchanged and never acted on
/// (`TriggerEvent.unsupported`).
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    /// A number without a fraction that fits 64 bits.
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// The value for `key` when this is an object.
    public subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    public var stringValue: String? {
        guard case .string(let string) = self else { return nil }
        return string
    }

    public var boolValue: Bool? {
        guard case .bool(let bool) = self else { return nil }
        return bool
    }

    /// A whole number: an integer, or a number without a fraction (`540.0`), that fits an `Int`.
    public var intValue: Int? {
        switch self {
        case .integer(let value):
            return Int(exactly: value)
        case .number(let value):
            guard value.isFinite, value.rounded() == value, abs(value) < 9.0e15 else { return nil }
            return Int(exactly: value)
        default:
            return nil
        }
    }

    public var arrayValue: [JSONValue]? {
        guard case .array(let array) = self else { return nil }
        return array
    }

    public var objectValue: [String: JSONValue]? {
        guard case .object(let object) = self else { return nil }
        return object
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let integer = try? container.decode(Int64.self) {
            self = .integer(integer)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
