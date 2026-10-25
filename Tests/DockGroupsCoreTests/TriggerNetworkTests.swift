import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Triggers: Wi-Fi, Ethernet and Location")
struct TriggerNetworkTests {
    private static let state = WiFiInterfaceState(isPoweredOn: true, isAssociated: true, networkName: "Office")

    @Test func withoutLocationAccessTheNetworkIsUnknownNeverNotConnected() {
        for authorization in LocationAuthorization.allCases where authorization != .allowed {
            #expect(WiFiReading(interface: Self.state, authorization: authorization) == .unknown, "\(authorization)")
            let off = WiFiInterfaceState(isPoweredOn: false, isAssociated: false, networkName: nil)
            #expect(WiFiReading(interface: off, authorization: authorization) == .unknown, "\(authorization)")
        }
    }

    @Test func withLocationAccessTheInterfaceDecides() {
        #expect(WiFiReading(interface: Self.state, authorization: .allowed) == .connected(WiFiNetworkName(stored: "Office")))
        #expect(WiFiReading(interface: .init(isPoweredOn: false, isAssociated: false, networkName: nil), authorization: .allowed) == .notConnected)
        #expect(WiFiReading(interface: .init(isPoweredOn: true, isAssociated: false, networkName: nil), authorization: .allowed) == .notConnected)
        // Joined, but macOS withholds the name: unknown.
        #expect(WiFiReading(interface: .init(isPoweredOn: true, isAssociated: true, networkName: nil), authorization: .allowed) == .unknown)
        #expect(WiFiReading(interface: .init(isPoweredOn: true, isAssociated: true, networkName: ""), authorization: .allowed) == .unknown)
        // No Wi-Fi interface to read.
        #expect(WiFiReading(interface: nil, authorization: .allowed) == .unknown)
    }

    @Test func onlyAllowedShowsNetworkNames() {
        #expect(LocationAuthorization.allCases.filter(\.allowsNetworkNames) == [.allowed])
    }

    @Test func draftsOfWiFiAndEthernetRoundTrip() throws {
        var draft = TriggerDraft(calendar: Calendar(identifier: .gregorian))
        draft.wifiName = "Office"
        draft.setWhen(.change(.wifiJoins))
        #expect(draft.event == .condition(.wifi(WiFiNetworkName(stored: "Office")), edge: .starts))
        #expect(draft.isValid)
        #expect(draft.when.change?.needsLocation == true)
        draft.wifiName = ""
        #expect(!draft.isValid)
        draft.setWhen(.change(.ethernetDisconnects))
        #expect(draft.event == .condition(.ethernet, edge: .ends))
        #expect(draft.isValid)
        #expect(draft.when.change?.needsLocation == false)
        #expect(draft.when.change?.isAboutDisplays == false)
    }

    @Test func theEditorOffersNoVPN() {
        let offered = TriggerDraft.When.offered.compactMap(\.change)
        #expect(offered.contains(.wifiJoins) && offered.contains(.ethernetConnects))
        #expect(offered.count == TriggerDraft.Change.allCases.count)
    }

    @Test func onlyWiFiTriggersNeedLocation() {
        #expect(TriggerEvent.condition(.wifi(WiFiNetworkName(stored: "Office")), edge: .starts).needsLocation)
        #expect(!TriggerEvent.condition(.ethernet, edge: .starts).needsLocation)
        #expect(!TriggerEvent.login.needsLocation)
    }

    @Test func locationEntitlementAndPurposeAreSigned() throws {
        let entitlements = LocalizationTests.resources.appending(path: "CybokronDockGroups.entitlements")
        let plist = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: entitlements), format: nil) as? [String: Any])
        #expect(plist[LocationPurpose.entitlement] as? Bool == true)
        let info = LocalizationTests.resources.appending(path: "Info.plist")
        let infoPlist = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: Any])
        #expect(infoPlist[LocationPurpose.infoPlistKey] as? String == LocationPurpose.infoPlistEntries[LocationPurpose.infoPlistKey])
    }

    @MainActor @Test func ethernetSignalsReachTheRules() async {
        let rule = GroupTrigger.on(.condition(.ethernet, edge: .starts), group: TriggerRig.work)
        let rig = TriggerRig([rule])
        await rig.send(.network(NetworkReading(usesEthernet: false)))
        await rig.send(.network(NetworkReading(usesEthernet: true)))
        #expect(rig.handler.calls.contains { $0.hasPrefix("start:Work") })
    }
}
