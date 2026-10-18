import AppKit

/// An item of a group: usually an app, identified by its bundle identifier — or, for an app bundle
/// that has none (a script wrapper, for example), by its location. It can also be a website
/// (`kind == .website`), identified by its web address.
public struct AppReference: Identifiable, Hashable, Sendable {
    /// What a group item is.
    public enum Kind: String, Codable, Sendable {
        case application
        /// A web link, opened in the default browser.
        case website
    }

    /// The app's bundle identifier. An app without one is identified by the absolute path of its
    /// bundle instead (see `isIdentifiedByPath`), and a website by its address as
    /// `WebsiteAddress.parse` normalizes it; bundle identifiers can't contain "/" or ":", so the
    /// three never collide.
    public var bundleIdentifier: String
    /// Display name captured when the app was added, shown when the app can't be found.
    public var name: String
    /// Where the app was when it was added. Only a fallback: a LaunchServices lookup by bundle
    /// identifier wins, so apps that were moved or updated keep working.
    public var path: String?
    /// An app, or a website. Items saved before websites existed are apps.
    public private(set) var kind: Kind

    public var id: String { bundleIdentifier }

    public init(bundleIdentifier: String, name: String, path: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.path = path
        kind = .application
    }

    /// A website item for `url`, which should already be checked (`WebsiteAddress.parse`). Without a
    /// usable `name` it's named after the host ("github.com").
    public init(websiteURL url: URL, name: String? = nil) {
        bundleIdentifier = url.absoluteString
        self.name = name.flatMap(DockGroup.sanitizedName) ?? WebsiteAddress.defaultName(for: url)
        path = nil
        kind = .website
    }

    /// Reads the identity of the `.app` bundle at `applicationURL`. A bundle without a bundle
    /// identifier is identified by its location, with symbolic links resolved.
    public init(applicationURL: URL) throws {
        let path = applicationURL.standardizedFileURL.path
        guard applicationURL.pathExtension.lowercased() == "app", let bundle = Bundle(url: applicationURL) else {
            throw AppReferenceError.notAnApplication(path: path)
        }
        let bundleIdentifier = bundle.bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 }
        let infoName = ["CFBundleDisplayName", "CFBundleName"]
            .lazy
            .compactMap { bundle.object(forInfoDictionaryKey: $0) as? String }
            .first { !$0.isEmpty }
        self.init(
            bundleIdentifier: bundleIdentifier ?? applicationURL.resolvingSymlinksInPath().standardizedFileURL.path,
            name: infoName ?? applicationURL.deletingPathExtension().lastPathComponent,
            path: path
        )
    }

    /// Whether the app has no bundle identifier and `bundleIdentifier` holds its location instead.
    public var isIdentifiedByPath: Bool { kind == .application && bundleIdentifier.hasPrefix("/") }

    /// Whether this is a website rather than an app.
    public var isWebsite: Bool { kind == .website }

    /// The website's address; `nil` for apps.
    public var websiteURL: URL? { isWebsite ? URL(string: bundleIdentifier) : nil }

    /// How the item appears in logs: an app by its identity, a website by its host only, so the
    /// addresses the user saved don't end up in the system log.
    public var logIdentity: String {
        guard isWebsite else { return bundleIdentifier }
        return "website \(websiteURL?.host() ?? "?")"
    }

    /// LaunchServices treats bundle identifiers case-insensitively; so do group membership checks.
    /// Locations are compared the same way, as APFS volumes ignore case by default.
    public var normalizedBundleIdentifier: String { bundleIdentifier.lowercased() }

    /// Where the app currently lives: the LaunchServices location for its bundle identifier, or the
    /// path it was added from if that still exists. `nil` when the app isn't on this Mac. Apps
    /// identified by path are only looked for there. Always `nil` for websites: they aren't on disk.
    public func resolvedURL(workspace: NSWorkspace = .shared) -> URL? {
        guard !isWebsite else { return nil }
        if !isIdentifiedByPath, let url = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return url
        }
        if let location = path ?? (isIdentifiedByPath ? bundleIdentifier : nil),
           FileManager.default.fileExists(atPath: location) {
            return URL(fileURLWithPath: location, isDirectory: true)
        }
        return nil
    }
}

// MARK: - Codable

extension AppReference: Codable {
    private enum CodingKeys: String, CodingKey {
        case bundleIdentifier, name, path, kind, url
    }

    /// Items without a `kind` are apps, as everything saved before websites existed. A website is
    /// recognized by its address too, so one that went through a version without websites (which
    /// keeps only the identifier and name) comes back as a website. A website whose address can't
    /// be read, or an item of a kind this version doesn't know, is kept as an app that can't be
    /// found, so it stays visible and removable instead of making the whole group unreadable.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let identifier = try container.decode(String.self, forKey: .bundleIdentifier)
        name = try container.decode(String.self, forKey: .name)
        path = container.decodeLeniently(String.self, forKey: .path)
        let rawKind = container.decodeLeniently(String.self, forKey: .kind)
        let isWebsite = rawKind == Kind.website.rawValue || (rawKind == nil && WebsiteAddress.looksLikeAddress(identifier))
        let address = isWebsite
            ? (container.decodeLeniently(String.self, forKey: .url) ?? identifier)
            : nil
        if let address, let url = try? WebsiteAddress.parse(address) {
            bundleIdentifier = url.absoluteString
            path = nil
            kind = .website
        } else {
            bundleIdentifier = identifier
            kind = .application
        }
    }

    /// Apps are written as before (no `kind`); websites add `kind` and `url`.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(path, forKey: .path)
        if isWebsite {
            try container.encode(kind, forKey: .kind)
            try container.encode(bundleIdentifier, forKey: .url)
        }
    }
}

public enum AppReferenceError: LocalizedError, Equatable, Sendable {
    case notAnApplication(path: String)

    public var errorDescription: String? {
        switch self {
        case .notAnApplication(let path):
            return "“\((path as NSString).lastPathComponent)” isn't an app."
        }
    }
}
