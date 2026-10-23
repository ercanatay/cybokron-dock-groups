import Foundation

/// The identities of file and folder items (`AppReference.Kind.file` / `.folder`): the `file://`
/// URL of the location, a folder's ending in "/".
public enum FileLocation {
    /// The identity of the item at `url`: the location standardized ("." and ".." removed; symbolic
    /// links are *not* resolved, so the location the user chose is kept), as a `file://` URL string.
    /// A folder's ends in "/" ("file:///Users/me/Projects/"), a file's doesn't
    /// ("file:///Users/me/Q3%20Report.pdf").
    public static func identity(for url: URL, kind: AppReference.Kind) -> String {
        let path = url.standardizedFileURL.path
        return URL(fileURLWithPath: path, isDirectory: kind == .folder).absoluteString
    }

    /// The location `identity` names, or `nil` unless all of these hold: the scheme is `file`; there
    /// is no host (or it's "localhost"), user, password, query or fragment; the path is absolute,
    /// with no "." or ".." components, no NUL characters (encoded or not) or encoded "/", and
    /// shorter than `PATH_MAX` bytes. `identity(for:kind:)` never writes "%00" or "%2F" (a "%" of a
    /// name is written "%25"), so only a crafted identity has them.
    public static func url(fromIdentity identity: String) -> URL? {
        guard let components = URLComponents(string: identity),
              components.scheme?.lowercased() == "file",
              components.host.map({ $0.isEmpty || $0.lowercased() == "localhost" }) ?? true,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              !["%00", "%2f"].contains(where: components.percentEncodedPath.lowercased().contains),
              isAbsoluteLocation(components.path)
        else { return nil }
        return URL(fileURLWithPath: components.path, isDirectory: identity.hasSuffix("/"))
    }

    /// Whether `identity` names a location (`url(fromIdentity:)`) in the form of `kind`: a folder's
    /// identity ends in "/", a file's doesn't. Always `false` for apps and websites.
    public static func isValidIdentity(_ identity: String, kind: AppReference.Kind) -> Bool {
        guard kind.isFileSystemItem, url(fromIdentity: identity) != nil else { return false }
        return identity.hasSuffix("/") == (kind == .folder)
    }

    /// Whether a saved identity is meant as a file or folder location (it may still be invalid):
    /// bundle identifiers can't contain ":", and app locations and web addresses start differently.
    public static func looksLikeIdentity(_ identifier: String) -> Bool {
        identifier.lowercased().hasPrefix("file:")
    }

    /// The name a file or folder item gets when none is given: the last component of its location
    /// ("Q3 Report.pdf", "Projects"), or "/" for the root folder.
    public static func defaultName(for url: URL) -> String {
        let name = url.standardizedFileURL.lastPathComponent
        return name.isEmpty ? "/" : name
    }

    /// Whether `path` is an absolute location without `.` or `..` components, NUL characters or
    /// more than `PATH_MAX` bytes: the rules every location in a groups file or backup must meet.
    public static func isAbsoluteLocation(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count < Int(PATH_MAX) else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: true).contains { $0 == "." || $0 == ".." }
    }

    /// Whether `path` can be where an app bundle is: an absolute location (`isAbsoluteLocation`)
    /// of a `.app` folder.
    public static func isAppBundlePath(_ path: String) -> Bool {
        guard isAbsoluteLocation(path), let last = path.split(separator: "/").last else { return false }
        return last.count > 4 && last.lowercased().hasSuffix(".app")
    }
}
