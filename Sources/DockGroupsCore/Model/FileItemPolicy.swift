import Foundation

/// Why a location can't be a file or folder item. A group opens what its items point to, and a
/// groups file or backup is something anyone can hand over, so a file item never runs code: apps
/// are added as apps, and programs, scripts, installers and location files aren't added at all.
public enum FileItemRefusal: LocalizedError, Equatable, Sendable {
    /// An executable, script, installer, location or alias file, or a system extension.
    case program(name: String)
    /// An app bundle: it's added as an app instead, never as a file.
    case application(name: String)

    public var name: String {
        switch self {
        case .program(let name), .application(let name): return name
        }
    }

    public var errorDescription: String? {
        Localization.format("core.item.error.program", "“%@” is a program or script, so it can't be added as a file.", name)
    }
}

/// What a file or folder is, as the file system describes it (symbolic links followed).
public struct ItemTypeInfo: Equatable, Sendable {
    /// The uniform type identifiers of the item, its supertypes included.
    public var typeIdentifiers: Set<String>
    public var isDirectory: Bool
    /// A directory shown as a single file, such as an `.rtfd` document or an app bundle.
    public var isPackage: Bool

    public init(typeIdentifiers: Set<String>, isDirectory: Bool, isPackage: Bool) {
        self.typeIdentifiers = typeIdentifiers
        self.isDirectory = isDirectory
        self.isPackage = isPackage
    }

    /// The kind of item this is: a plain folder, or a file (a document package included).
    public var itemKind: AppReference.Kind {
        isDirectory && !isPackage ? .folder : .file
    }
}

/// What a file or folder item may point to.
public enum FileItemPolicy {
    /// Extensions refused by name alone, without looking at the disk (a backup's items may not
    /// exist on this Mac): apps and bundles, scripts and programs, installers, profiles, location
    /// files and system extensions.
    public static let refusedExtensions: Set<String> = [
        "app", "command", "tool", "terminal", "sh", "bash", "zsh", "csh", "tcsh", "ksh", "fish",
        "py", "pyw", "pl", "rb", "jar", "workflow", "action", "scpt", "scptd", "applescript",
        "fileloc", "inetloc", "webloc", "pkg", "mpkg", "mobileconfig", "prefpane", "saver",
        "qlgenerator", "kext", "plugin", "bundle", "framework", "xpc", "osax",
        "appex", "systemextension", "dext", "mdimporter",
    ]

    /// Types refused when the item is checked on disk, as it's added and again before it's opened.
    /// Each covers the types that conform to it: `public.executable` includes apps and Unix
    /// executables, `public.script` shell, Python, Ruby, AppleScript and `.command` files, and
    /// `com.apple.internet-location` the `.webloc`, `.inetloc` and `.fileloc` location files. An
    /// alias file opens what it points to, unchecked, so it's refused too.
    public static let refusedTypeIdentifiers: Set<String> = [
        "public.executable",
        "public.script",
        "com.apple.application-bundle",
        "com.apple.installer-package-archive",
        "com.apple.internet-location",
        "com.apple.web-internet-location",
        "com.apple.alias-file",
    ]

    /// The refusal for the location `url` judged by its name alone, or `nil` when the name is fine.
    public static func refusal(byName url: URL) -> FileItemRefusal? {
        let fileExtension = url.pathExtension.lowercased()
        let name = FileLocation.defaultName(for: url)
        if fileExtension == "app" { return .application(name: name) }
        return refusedExtensions.contains(fileExtension) ? .program(name: name) : nil
    }

    /// The refusal for an item of type `info`, or `nil` when it may be opened as a file or folder.
    public static func refusal(for info: ItemTypeInfo, name: String) -> FileItemRefusal? {
        if info.typeIdentifiers.contains("com.apple.application-bundle") || info.typeIdentifiers.contains("com.apple.application") {
            return .application(name: name)
        }
        return info.typeIdentifiers.isDisjoint(with: refusedTypeIdentifiers) ? nil : .program(name: name)
    }

    /// Whether a file or folder item can be kept, judged by its identity alone, without looking
    /// at the disk: its location is valid and in its kind's form (`FileLocation.isValidIdentity`)
    /// and its name isn't refused. Always `true` for apps and websites.
    public static func acceptsByIdentity(_ item: GroupItem) -> Bool {
        guard item.kind.isFileSystemItem else { return true }
        guard FileLocation.isValidIdentity(item.bundleIdentifier, kind: item.kind), let url = item.fileURL else { return false }
        return refusal(byName: url) == nil
    }
}
