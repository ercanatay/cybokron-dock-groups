import Foundation
@testable import DockGroupsCore

/// An `ItemLocating` that answers from tables and counts the questions: presences by normalized
/// identity (everything else is missing; websites are online), type infos by path.
@MainActor
final class ScriptedLocator: ItemLocating {
    var presences: [String: ItemPresence] = [:]
    var typeInfos: [String: ItemTypeInfo] = [:]
    private(set) var presenceChecks: [String] = []
    private(set) var typeInfoChecks: [String] = []

    func set(_ presence: ItemPresence, for item: GroupItem) {
        presences[item.normalizedBundleIdentifier] = presence
    }

    func presence(of item: GroupItem) -> ItemPresence {
        presenceChecks.append(item.bundleIdentifier)
        if item.isWebsite { return .online }
        return presences[item.normalizedBundleIdentifier] ?? .missing
    }

    func typeInfo(at url: URL) -> ItemTypeInfo? {
        typeInfoChecks.append(url.path)
        return typeInfos[url.standardizedFileURL.path]
    }
}

/// Groups kept in memory, saves counted.
final class MemoryGroupPersistence: GroupPersisting {
    private(set) var saveCount = 0
    private var saved: [DockGroup] = []

    func loadGroups() throws -> [DockGroup] { saved }

    func saveGroups(_ groups: [DockGroup]) throws {
        saved = groups
        saveCount += 1
    }

    func preserveUnreadableData() throws -> URL? { nil }
}

extension ItemTypeInfo {
    static let pdf = ItemTypeInfo(typeIdentifiers: ["com.adobe.pdf", "public.data", "public.item", "public.content"], isDirectory: false, isPackage: false)
    static let plainFolder = ItemTypeInfo(typeIdentifiers: ["public.folder", "public.directory", "public.item"], isDirectory: true, isPackage: false)
    static let rtfd = ItemTypeInfo(typeIdentifiers: ["com.apple.rtfd", "com.apple.package", "public.directory", "public.item"], isDirectory: true, isPackage: true)
    static let appBundle = ItemTypeInfo(
        typeIdentifiers: ["com.apple.application-bundle", "com.apple.application", "public.executable", "com.apple.package", "public.directory"],
        isDirectory: true,
        isPackage: true
    )
    static let shellScript = ItemTypeInfo(typeIdentifiers: ["public.shell-script", "public.script", "public.source-code", "public.data"], isDirectory: false, isPackage: false)
}
