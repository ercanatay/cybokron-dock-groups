import Foundation

/// Validates the syntax of a code-hash token used for application presence rules.
/// This validates syntax only — it does not verify trust, authorization,
/// or that the hash corresponds to any real application.
internal struct ApplicationCodeHash: Hashable, Sendable {
    internal let hex: String
    internal var requirementExpression: String {
        "cdhash H\"\(hex)\""
    }

    init?(bytes: [UInt8]) {
        guard bytes.count == 20 else { return nil }
        let hexChars = "0123456789abcdef"
        var result = ""
        for b in bytes {
            let hi = Int(b >> 4)
            let lo = Int(b & 0x0F)
            result.append(hexChars[hexChars.index(hexChars.startIndex, offsetBy: hi)])
            result.append(hexChars[hexChars.index(hexChars.startIndex, offsetBy: lo)])
        }
        self.hex = result
    }

    init?(hex: String) {
        guard hex.utf8.count == 40 else { return nil }
        let utf8Bytes = hex.utf8
        for b in utf8Bytes {
            guard (0x30...0x39).contains(b)
                || (0x61...0x66).contains(b)
                || (0x41...0x46).contains(b)
            else { return nil }
        }
        // Normalize uppercase to lowercase
        var normalized = ""
        for b in utf8Bytes {
            if b >= 0x41 && b <= 0x46 {
                normalized.append(Character(UnicodeScalar(b + 0x20)))
            } else {
                normalized.append(Character(UnicodeScalar(b)))
            }
        }
        self.hex = normalized
    }


}
