import Foundation
import Testing
@testable import CybokronDockGroups
@testable import DockGroupsCore

/// Siri and Shortcuts name a group by identifier (`GroupEntity`), unaffected by the link changes:
/// a renamed group is still found, an archived one says so, and an unknown one gives its own error.
@MainActor
@Suite("Intents: resolving a group", .serialized)
struct GroupIntentResolutionTests {
    /// Answers with fixed groups; nothing else is ever called.
    private final class Handler: GroupIntentHandling {
        var groups: [DockGroup]
        var archivedGroups: [ArchivedGroup]

        init(groups: [DockGroup], archivedGroups: [ArchivedGroup]) {
            self.groups = groups
            self.archivedGroups = archivedGroups
        }

        func showPopup(forGroup id: DockGroup.ID) {}
        func launchAll(_ group: DockGroup) async -> LaunchReport { LaunchReport(groupName: group.name, entries: []) }
        func quitAll(_ group: DockGroup, mode: QuitMode, confirm: (QuitConfirmation) async throws -> Void) async throws -> QuitReport {
            QuitReport(groupName: group.name, mode: mode, quit: [], refused: [])
        }
        func start(_ group: DockGroup, confirm: @escaping (TransitionConfirmation) async throws -> Void) async throws -> TransitionReport {
            throw CancellationError()
        }
        func finish(_ group: DockGroup, confirm: @escaping (TransitionConfirmation) async throws -> Void) async throws -> TransitionReport {
            throw CancellationError()
        }
        func captureNewGroup(named name: String?, onlyAppsWithWindows: Bool?) -> CaptureOutcome { fatalError("not used") }
        func captureOpenApps(into group: DockGroup, onlyAppsWithWindows: Bool?) -> CaptureOutcome { fatalError("not used") }
    }

    private func withHandler<T>(_ handler: Handler, _ body: () throws -> T) rethrows -> T {
        let previous = GroupIntentSupport.handler
        GroupIntentSupport.handler = handler
        defer { GroupIntentSupport.handler = previous }
        return try body()
    }

    @Test func aRenamedGroupIsFoundByItsIdentifier() throws {
        let saved = DockGroup(name: "Work")
        var renamed = saved
        renamed.name = "Office"
        let handler = Handler(groups: [DockGroup(name: "Work"), renamed], archivedGroups: [])
        let (_, group) = try withHandler(handler) { try GroupIntentSupport.resolve(GroupEntity(group: saved), for: "Test") }
        #expect(group.id == saved.id)
        #expect(group.name == "Office")
    }

    @Test func anUnknownGroupIsNotFound() {
        let gone = DockGroup(name: "Gone")
        let handler = Handler(groups: [DockGroup(name: "Gone")], archivedGroups: [])
        do {
            _ = try withHandler(handler) { try GroupIntentSupport.resolve(GroupEntity(group: gone), for: "Test") }
            Issue.record("a group with another identifier was found")
        } catch GroupIntentError.groupNotFound(let name) {
            #expect(name == "Gone")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func anArchivedGroupSaysItIsArchived() {
        let work = DockGroup(name: "Work")
        var archived = work
        archived.name = "Old Work"
        let handler = Handler(groups: [], archivedGroups: [ArchivedGroup(group: archived, archivedAt: nil)])
        do {
            _ = try withHandler(handler) { try GroupIntentSupport.resolve(GroupEntity(group: work), for: "Test") }
            Issue.record("an archived group was used")
        } catch GroupIntentError.groupArchived(let name) {
            #expect(name == "Old Work", "its name as archived")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func errorsKeepTheirOwnMessages() {
        #expect(String(localized: GroupIntentError.groupNotFound(name: "Work").localizedStringResource)
            == "There's no group named “Work”. It may have been renamed or deleted.")
        #expect(String(localized: GroupIntentError.groupArchived(name: "Work").localizedStringResource)
            == "“Work” is archived. Restore it in Cybokron Dock Groups to use it.")
    }
}
