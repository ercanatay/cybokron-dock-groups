import Foundation
import Testing
@testable import DockGroupsCore

@Suite("TriggerApplicationIdentifier")
struct TriggerApplicationIdentifierTests {
    @Test func acceptsSingleSegment() {
        let id = TriggerApplicationIdentifier("foo")
        #expect(id != nil)
        guard let v = id else { return }
        #expect(v.rawValue == "foo")
        #expect(v.matchKey == "foo")
    }

    @Test func acceptsReverseDns() {
        let id = TriggerApplicationIdentifier("com.example.sample")
        #expect(id != nil)
        guard let v = id else { return }
        #expect(v.rawValue == "com.example.sample")
        #expect(v.matchKey == "com.example.sample")
    }

    @Test func acceptsMixedCaseAndDash() {
        let id = TriggerApplicationIdentifier("My.App-123")
        #expect(id != nil)
        guard let v = id else { return }
        #expect(v.matchKey == "my.app-123")
        #expect(v.rawValue == "My.App-123")
    }

    @Test func preservesExactOriginalStringAsRawValue() {
        let id = TriggerApplicationIdentifier("EX.a.B")
        #expect(id != nil)
        guard let v = id else { return }
        #expect(v.rawValue == "EX.a.B")
        #expect(v.matchKey == "ex.a.b")
    }

    @Test func caseInsensitiveEquality() {
        let a = TriggerApplicationIdentifier("a.b")
        let b = TriggerApplicationIdentifier("A.B")
        #expect(a != nil && b != nil)
        guard let av = a, let bv = b else { return }
        #expect(av == bv)
    }

    @Test func setDeduplicatesByMatchKey() {
        let s: Set<TriggerApplicationIdentifier> = [TriggerApplicationIdentifier("x.y")!, TriggerApplicationIdentifier("X.Y")!, TriggerApplicationIdentifier("a.b")!]
        #expect(s.count == 2)
    }

    @Test func twoHundredFiftyFiveBytesAccepted() {
        let v = String(repeating: "a", count: 255)
        #expect(TriggerApplicationIdentifier(v) != nil)
    }

    @Test func twoHundredFiftySixBytesRejected() {
        let v = String(repeating: "a", count: 256)
        #expect(TriggerApplicationIdentifier(v) == nil)
    }

    @Test func nilForEmpty() {
        #expect(TriggerApplicationIdentifier("") == nil)
        #expect(TriggerApplicationIdentifier("   ") == nil)
    }

    @Test func nilForPunctuationOnly() {
        #expect(TriggerApplicationIdentifier("-._") == nil)
        #expect(TriggerApplicationIdentifier("-.") == nil)  // only allowed punctuation, no alphanumeric
        #expect(TriggerApplicationIdentifier("...") == nil) // only allowed punctuation, no alphanumeric
    }

    @Test func nilForSlashPathUrl() {
        #expect(TriggerApplicationIdentifier("/usr/bin/python") == nil)
        #expect(TriggerApplicationIdentifier("http://example.com") == nil)
        #expect(TriggerApplicationIdentifier("a://b") == nil)
    }

    @Test func nilForSpacesNewlines() {
        #expect(TriggerApplicationIdentifier("foo bar") == nil)
        #expect(TriggerApplicationIdentifier("foo\nbar") == nil)
        #expect(TriggerApplicationIdentifier("\tfoo") == nil)
    }

    @Test func nilForUnderscoreAndNonASCII() {
        #expect(TriggerApplicationIdentifier("foo_bar") == nil)
        #expect(TriggerApplicationIdentifier("münchen") == nil)
        #expect(TriggerApplicationIdentifier("é") == nil)
    }

    @Test func nilForControlCharacters() {
        #expect(TriggerApplicationIdentifier("A\u{01}") == nil)
        #expect(TriggerApplicationIdentifier("A\u{7F}") == nil)
    }

    @Test func hashConsistencyWithEquality() {
        let id1 = TriggerApplicationIdentifier("aaa")!
        let id2 = TriggerApplicationIdentifier("AAA")!
        #expect(id1 == id2)
        var h1 = Hasher()
        var h2 = Hasher()
        id1.hash(into: &h1)
        id2.hash(into: &h2)
        #expect(h1.finalize() == h2.finalize())
    }
}
