import Foundation
import Testing
@testable import DockGroupsCore

/// `LinkPolicy`: which links from release notes, release pages and feed overrides the app follows.
@Suite("Link policy")
struct LinkPolicyTests {
    /// The links of `text`, in order.
    private func links(in text: AttributedString) -> [URL] {
        text.runs.compactMap(\.link)
    }

    /// Markdown with one link of every kind the tests care about.
    private let mixedLinks = "[file](file:///etc/hosts) [script](javascript:alert(1)) [quit](cybokrondockgroups://quit/work) "
        + "[settings](x-apple.systempreferences:com.apple.preference.security) [plain](http://example.com/a) "
        + "[web](https://cybokron.com/dock-groups/) [mail](mailto:hello@example.com)"

    @Test(arguments: [
        ("https://github.com/ercanatay/cybokron-dock-groups", true),
        ("HTTPS://GitHub.com/x", true),
        ("mailto:hello@example.com", true),
        ("http://example.com/", false),
        ("https:///no-host", false),
        ("file:///etc/hosts", false),
        ("javascript:alert(1)", false),
        ("cybokrondockgroups://quit/work?mode=force", false),
        ("x-apple.systempreferences:com.apple.preference.security", false),
        ("ftp://example.com/file", false),
    ])
    func clickableLinks(address: String, isClickable: Bool) throws {
        #expect(LinkPolicy.isClickable(try #require(URL(string: address))) == isClickable, "\(address)")
    }

    @Test func inlineNotesKeepOnlyHTTPSAndMailLinks() {
        let text = ReleaseNotesMarkdown.inline(mixedLinks)

        #expect(links(in: text) == [URL(string: "https://cybokron.com/dock-groups/")!, URL(string: "mailto:hello@example.com")!])
        // The words of the refused links stay, as plain text.
        #expect(String(text.characters) == "file script quit settings plain web mail")
    }

    @Test func inlineNotesWithOnlyUnsafeLinksHaveNone() {
        let text = ReleaseNotesMarkdown.inline("[a](file:///etc/hosts) [b](javascript:alert(1)) [c](cybokrondockgroups://launch/work) <cybokrondockgroups://quit/work>")
        #expect(links(in: text).isEmpty)
    }

    @Test func updateWindowNotesUseTheSameRule() throws {
        let text = try #require(ReleaseNotesMarkdown.compact("## What's new\n- " + mixedLinks + "\n* second item"))

        #expect(links(in: text) == [URL(string: "https://cybokron.com/dock-groups/")!, URL(string: "mailto:hello@example.com")!])
        #expect(String(text.characters) == "What's new\n• file script quit settings plain web mail\n• second item")
        #expect(text.runs.contains { String(text[$0.range].characters) == "What's new" && $0.inlinePresentationIntent == .stronglyEmphasized })
        #expect(ReleaseNotesMarkdown.compact(" \n\t\n") == nil, "no notes")
    }

    @Test func pageAddressesMustBeHTTPS() {
        #expect(LinkPolicy.webPageURL("https://github.com/ercanatay/cybokron-dock-groups/releases/tag/v0.6.0")?.absoluteString
            == "https://github.com/ercanatay/cybokron-dock-groups/releases/tag/v0.6.0")
        for address in ["http://github.com/x", "javascript:alert(1)", "file:///Applications", "cybokrondockgroups://quit/work", "https:///x", "", "not a url"] {
            #expect(LinkPolicy.webPageURL(address) == nil, "\(address)")
        }
        #expect(LinkPolicy.webPageURL(nil) == nil)
    }

    @Test func releasePagesThatArentHTTPSAreDropped() throws {
        func release(htmlURL: String) throws -> ReleaseInfo {
            try ReleaseInfo.decode(from: Data(#"{"tag_name": "v0.7.0", "html_url": "\#(htmlURL)"}"#.utf8))
        }
        #expect(try release(htmlURL: "https://github.com/ercanatay/cybokron-dock-groups/releases/tag/v0.7.0").pageURL != nil)
        #expect(try release(htmlURL: "javascript:alert(1)").pageURL == nil)
        #expect(try release(htmlURL: "http://github.com/ercanatay/cybokron-dock-groups/releases/tag/v0.7.0").pageURL == nil)
        #expect(try release(htmlURL: "file:///etc/hosts").pageURL == nil)
        #expect(try release(htmlURL: "cybokrondockgroups://quit/work").pageURL == nil)

        // A saved changelog entry is read the same way.
        let entry = try JSONDecoder().decode(ChangelogEntry.self, from: Data(#"{"tagName": "v0.7.0", "pageURL": "cybokrondockgroups://quit/work"}"#.utf8))
        #expect(entry.pageURL == nil)
        let kept = try JSONDecoder().decode(ChangelogEntry.self, from: Data(#"{"tagName": "v0.7.0", "pageURL": "https://github.com/x/y/releases/tag/v0.7.0"}"#.utf8))
        #expect(kept.pageURL?.absoluteString == "https://github.com/x/y/releases/tag/v0.7.0")
    }

    @Test func secureOrLocalAddresses() throws {
        for address in ["https://example.com/latest.json", "http://127.0.0.1:8765/latest.json", "http://localhost:8765/x", "http://[::1]:8765/x", "HTTP://LOCALHOST/x"] {
            #expect(LinkPolicy.isSecureOrLocal(try #require(URL(string: address))), "\(address)")
        }
        for address in ["http://example.com/latest.json", "http://192.168.1.2:8765/latest.json", "file:///etc/hosts", "ftp://example.com/x", "https:///x"] {
            #expect(!LinkPolicy.isSecureOrLocal(try #require(URL(string: address))), "\(address)")
        }
    }

    /// The three feed overrides: `https` anywhere, plain `http` only to this Mac.
    @Test func feedOverridesRefusePlainHTTPToOtherMachines() {
        let feeds: [(variable: String, resolve: ([String: String]) -> URL, fallback: URL)] = [
            (GitHubReleaseFeed.urlOverrideVariable, { GitHubReleaseFeed.resolvedURL(environment: $0) }, UpdateLinks.latestReleaseAPI),
            (GitHubReleaseFeed.listURLOverrideVariable, { GitHubReleaseFeed.resolvedListURL(environment: $0) }, UpdateLinks.releasesAPI),
            (GitHubChangelogFeed.urlOverrideVariable, { GitHubChangelogFeed.resolvedURL(environment: $0) }, UpdateLinks.changelogReleasesAPI),
        ]
        for feed in feeds {
            #expect(feed.resolve([feed.variable: "http://example.com/latest.json"]) == feed.fallback, "\(feed.variable)")
            #expect(feed.resolve([feed.variable: "http://10.0.0.5:8765/latest.json"]) == feed.fallback, "\(feed.variable)")
            #expect(feed.resolve([feed.variable: "https://example.com/latest.json"]).absoluteString == "https://example.com/latest.json")
            #expect(feed.resolve([feed.variable: "http://localhost:8765/latest.json"]).absoluteString == "http://localhost:8765/latest.json")
            #expect(feed.resolve([feed.variable: "http://127.0.0.1:8765/latest.json"]).absoluteString == "http://127.0.0.1:8765/latest.json")
        }
    }

    /// Release builds (overrides not enabled) ignore every override, even a valid https one, and the
    /// dry run and simulated signing failure switches.
    @Test func releaseBuildsIgnoreEveryOverride() {
        let feeds: [(variable: String, resolve: ([String: String]) -> URL, fallback: URL)] = [
            (GitHubReleaseFeed.urlOverrideVariable, { GitHubReleaseFeed.resolvedURL(environment: $0, overridesEnabled: false) }, UpdateLinks.latestReleaseAPI),
            (GitHubReleaseFeed.listURLOverrideVariable, { GitHubReleaseFeed.resolvedListURL(environment: $0, overridesEnabled: false) }, UpdateLinks.releasesAPI),
            (GitHubChangelogFeed.urlOverrideVariable, { GitHubChangelogFeed.resolvedURL(environment: $0, overridesEnabled: false) }, UpdateLinks.changelogReleasesAPI),
        ]
        for feed in feeds {
            #expect(feed.resolve([feed.variable: "https://example.com/latest.json"]) == feed.fallback, "\(feed.variable)")
            #expect(feed.resolve([feed.variable: "http://127.0.0.1:8765/latest.json"]) == feed.fallback, "\(feed.variable)")
        }
        let environment = [UpdateInstaller.dryRunVariable: "1", AgentInstaller.simulateSigningFailureVariable: "1"]
        #expect(DevelopmentOverrides.value(UpdateInstaller.dryRunVariable, in: environment, enabled: false) == nil)
        #expect(DevelopmentOverrides.value(AgentInstaller.simulateSigningFailureVariable, in: environment, enabled: false) == nil)
        #expect(DevelopmentOverrides.value(UpdateInstaller.dryRunVariable, in: environment, enabled: true) == "1")
    }

    /// `scripts/test.sh` builds with the DEBUG condition, as Debug builds do; Release builds (and
    /// `swift test -c release`) don't have it.
    @Test func overridesAreEnabledOnlyInDevelopmentBuilds() throws {
        #if DEBUG
        #expect(DevelopmentOverrides.areEnabled)
        #expect(GitHubReleaseFeed.resolvedURL(environment: [GitHubReleaseFeed.urlOverrideVariable: "https://example.com/x.json"]).host() == "example.com")
        #else
        #expect(!DevelopmentOverrides.areEnabled)
        #expect(GitHubReleaseFeed.resolvedURL(environment: [GitHubReleaseFeed.urlOverrideVariable: "https://example.com/x.json"]) == UpdateLinks.latestReleaseAPI)
        #endif
        // The switch is the DEBUG compilation condition, nothing a shipped copy can change.
        let source = try String(
            contentsOf: LocalizationTests.root.appending(components: "Sources", "DockGroupsCore", "Updates", "DevelopmentOverrides.swift"),
            encoding: .utf8
        )
        #expect(source.contains("#if DEBUG\n        return true\n        #else\n        return false\n        #endif"))
    }

    /// A user name in a link dresses one host up as another; such links show as text.
    @Test func linksWithAUserNameOrPasswordArentClickable() throws {
        for address in [
            "https://github.com%2F@evil.example/x",
            "https://user@evil.example",
            "https://user:pass@evil.example/",
            "https://@evil.example",
            "https://github.com:@evil.example",
        ] {
            let url = try #require(URL(string: address), "\(address)")
            #expect(LinkPolicy.hasUserInfo(url), "\(address)")
            #expect(!LinkPolicy.isClickable(url), "\(address)")
            #expect(LinkPolicy.webPageURL(address) == nil, "\(address)")
        }
        #expect(LinkPolicy.isClickable(try #require(URL(string: "https://github.com/ercanatay/cybokron-dock-groups/releases"))))
        #expect(LinkPolicy.isClickable(try #require(URL(string: "mailto:someone@example.com"))), "a mail address isn't a user name")

        let text = ReleaseNotesMarkdown.inline("[GitHub](https://github.com%2F@evil.example/x) and https://user@evil.example")
        #expect(!text.runs.contains { $0.link != nil })
        #expect(String(text.characters).hasPrefix("GitHub and "))
    }

    /// GitHub API answers, after any redirects, come from GitHub over HTTPS — or from the host a
    /// development override asked.
    @Test func apiAnswersMustComeFromGitHub() throws {
        let api = UpdateLinks.latestReleaseAPI
        func allowed(_ final: String, for request: URL) throws -> Bool {
            LinkPolicy.isAllowedAPIAnswer(from: try #require(URL(string: final)), for: request)
        }
        #expect(try allowed(api.absoluteString, for: api))
        #expect(try allowed("https://api.github.com/repositories/1/releases/latest", for: api))
        #expect(try allowed("https://github.com/x", for: api))
        #expect(try !allowed("http://api.github.com/x", for: api))
        #expect(try !allowed("https://evil.example/latest", for: api))
        #expect(try !allowed("https://api.github.com.evil.example/x", for: api))
        #expect(try !allowed("https://user@api.github.com/x", for: api))

        let local = try #require(URL(string: "http://127.0.0.1:8765/latest.json"))
        #expect(try allowed("http://127.0.0.1:8765/other.json", for: local))
        #expect(try !allowed("http://127.0.0.1:9999/latest.json", for: local))
        #expect(try !allowed("http://localhost:8765/latest.json", for: local))
    }

    @Test func aFeedRedirectedAwayFromGitHubFails() async throws {
        let url = StubURLProtocol.register(.init(body: ReleaseFixtures.data(ReleaseFixtures.v060WithDecoys), finalURL: URL(string: "https://evil.example/latest")!))
        let feed = GitHubReleaseFeed(url: url, appVersion: "0.6.4", session: StubURLProtocol.makeSession())

        await #expect(throws: UpdateCheckError.network("redirected to evil.example")) {
            try await feed.latestRelease()
        }
        let changelog = StubURLProtocol.register(.init(body: Data("[]".utf8), finalURL: URL(string: "http://api.github.com/x")!))
        await #expect(throws: UpdateCheckError.network("redirected to api.github.com")) {
            try await GitHubChangelogFeed(url: changelog, appVersion: "0.6.4", session: StubURLProtocol.makeSession()).releases(ifNoneMatch: nil)
        }
    }

    @Test func downloadsFollowTheSameRule() throws {
        #expect(UpdateInstaller.isAllowedDownloadURL(try #require(URL(string: "https://github.com/x.dmg"))))
        #expect(UpdateInstaller.isAllowedDownloadURL(try #require(URL(string: "http://127.0.0.1:8765/x.dmg"))))
        #expect(!UpdateInstaller.isAllowedDownloadURL(try #require(URL(string: "http://example.com/x.dmg"))))
    }
}
