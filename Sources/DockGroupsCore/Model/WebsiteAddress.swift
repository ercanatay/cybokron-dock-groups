import Foundation

/// Why a typed web address can't be added to a group.
public enum WebsiteAddressError: LocalizedError, Equatable, Sendable {
    case empty
    /// Not a web address at all, or one that can't be opened.
    case invalid
    /// A scheme other than http or https, such as `file:` or `javascript:`.
    case unsupportedScheme(String)
    /// The address carries a user name or password, which would be saved as plain text.
    case containsCredentials

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "Enter a web address."
        case .invalid:
            return "This isn't a valid web address."
        case .unsupportedScheme(let scheme):
            return "Only http and https addresses can be added, not “\(scheme):”."
        case .containsCredentials:
            return "Remove the user name and password from the address."
        }
    }
}

/// Reading and normalizing the web addresses of website items (`AppReference.Kind.website`).
public enum WebsiteAddress {
    /// The schemes a website item can have.
    public static let allowedSchemes: Set<String> = ["http", "https"]

    /// The address `input` stands for, as typed into "Add Website…": surrounding whitespace is
    /// ignored and an address without a scheme gets "https://" ("github.com" becomes
    /// "https://github.com"). The scheme and host are lowercased and an empty path is dropped
    /// ("https://GitHub.com/" becomes "https://github.com"), so the same site is stored the same way.
    /// Only http and https addresses with a host are accepted.
    public static func parse(_ input: String) throws -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WebsiteAddressError.empty }
        guard !trimmed.contains(where: \.isWhitespace) else { throw WebsiteAddressError.invalid }
        let candidate: String
        if let scheme = explicitScheme(of: trimmed) {
            guard allowedSchemes.contains(scheme.lowercased()) else {
                throw WebsiteAddressError.unsupportedScheme(scheme.lowercased())
            }
            candidate = trimmed
        } else {
            candidate = "https://" + trimmed
        }
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              allowedSchemes.contains(scheme),
              let host = components.host, isValidHost(host)
        else {
            throw WebsiteAddressError.invalid
        }
        guard components.user == nil, components.password == nil else {
            throw WebsiteAddressError.containsCredentials
        }
        components.scheme = scheme
        components.host = host.lowercased()
        if components.path == "/", components.query == nil, components.fragment == nil {
            components.path = ""
        }
        guard let url = components.url else { throw WebsiteAddressError.invalid }
        return url
    }

    /// The name a website gets when none is given: its host without a leading "www."
    /// ("https://www.github.com/x" is "github.com").
    public static func defaultName(for url: URL) -> String {
        let host = url.host() ?? url.absoluteString
        return host.hasPrefix("www.") && host.count > 4 ? String(host.dropFirst(4)) : host
    }

    /// Whether a saved identifier is a web address rather than a bundle identifier or location:
    /// bundle identifiers can't contain ":" and locations start with "/".
    public static func looksLikeAddress(_ identifier: String) -> Bool {
        let lowercased = identifier.lowercased()
        return lowercased.hasPrefix("https://") || lowercased.hasPrefix("http://")
    }

    /// The scheme `text` starts with ("mailto" for "mailto:me@example.com"), or `nil` when it has
    /// none. "localhost:8080" and "example.com:443/path" have a port, not a scheme.
    private static func explicitScheme(of text: String) -> String? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let scheme = text[..<colon]
        guard let first = scheme.first, first.isASCII, first.isLetter,
              scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) })
        else { return nil }
        let rest = text[text.index(after: colon)...]
        if rest.hasPrefix("//") { return String(scheme) }
        // "host:port" — digits up to the end or the path.
        let port = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        if !port.isEmpty, port.allSatisfy(\.isNumber) { return nil }
        return String(scheme)
    }

    /// A host a browser can reach: a domain name with a dot, an IP address, or "localhost".
    private static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, !host.hasPrefix("."), !host.hasSuffix("."), !host.contains("..") else { return false }
        if host.lowercased() == "localhost" { return true }
        // IPv6 literals ("[::1]") arrive without their brackets.
        if host.contains(":") { return host.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." } }
        return host.contains(".")
    }
}
