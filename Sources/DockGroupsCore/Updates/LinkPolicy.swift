import Foundation

/// Which addresses from what GitHub (or a test server) sends the app follows: links in release
/// notes, a release's page, and the feed addresses the environment may override. Release notes are
/// written by whoever publishes a release, so their links mustn't open files, scripts, other apps —
/// or this app's own `cybokrondockgroups:` commands.
public enum LinkPolicy {
    /// Whether a link in release notes, and in the windows that show them, may be opened: an
    /// `https` address with a host, or a `mailto:` address. Everything else — `file:`,
    /// `javascript:`, plain `http:`, `cybokrondockgroups:` and other apps' schemes — isn't.
    public static func isClickable(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https":
            return !(url.host ?? "").isEmpty
        case "mailto":
            return true
        default:
            return false
        }
    }

    /// `text` with every link `isClickable` refuses turned into plain text (the words stay).
    public static func removingUnclickableLinks(from text: AttributedString) -> AttributedString {
        var result = text
        let refused = result.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard let link = run.link else { return nil }
            return isClickable(link) ? nil : run.range
        }
        for range in refused {
            result[range].link = nil
        }
        return result
    }

    /// A release's page on the web: an `https` address with a host, otherwise `nil`.
    public static func webPageURL(_ string: String?) -> URL? {
        guard let string, let url = URL(string: string), url.scheme?.lowercased() == "https",
              !(url.host ?? "").isEmpty
        else { return nil }
        return url
    }

    /// HTTPS anywhere; plain HTTP only to this Mac (a local test server). For the update feeds and
    /// the update's download.
    public static func isSecureOrLocal(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https":
            return !(url.host ?? "").isEmpty
        case "http":
            return ["127.0.0.1", "localhost", "::1"].contains(url.host?.lowercased() ?? "")
        default:
            return false
        }
    }
}
