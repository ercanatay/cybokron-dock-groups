import Foundation
@testable import DockGroupsCore

/// Keeps templates in memory and counts the saves; can fail to load, to move a file aside, or to
/// save.
final class MemoryTemplatePersistence: TemplatePersisting {
    struct Failure: Error {}

    private(set) var saveCount = 0
    private(set) var saved: [GroupTemplate]
    var failsToLoad = false
    var failsToMoveAside = false
    var failsToSave = false
    private(set) var movedAside = false

    init(_ templates: [GroupTemplate] = []) {
        saved = templates
    }

    func loadTemplates() throws -> [GroupTemplate] {
        if failsToLoad { throw Failure() }
        return saved
    }

    func saveTemplates(_ templates: [GroupTemplate]) throws {
        if failsToSave { throw Failure() }
        saved = templates
        saveCount += 1
    }

    func preserveUnreadableData() throws -> URL? {
        if failsToMoveAside { throw Failure() }
        movedAside = true
        return URL(fileURLWithPath: "/tmp/templates.unreadable.json")
    }
}

extension GroupTemplate {
    /// A template of an empty group with this name.
    static func named(_ name: String, id: UUID = UUID()) -> GroupTemplate {
        GroupTemplate(saving: DockGroup(name: name), id: id, at: Date(timeIntervalSince1970: 1_793_300_000))
    }
}
