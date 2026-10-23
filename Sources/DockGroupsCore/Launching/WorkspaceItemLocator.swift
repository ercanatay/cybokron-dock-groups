import AppKit
import UniformTypeIdentifiers

/// `ItemLocating` backed by LaunchServices for apps and the file system for files and folders.
///
/// Each check is one lookup, made when it's asked for: nothing is watched or polled, and a file's
/// contents are never read.
@MainActor
public final class WorkspaceItemLocator: ItemLocating {
    private let workspace: NSWorkspace
    private let fileSystem: FileSystemProbing

    public init(workspace: NSWorkspace = .shared, fileSystem: FileSystemProbing = SystemFileSystemProbe()) {
        self.workspace = workspace
        self.fileSystem = fileSystem
    }

    public func presence(of item: GroupItem) -> ItemPresence {
        switch item.kind {
        case .website:
            return .online
        case .application:
            return item.resolvedURL(workspace: workspace).map(ItemPresence.available) ?? .missing
        case .file, .folder:
            guard let url = item.fileURL else { return .missing }
            let resolved = fileSystem.resolvingSymbolicLinks(in: url)
            do {
                let info = try fileSystem.typeInfo(at: resolved)
                return info.itemKind == item.kind ? .available(resolved) : .missing
            } catch where Self.meansNotThere(error) {
                return unmountedVolume(of: url).map { .volumeUnavailable(name: $0) } ?? .missing
            } catch {
                return .unverified
            }
        }
    }

    public func typeInfo(at url: URL) -> ItemTypeInfo? {
        try? fileSystem.typeInfo(at: fileSystem.resolvingSymbolicLinks(in: url))
    }

    /// The name of the volume `url` is on when that volume isn't connected: its location is
    /// "/Volumes/<name>/…" and "/Volumes/<name>" isn't there.
    private func unmountedVolume(of url: URL) -> String? {
        let components = url.standardizedFileURL.pathComponents
        guard components.count > 3, components[1] == "Volumes" else { return nil }
        let name = components[2]
        return fileSystem.itemExists(atPath: "/Volumes/\(name)") ? nil : name
    }

    /// Whether a file system error says there's nothing at the location (rather than that the app
    /// wasn't allowed to look, or anything else that went wrong).
    nonisolated static func meansNotThere(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain,
           [CocoaError.fileReadNoSuchFile.rawValue, CocoaError.fileNoSuchFile.rawValue].contains(error.code) {
            return true
        }
        let posix = error.domain == NSPOSIXErrorDomain ? error : error.userInfo[NSUnderlyingErrorKey] as? NSError
        guard let posix, posix.domain == NSPOSIXErrorDomain else { return false }
        return [ENOENT, ENOTDIR, ELOOP, ENAMETOOLONG].contains(Int32(posix.code))
    }
}

/// `FileSystemProbing` with `FileManager` and URL resource values: the type comes from the
/// file system's metadata, never from the file's contents.
public struct SystemFileSystemProbe: FileSystemProbing {
    public init() {}

    public func resolvingSymbolicLinks(in url: URL) -> URL {
        url.resolvingSymlinksInPath()
    }

    public func typeInfo(at url: URL) throws -> ItemTypeInfo {
        var url = url
        url.removeAllCachedResourceValues()
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .contentTypeKey])
        let type = values.contentType
        return ItemTypeInfo(
            typeIdentifiers: Set((type.map { [$0] + $0.supertypes } ?? []).map(\.identifier)),
            isDirectory: values.isDirectory ?? false,
            isPackage: values.isPackage ?? false
        )
    }

    public func itemExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}
