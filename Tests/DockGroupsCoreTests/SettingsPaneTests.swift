import Foundation
import Testing

/// The Settings window's panes and the About content they share, read from the app's sources:
/// the views live in the app target, which the tests don't link.
@Suite("Settings panes")
struct SettingsPaneTests {
    static func source(_ components: String...) throws -> String {
        let url = components.reduce(LocalizationTests.root.appending(path: "Sources")) { $0.appending(path: $1) }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The `case` names of `enum SettingsPane`, in sidebar order.
    static func paneCases() throws -> [String] {
        let text = try source("CybokronDockGroups", "Settings", "SettingsWindowController.swift")
        let start = try #require(text.range(of: "enum SettingsPane: String, CaseIterable, Identifiable {"))
        let body = text[start.upperBound...].prefix { $0 != "}" }
        let expression = try NSRegularExpression(pattern: #"^\s*case (\w+)\s*$"#, options: .anchorsMatchLines)
        let range = NSRange(body.startIndex..., in: body)
        return expression.matches(in: String(body), range: range).map { String(body[Range($0.range(at: 1), in: body)!]) }
    }

    @Test func supportIsTheLastPaneAfterTheChangelog() throws {
        #expect(try Self.paneCases() == ["popup", "shortcuts", "mostUsed", "updates", "backup", "changelog", "support"])
        let settings = try Self.source("CybokronDockGroups", "Settings", "SettingsWindowController.swift")
        #expect(settings.contains("case .support: L10n.Settings.supportTab"))
        #expect(settings.contains("case .support: \"heart\""))
        #expect(settings.contains("case .support:\n            SupportSettingsView()"))
        #expect(try LocalizationTests.table("en")["settings.support.tab"] == "Support")
    }

    /// The About window and Settings → Support show the same view, written once.
    @Test func supportShowsTheAboutWindowsContent() throws {
        let support = try Self.source("CybokronDockGroups", "Settings", "SupportSettingsView.swift")
        let about = try Self.source("CybokronDockGroups", "About", "AboutWindowController.swift")
        #expect(support.contains("AboutContentView()"))
        #expect(about.contains("AboutContentView()"))

        // Each of the content's views is declared once, in AboutContentView.swift.
        let sources = LocalizationTests.root.appending(path: "Sources")
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var declarations: [String: [String]] = [:]
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for name in ["AboutContentView", "BookCard", "LinkRow", "SocialButton"] where text.contains("struct \(name): View") {
                declarations[name, default: []].append(url.lastPathComponent)
            }
        }
        for name in ["AboutContentView", "BookCard", "LinkRow", "SocialButton"] {
            #expect(declarations[name] == ["AboutContentView.swift"], "\(name) is declared in \(declarations[name] ?? [])")
        }
    }
}
