import Foundation

/// Bounded, pure, linear preflight for duplicate object member keys in raw JSON-like data.
///
/// SCOPE / LIMITATIONS (read before relying on the result):
/// - This is ONLY a preflight, not validation. A successful `.pass` does NOT mean the input is
///   valid JSON, does NOT verify schema, contents, numeric ranges, or encoding completeness,
///   and does NOT authorize importing. A separate full strict decode + model validator is
///   required before any data is used.
/// - It does not decode JSON syntax (grammar stays with the later decoder).
/// - It checks only: byte-size cap, UTF-8 validity, nesting depth, unterminated strings /
///   brackets, unpaired surrogates / invalid string escapes (via Foundation JSONDecoder on
///   each string token), and duplicate keys within the same object scope at any depth.
/// - Keys are compared after escape decoding (`"id"` and `"\u0069d"` are equal).
/// - No file I/O, network, UI, AX, window movement, or git operations occur.
/// - Errors never embed raw input texts (privacy of untrusted keys/values).
///
enum JSONDuplicateKeyPreflight {
    private static let maxBytes = 2 * 1024 * 1024
    private static let maxDepth = 32
    private static let maxKeysPerObject = 64

    enum Result: Equatable, Sendable {
        case pass
        case fail(String) // never includes raw input
    }

    /// Pure bounded scan. Input `data` is never retained beyond this call.
    static func check(data: Data) -> Result {
        // 1. Byte cap before scanning.
        guard data.count <= maxBytes else {
            return .fail("input exceeds 2 MiB")
        }
        // 2. Invalid UTF-8.
        guard String(data: data, encoding: .utf8) != nil else {
            return .fail("invalid UTF-8")
        }
        // 3. Bounded linear byte scan.
        return scan(bytes: Array(data))
    }

    // MARK: - Reference-type key container (per-scan, never shared across calls)

    /// A tiny reference type used within a single `check()` scan to track
    /// object keys without triggering value-type copy-on-write.
    private class KeySetRef {
        var set: Set<String>
        init() { self.set = [] }
    }

    private static func scan(bytes: [UInt8]) -> Result {
        var i = 0
        let n = bytes.count
        var depth = 0
        enum Scope {
            case object(ref: KeySetRef)
            case array
        }
        var scopes: [Scope] = []

        func isWhitespace(_ b: UInt8) -> Bool {
            b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
        }

        // Helper: check if current token is a key (followed by colon after whitespace)
        func isObjectKey(after i: Int, bytes: [UInt8]) -> Bool {
            var j = i
            while j < n && isWhitespace(bytes[j]) { j += 1 }
            return j < n && bytes[j] == 0x3A // colon
        }

        while i < n {
            // Skip whitespace.
            while i < n && isWhitespace(bytes[i]) { i += 1 }
            guard i < n else { break }
            let b = bytes[i]

            if b == 0x7B { // {
                if depth >= maxDepth { return .fail("nesting exceeds 32") }
                depth += 1
                scopes.append(.object(ref: KeySetRef()))
                i += 1
            } else if b == 0x7D { // }
                guard depth > 0 else { return .fail("unterminated structure") }
                guard case .object = scopes.last else { return .fail("mismatched bracket") }
                depth -= 1
                scopes.removeLast()
                i += 1
            } else if b == 0x5B { // [
                if depth >= maxDepth { return .fail("nesting exceeds 32") }
                depth += 1
                scopes.append(.array)
                i += 1
            } else if b == 0x5D { // ]
                guard depth > 0 else { return .fail("unterminated structure") }
                guard case .array = scopes.last else { return .fail("mismatched bracket") }
                depth -= 1
                scopes.removeLast()
                i += 1
            } else if b == 0x22 { // "
                let start = i
                i += 1
                var terminated = false
                while i < n {
                    if bytes[i] == 0x22 { // closing quote
                        i += 1
                        terminated = true
                        break
                    } else if bytes[i] == 0x5C { // backslash: skip escaped char
                        i += 1
                        if i >= n {
                            return .fail("unterminated string")
                        }
                        i += 1
                    } else {
                        i += 1
                    }
                }
                if !terminated {
                    return .fail("unterminated string")
                }
                // Extract token with quotes.
                let tokenData = Data(bytes[start..<i])
                // Strict decode of the string token only (never regex).
                guard let decodedString = try? JSONDecoder().decode(String.self, from: tokenData) else {
                    return .fail("invalid JSON string token")
                }
                // Identify whether this token is an object key: inside object and followed (after ws) by colon.
                if case .object(ref: let ref) = scopes.last, isObjectKey(after: i, bytes: bytes) {
                    // Check and insert key — linear via Set.contains/Set.insert through the ref.
                    if ref.set.contains(decodedString) {
                        return .fail("duplicate object key")
                    }
                    // Enforce provisional max 64 keys per object.
                    if ref.set.count >= maxKeysPerObject {
                        return .fail("too many keys in object")
                    }
                    ref.set.insert(decodedString)
                }
                // If not a key (no colon after), it's a value; no duplicate check needed.
            } else {
                // Primitive / number / true / false / null: advance by one so the main loop
                // processes braces, brackets, quotes, and commas individually.
                i += 1
            }
        }

        if depth != 0 {
            return .fail("unterminated structure")
        }
        return .pass
    }
}