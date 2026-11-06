import Foundation
import Testing
@testable import DockGroupsCore

/// Links name a group by its identifier, so renaming it keeps its links working, and a link that
/// can't name exactly one active group opens none — never another group, never silently.
@MainActor
@Suite("Group links by identity")
struct GroupLinkIdentityTests {
    /// The group a link's text opens among the store's active groups, as the app resolves it.
    private func resolve(_ link: String, in store: GroupStore) throws -> GroupResolution {
        let url = try #require(URL(string: link))
        let token: String
        switch try #require(LinkCommand(url: url), "\(link)") {
        case .command(.showGroup(let t)), .command(.launchGroup(let t)), .command(.hideGroup(let t)),
             .command(.quitGroup(let t, _)), .command(.captureOpenApps(let t)), .command(.showGroupSettings(let t)):
            token = t
        case .switching(let command):
            token = command.group
        case .command(let other):
            Issue.record("\(link) names no group: \(other)")
            return .notFound
        }
        return GroupLookup.resolve(token, in: store.groups)
    }

    @Test func aLinkCopiedBeforeARenameOpensTheSameGroup() throws {
        let (store, _) = GroupStore.archiving()
        let work = store.addGroup(named: "Work")
        let links = (GroupInvocations.links(for: work) + GroupInvocations.switchingLinks(for: work) + [GroupInvocations.captureLink(for: work)]).map(\.text)

        #expect(store.renameGroup(work.id, to: "Office") == .renamed)
        // Another group takes the old name: the old links still open the renamed group.
        let newcomer = store.addGroup(named: "Work")
        for link in links {
            #expect(try resolve(link, in: store).group?.id == work.id, "\(link)")
        }
        #expect(try resolve(URLCommand.groupSettingsURL(for: work.id).absoluteString, in: store).group?.id == work.id)
        // Links copied now name the group by the same identifier.
        let office = try #require(store.group(withID: work.id))
        #expect(GroupInvocations.links(for: office)[0].text == "cybokrondockgroups://open/\(work.id.uuidString)/office")
        #expect(try resolve("cybokrondockgroups://open/work", in: store).group?.id == newcomer.id, "a name link names whoever has the name")
    }

    @Test func aLinkNamingTheOldNameFindsNothingAfterARename() throws {
        let (store, _) = GroupStore.archiving()
        let work = store.addGroup(named: "Work")
        let play = store.addGroup(named: "Play")
        #expect(store.renameGroup(work.id, to: "Office") == .renamed)

        for link in ["cybokrondockgroups://open/work", "cybokrondockgroups://launch/Work", "cybokrondockgroups://quit/work?mode=force", "cybokrondockgroups://start/work"] {
            let resolution = try resolve(link, in: store)
            #expect(resolution == .notFound, "\(link)")
            #expect(resolution.group == nil)
            #expect(resolution.problemMessage != nil, "the app tells the user")
        }
        // Not another group: the play group is never what a work link opens.
        let stored = try #require(store.group(withID: play.id))
        #expect(try resolve("cybokrondockgroups://open/play", in: store) == .found(stored))
    }

    @Test func aDeletedGroupsIdentifierLinkOpensNoOtherGroup() throws {
        let (store, _) = GroupStore.archiving()
        let work = store.addGroup(named: "Work")
        let link = GroupInvocations.links(for: work)[0].text
        store.deleteGroup(work.id)
        // A group named like the link's slug doesn't answer to it: the identifier decides.
        store.addGroup(named: "Work")
        #expect(try resolve(link, in: store) == .notFound)
    }

    @Test func anArchivedGroupsLinkFindsNothing() throws {
        let (store, _) = GroupStore.archiving()
        let work = store.addGroup(named: "Work")
        let link = GroupInvocations.links(for: work)[0].text
        store.archiveGroup(work.id)
        #expect(try resolve(link, in: store) == .notFound)
        #expect(try resolve("cybokrondockgroups://open/work", in: store) == .notFound)
    }

    @Test func renamingToAnotherGroupsNameIsRefused() throws {
        let (store, persistence) = GroupStore.archiving()
        let work = store.addGroup(named: "Work")
        let home = store.addGroup(named: "Home")
        let saves = persistence.saveCount

        #expect(store.renameGroup(home.id, to: "Work") == .nameTaken(by: work.id))
        #expect(store.renameGroup(home.id, to: "  WORK ") == .nameTaken(by: work.id))
        #expect(store.nameOwner(of: "work", except: home.id)?.id == work.id)
        #expect(store.nameOwner(of: "Work", except: work.id) == nil, "a group's own name isn't taken")
        #expect(store.nameOwner(of: "  ", except: home.id) == nil)
        // Changing the case of its own name is fine.
        #expect(store.renameGroup(work.id, to: "WORK") == .renamed)
        // Setting the name another way is refused the same way.
        store.updateGroup(home.id) { $0.name = "work" }
        #expect(store.group(withID: home.id)?.name == "Home")
        #expect(persistence.saveCount == saves + 1, "only the case change was saved")

        #expect(GroupRename.nameTakenMessage(otherGroupName: "WORK") == "Another group is already named “WORK”. Choose a different name.")
        #expect(GroupRename.renamed.succeeded && GroupRename.unchanged.succeeded)
        #expect(!GroupRename.nameTaken(by: work.id).succeeded && !GroupRename.blankName.succeeded && !GroupRename.unknownGroup.succeeded)
    }

    /// Renaming can't make two groups share a name any more, but older data, a name given when
    /// adding, a restore or a slug shared by different names still can: a link by that name opens
    /// none of them. Their identifier links still work.
    @Test func anAmbiguousNameOpensNoGroup() throws {
        let (store, _) = GroupStore.archiving()
        let first = store.addGroup(named: "Dev Ops")
        let second = store.addGroup(named: "Dev-Ops")
        let resolution = try resolve("cybokrondockgroups://open/dev-ops", in: store)
        #expect(resolution == .ambiguous(name: "dev-ops", matches: [first.id, second.id]))
        #expect(resolution.group == nil)
        #expect(resolution.problemMessage?.contains("“dev-ops”") == true)
        #expect(try resolve("cybokrondockgroups://settings/group/Dev%20Ops", in: store).group == nil)
        #expect(try resolve(GroupInvocations.links(for: second)[0].text, in: store) == .found(second))
        #expect(try resolve(GroupInvocations.links(for: first)[0].text, in: store) == .found(first))
        #expect(GroupSettingsDestination(request: "dev-ops", current: first.id, in: store.groups) == .unmatched(keeping: first.id))
    }

    /// The app tells the user when a link opens no group, instead of beeping; Siri and Shortcuts
    /// keep their own errors (`GroupIntentSupport`).
    @Test func theAppShowsAnAlertForALinkThatOpensNoGroup() throws {
        let sources = LocalizationTests.root.appending(components: "Sources", "CybokronDockGroups")
        let app = try String(contentsOf: sources.appending(components: "App", "AppDelegate.swift"), encoding: .utf8)
        let lookup = try #require(app.range(of: "private func group(named name: String) -> DockGroup? {"))
        let body = String(app[lookup.upperBound...].prefix(900))
        #expect(body.contains("GroupLookup.resolve(name, in: store.groups)"))
        #expect(body.contains("GroupLinkProblemAlert.present(resolution)"))
        #expect(!body.contains("NSSound.beep()"))
        #expect(app.contains("GroupLinkProblemAlert.present(GroupLookup.resolve(name, in: store.groups))"), "the settings link too")
        #expect(!app.contains("GroupLookup.group(matching:"), "every link resolves strictly")

        let alert = try String(contentsOf: sources.appending(components: "Support", "GroupLinkProblemAlert.swift"), encoding: .utf8)
        #expect(alert.contains("guard let message = resolution.problemMessage else { return }"))
        #expect(alert.contains("alert.runModal()"))
        #expect(alert.contains("CommandThrottle.urlCooldown"), "links in a burst can't stack alerts")
    }
}
