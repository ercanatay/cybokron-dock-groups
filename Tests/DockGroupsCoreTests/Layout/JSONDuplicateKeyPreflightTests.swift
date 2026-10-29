import Testing
import Foundation
@testable import DockGroupsCore

struct JSONDuplicateKeyPreflightTests {
    // MARK: - Happy path (pass)

    @Test func emptyObjectPasses() {
        let data = Data("{}".utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) == .pass)
    }

    @Test func simpleNoDuplicatesPasses() {
        let data = Data("{\"id\":\"abc\",\"name\":\"Test\"}".utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) == .pass)
    }

    @Test func emptyArrayPasses() {
        let data = Data("[]".utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) == .pass)
    }

    @Test func arrayOfObjectsNoDuplicatesAcrossObjectsPasses() {
        // Same key in different objects is NOT a duplicate.
        let data = Data("[{\"id\":\"a\"},{\"id\":\"b\"}]".utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) == .pass)
    }

    @Test func nestedObjectsKeyReuseIsNotDuplicate() {
        let data = Data("{\"outer\":{\"id\":1},\"inner\":{\"id\":2}}".utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) == .pass)
    }

    // MARK: - Duplicate keys (fail)

    @Test func sameObjectDuplicateKeysFail() {
        let data = Data("{\"id\":\"a\",\"id\":\"b\"}".utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) != .pass)
    }

    @Test func nestedSameScopeDuplicateKeysFail() {
        let data = Data("{\"g\":{\"a\":1,\"a\":2}}".utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) != .pass)
    }

    @Test func duplicateKeyInArrayElementObjectFails() {
        let data = Data("[{\"x\":1,\"x\":2}]".utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) != .pass)
    }

    @Test func duplicateKeyDeeplyNestedFails() {
        let data = Data("{\"a\":{\"b\":{\"c\":1,\"c\":2}}}".utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) != .pass)
    }

    // MARK: - Escaped equivalent keys (decoded comparison)

    @Test func escapedUnicodeKeyEqualsPlainKeyFails() {
        // "\u0069d" decodes to "id", so it duplicates plain "id".
        let data = Data("{\"id\":1,\"\\u0069d\":2}".utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) != .pass)
    }

    @Test func escapedReverseOrderAlsoFails() {
        let data = Data("{\"\\u0069d\":1,\"id\":2}".utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) != .pass)
    }

    @Test func differentUnicodeEscapeSameStringFails() {
        // "\u0069d" and "id" are same after decode.
        let data = Data("{\"\\u0069d\":1,\"id\":2}".utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) != .pass)
    }

    // MARK: - Unicode escapes / surrogates

    @Test func validUnicodeEscapePasses() {
        let data = Data("{\"\\u0065moji\":\"\\u0048\"}".utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) == .pass)
    }

    @Test func unpairedSurrogateFails() {
        // High surrogate without low surrogate is invalid.
        let data = Data("{\"k\":\"\\uD800\"}".utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) != .pass)
    }

    @Test func unpairedLowSurrogateFails() {
        let data = Data("{\"k\":\"\\uDC00\"}".utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) != .pass)
    }

    @Test func validSurrogatePairPasses() {
        let data = Data("{\"k\":\"\\uD83D\\uDE00\"}".utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) == .pass)
    }

    // MARK: - Invalid escapes

    @Test func invalidStringEscapeFails() {
        // "\x" is not a valid JSON escape.
        let data = Data("{\"k\":\"\\x\"}".utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) != .pass)
    }

    // MARK: - Escaped quote / backslash inside strings

    @Test func escapedQuoteInStringPasses() {
        let data = Data("{\"k\":\"a\\\"b\"}".utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) == .pass)
    }

    @Test func escapedBackslashInStringPasses() {
        let data = Data("{\"k\":\"a\\\\b\"}".utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) == .pass)
    }

    @Test func escapedQuoteDoesNotCloseString() {
        // quote after backslash is escaped, not terminator.
        let data = Data("{\"k\":\"\\\"\",\"k2\":1}".utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) == .pass)
    }

    // MARK: - Punctuation / brackets inside strings / values

    @Test func punctuationInValueStringPasses() {
        let data = Data("{\"msg\":\"hello, world! @#$%^&*()\"}".utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) == .pass)
    }

    @Test func valueTextContainingColonPasses() {
        // ":" inside a string value must not be mistaken for key-value separator.
        let data = Data("{\"url\":\"http://example.com\"}".utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) == .pass)
    }

    @Test func bracketsInsideStringPasses() {
        let data = Data("{\"k\":\"[nested]\"}".utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) == .pass)
    }

    @Test func braceInsideStringValuePasses() {
        let data = Data("{\"k\":\"a{b}c\"}".utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) == .pass)
    }

    @Test func keyWithPunctuationPasses() {
        let data = Data("{\"a-b.c\":1}".utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) == .pass)
    }

    // MARK: - Invalid UTF-8

    @Test func invalidUTF8Fails() {
        let data = Data([0x7B, 0x22, 0xC3, 0x28, 0x22, 0x3A, 0x31, 0x7D])
        #expect(JSONDuplicateKeyPreflight.check(data: data) != .pass)
    }

    @Test func loneContinuationByteFails() {
        let data = Data([0x7B, 0x80, 0x7D])
        #expect(JSONDuplicateKeyPreflight.check(data: data) != .pass)
    }

    // MARK: - Byte boundaries

    @Test func exactlyTwoMibBoundary() {
        // 2 MiB = 2 * 1024 * 1024 = 2097152 bytes. Build exactly that size of valid JSON.
        let cap = 2 * 1024 * 1024
        var bytes = [UInt8]()
        bytes.append(0x7B) // {
        // fill with whitespace then close object
        for _ in 0..<(cap - 2) { bytes.append(0x20) } // spaces
        bytes.append(0x7D) // }
        let data = Data(bytes)
        #expect(data.count == cap)
        #expect(JSONDuplicateKeyPreflight.check(data: data) == .pass)
    }

    @Test func oneByteOverTwoMibFails() {
        let cap = 2 * 1024 * 1024 + 1
        var bytes = [UInt8](repeating: 0x20, count: cap) // all spaces
        let data = Data(bytes)
        #expect(data.count == cap)
        #expect(JSONDuplicateKeyPreflight.check(data: data) != .pass)
    }

    // MARK: - Nesting depth

    @Test func depth32Passes() throws {
        let s = String(repeating: "[", count: 32) + "0" + String(repeating: "]", count: 32)
        let data = Data(s.utf8)
        _ = try JSONSerialization.jsonObject(with: data)
        #expect(JSONDuplicateKeyPreflight.check(data: data) == .pass)
    }

    @Test func depth33Fails() throws {
        let s = String(repeating: "[", count: 33) + "0" + String(repeating: "]", count: 33)
        let data = Data(s.utf8)
        _ = try JSONSerialization.jsonObject(with: data)
        #expect(JSONDuplicateKeyPreflight.check(data: data) != .pass)
    }

    // MARK: - Unterminated structures

    @Test func unterminatedStringFails() {
        let data = Data("{\"k\":\"unterminated".utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) != .pass)
    }

    @Test func unterminatedObjectFails() {
        let data = Data("{\"k\":1".utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) != .pass)
    }

    @Test func unterminatedArrayFails() {
        let data = Data("[1,2".utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) != .pass)
    }

    @Test func mismatchedBracketsFail() {
        let data = Data("{]}".utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) != .pass)
    }

    @Test func trailingCloseWithoutOpenFails() {
        let data = Data("}".utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) != .pass)
    }

    // MARK: - Privacy of errors

    @Test func errorNeverContainsRawKey() {
        let data = Data("{\"secretKey\":\"value\"}".utf8)
        // Force a duplicate on a "secret" key so error mentions key word but not value.
        let dup = Data("{\"secretKey\":1,\"secretKey\":2}".utf8)
        let result = JSONDuplicateKeyPreflight.check(data: dup)
        if case .fail(let message) = result {
            #expect(!message.contains("secretKey"))
            #expect(!message.contains("value"))
        } else {
            Issue.record("expected fail")
        }
    }

    @Test func errorNeverContainsRawValue() {
        let dup = Data("{\"k\":\"secret123\",\"k\":\"secret456\"}".utf8)
        let result = JSONDuplicateKeyPreflight.check(data: dup)
        if case .fail(let message) = result {
            #expect(!message.contains("secret123"))
            #expect(!message.contains("secret456"))
        } else {
            Issue.record("expected fail")
        }
    }

    // MARK: - Arrays inside objects do not leak keys

    @Test func keysInsideNestedObjectInsideArrayAreScoped() {
        // Two separate objects inside an array may reuse "id".
        let data = Data("[{\"id\":1},{\"id\":2}]".utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) == .pass)
    }

    @Test func duplicateKeyInsideSameNestedObjectFails() {
        let data = Data("[{\"id\":1,\"id\":2}]".utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) != .pass)
    }

    // MARK: - Complex value with colon inside key context

    @Test func objectKeyFollowedByValueColonInsideStringDoesNotBreakKeyDetection() {
        // Key "url" then string containing colon, then closing.
        let data = Data("{\"url\":\"http://x:y\"}".utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) == .pass)
    }

    // MARK: - Provisional max 64 keys per object

    @Test func exactly64UniqueKeysPasses() {
        var s = "{"
        for i in 0..<64 {
            if i > 0 { s += "," }
            s += "\"k\(i)\":\(i)"
        }
        s += "}"
        let data = Data(s.utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) == .pass)
    }

    @Test func exactly65UniqueKeysFails() {
        var s = "{"
        for i in 0..<65 {
            if i > 0 { s += "," }
            s += "\"k\(i)\":\(i)"
        }
        s += "}"
        let data = Data(s.utf8)
        let result = JSONDuplicateKeyPreflight.check(data: data)
        if case .fail(let message) = result {
            #expect(message == "too many keys in object")
            #expect(!message.contains("k64"))
            #expect(!message.contains("k0"))
        } else {
            Issue.record("expected fail at 65 keys")
        }
    }

    @Test func nestedObjectsEachGetIndependentBudget() {
        // Each object gets its own 64-key budget.
        // Parent: 63 loop keys + 1 "child" key = 64 total (within budget).
        // Child: 64 keys (within budget). Independent budget → both pass.
        var s = "{"
        for i in 0..<63 {
            if i > 0 { s += "," }
            s += "\"p\(i)\":\(i)"
        }
        s += ","
        s += "\"child\":{"
        for i in 0..<64 {
            if i > 0 { s += "," }
            s += "\"c\(i)\":\(i)"
        }
        s += "}}"
        let data = Data(s.utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) == .pass)
    }

    @Test func siblingObjectsEachGetIndependentBudget() {
        // Parent: 63 loop keys + 1 "grp" key = 64 total (within budget).
        // Sibling inside array: 65 keys — must fail its own budget.
        var s = "["
        s += "{"
        for i in 0..<63 {
            if i > 0 { s += "," }
            s += "\"a\(i)\":\(i)"
        }
        s += ",\"grp\":{"
        for i in 0..<64 {
            if i > 0 { s += "," }
            s += "\"b\(i)\":\(i)"
        }
        s += "}}"
        s += "]"
        let data = Data(s.utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) == .pass)
    }

    @Test func budgetDoesNotApplyInsideArrays() {
        // Arrays don't track keys, so a 65-element array of objects is fine.
        var s = "["
        for i in 0..<65 {
            if i > 0 { s += "," }
            s += "{\"k\":\(i)}"
        }
        s += "]"
        let data = Data(s.utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) == .pass)
    }

    @Test func duplicateKeyStillRejectedAfterBudget() {
        // Even before hitting 64, duplicates must still fail.
        let data = Data("{\"a\":1,\"a\":2}".utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) != .pass)
    }

    // MARK: - Unicode escaping in keys

    @Test func unicodeEscapedKeyWithValidSurrogatePairPasses() {
        let data = Data("{\"\\uD83D\\uDE00\":1}".utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) == .pass)
    }

    @Test func escapedUnicodeKeyStillDetectsDuplicate() {
        // "\u0069d" == "id" after decode; both present in same object → duplicate.
        let data = Data("{\"id\":1,\"\\u0069d\":2}".utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) != .pass)
    }

    @Test func escapedKeyDifferentFromPlainKeyPasses() {
        // "\u0065" == "e", so "k\u0065y" == "key" — same as plain "key" → duplicate.
        let data = Data("{\"key\":1,\"k\\u0065y\":2}".utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) != .pass)
    }

    // MARK: - Arrays nested inside objects

    @Test func nestedArrayInsideObjectDoesNotLeakKeys() {
        let data = Data("{\"items\":[1,2,3],\"name\":\"x\"}".utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) == .pass)
    }

    @Test func arrayNestedInObjectNestedInArray() {
        // [[{"a":1}]] — array → array → object, then back out.
        let data = Data("[[{\"a\":1}]]".utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) == .pass)
    }

    @Test func duplicateKeyInsideArrayElementObjectStillFails() {
        let data = Data("[{\"x\":1,\"x\":2}]".utf8)
        #expect(JSONDuplicateKeyPreflight.check(data: data) != .pass)
    }
}
