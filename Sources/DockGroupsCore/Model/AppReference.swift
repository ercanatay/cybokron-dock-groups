import AppKit

/// An item of a group: usually an app, identified by its bundle identifier — or, for an app bundle
/// that has none (a script wrapper, for example), by its location. It can also be a website
/// (`kind == .website`), identified by its web address, or a file or folder on this Mac
/// (`kind == .file` / `.folder`), identified by its location as a `file://` URL.
///
/// `GroupItem` is the same type; new code uses that name.
public struct AppReference: Identifiable, Hashable, Sendable {
    /// What a group item is.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case application
        /// A web link, opened in the default browser.
        case website
        /// A document, or a document package such as `.rtfd` / `.pages`, opened with its default app.
        case file
        /// A plain folder (not a package), opened in the default file viewer.
        case folder
    }

    /// The item's identity (the JSON key keeps the name `bundleIdentifier`):
    /// - application: its bundle identifier, or the absolute path of its bundle ("/…") when it has
    ///   none (see `isIdentifiedByPath`);
    /// - website: its address as `WebsiteAddress.parse` normalizes it;
    /// - file: the `file://` URL of its location ("file:///Users/me/Q3%20Report.pdf");
    /// - folder: the same, always ending in "/" ("file:///Users/me/Projects/").
    ///
    /// Bundle identifiers can't contain "/" or ":", so the "/", "http(s)://" and "file://" forms
    /// never collide with them or with each other.
    public var bundleIdentifier: String
    /// The name captured when the item was added: an app's display name, a website's name, or a
    /// file's or folder's name. Shown when the item has no alias, and when it can't be found.
    public var name: String
    /// Apps only: where the app was when it was added. Only a fallback: a LaunchServices lookup by
    /// bundle identifier wins, so apps that were moved or updated keep working. Files and folders
    /// never write it: a version without them would take it for an app's location.
    public var path: String?
    /// An app, a website, a file or a folder. Items saved before websites existed are apps.
    public private(set) var kind: Kind
    /// The item's alias, tags and task notes; empty for most items, and then not written.
    public var details: ItemDetails

    public var id: String { bundleIdentifier }

    public init(bundleIdentifier: String, name: String, path: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.path = path
        kind = .application
        details = ItemDetails()
    }

    /// A website item for `url`, which should already be checked (`WebsiteAddress.parse`). Without a
    /// usable `name` it's named after the host ("github.com").
    public init(websiteURL url: URL, name: String? = nil) {
        bundleIdentifier = url.absoluteString
        self.name = name.flatMap(DockGroup.sanitizedName) ?? WebsiteAddress.defaultName(for: url)
        path = nil
        kind = .website
        details = ItemDetails()
    }

    /// A file or folder item for the location `url`, which should already be classified (a plain
    /// folder is a `.folder`, a document or document package a `.file`) and checked
    /// (`FileItemPolicy`). Without a usable `name` it's named after the last path component.
    /// - Precondition: `kind` is `.file` or `.folder`.
    public init(fileURL url: URL, kind: Kind, name: String? = nil) {
        precondition(kind.isFileSystemItem, "A file item is a file or a folder, not \(kind)")
        bundleIdentifier = FileLocation.identity(for: url, kind: kind)
        self.name = name.flatMap(DockGroup.sanitizedName) ?? FileLocation.defaultName(for: url)
        path = nil
        self.kind = kind
        details = ItemDetails()
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

    /// The website's address; `nil` for other items.
    public var websiteURL: URL? { isWebsite ? URL(string: bundleIdentifier) : nil }

    /// The location of a file or folder item; `nil` for other items.
    public var fileURL: URL? { kind.isFileSystemItem ? FileLocation.url(fromIdentity: bundleIdentifier) : nil }

    /// What lists show: the alias when there is one, otherwise the name.
    public var displayName: String { details.alias ?? name }

    /// How the item appears in logs: an app by its identity, a website by its host only, and a file
    /// or folder by its kind and extension only ("file .pdf", "folder"), so the addresses and
    /// locations the user saved don't end up in the system log.
    public var logIdentity: String {
        switch kind {
        case .application:
            return bundleIdentifier
        case .website:
            return "website \(websiteURL?.host() ?? "?")"
        case .file:
            let fileExtension = fileURL?.pathExtension.lowercased() ?? ""
            return fileExtension.isEmpty ? "file" : "file .\(fileExtension)"
        case .folder:
            return "folder"
        }
    }

    /// LaunchServices treats bundle identifiers case-insensitively; so do group membership checks.
    /// Locations are compared the same way, as APFS volumes ignore case by default.
    public var normalizedBundleIdentifier: String { bundleIdentifier.lowercased() }

    /// Where the app currently lives: the LaunchServices location for its bundle identifier, or the
    /// path it was added from if that still exists. `nil` when the app isn't on this Mac. Apps
    /// identified by path are only looked for there. Always `nil` for websites, files and folders:
    /// they aren't apps (`WorkspaceItemLocator` finds files and folders).
    public func resolvedURL(workspace: NSWorkspace = .shared) -> URL? {
        guard kind == .application else { return nil }
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
        case bundleIdentifier, name, path, kind, url, alias, tags, notes
    }

    /// Items without a `kind` are apps, as everything saved before websites existed. A website is
    /// recognized by its address too, and a file or folder by its `file://` location (a folder's
    /// ends in "/"), so one that went through a version without them (which keeps only the
    /// identifier, name and location) comes back as what it was. A website whose address can't be
    /// read, a file or folder whose location can't be, or an item of a kind this version doesn't
    /// know, is kept as an app that can't be found, so it stays visible and removable instead of
    /// making the whole group unreadable. The alias, tags and task notes are each read on their own:
    /// an unreadable one is left empty.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let identifier = try container.decode(String.self, forKey: .bundleIdentifier)
        name = try container.decode(String.self, forKey: .name)
        path = container.decodeLeniently(String.self, forKey: .path)
        details = ItemDetails(
            alias: container.decodeLeniently(String.self, forKey: .alias),
            tags: container.decodeLeniently([String].self, forKey: .tags) ?? [],
            notes: container.decodeLeniently(String.self, forKey: .notes)
        )
        bundleIdentifier = identifier
        kind = .application
        let rawKind = container.decodeLeniently(String.self, forKey: .kind)
        if rawKind == Kind.website.rawValue || (rawKind == nil && WebsiteAddress.looksLikeAddress(identifier)) {
            let address = container.decodeLeniently(String.self, forKey: .url) ?? identifier
            if let url = try? WebsiteAddress.parse(address) {
                bundleIdentifier = url.absoluteString
                path = nil
                kind = .website
            }
        } else if let fileKind = Self.fileSystemKind(rawKind: rawKind, identifier: identifier) {
            // A file or folder never has an app's location, even a crafted one.
            path = nil
            if FileLocation.isValidIdentity(identifier, kind: fileKind) {
                kind = fileKind
            }
        }
    }

    /// The kind a saved file or folder item has: the saved one, or — without one — what its
    /// `file://` identity says. `nil` for other items.
    private static func fileSystemKind(rawKind: String?, identifier: String) -> Kind? {
        switch rawKind {
        case Kind.file.rawValue: return .file
        case Kind.folder.rawValue: return .folder
        case nil where FileLocation.looksLikeIdentity(identifier): return identifier.hasSuffix("/") ? .folder : .file
        default: return nil
        }
    }

    /// Apps are written as before (no `kind`); websites add `kind` and `url`, files and folders
    /// `kind` only. The alias, tags and task notes are written only when set.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(name, forKey: .name)
        switch kind {
        case .application:
            try container.encodeIfPresent(path, forKey: .path)
        case .website:
            try container.encode(kind, forKey: .kind)
            try container.encode(bundleIdentifier, forKey: .url)
        case .file, .folder:
            try container.encode(kind, forKey: .kind)
        }
        try container.encodeIfPresent(details.alias, forKey: .alias)
        if !details.tags.isEmpty {
            try container.encode(details.tags, forKey: .tags)
        }
        try container.encodeIfPresent(details.notes, forKey: .notes)
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
