import Foundation
import Testing
@testable import DockGroupsCore

@Suite("Group model coding")
struct DockGroupCodingTests {
    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    @Test func fullyPopulatedGroupSurvivesRoundTrip() throws {
        let group = DockGroup(
            name: "Work",
            emoji: "💼",
            apps: [
                AppReference(bundleIdentifier: "com.apple.Safari", name: "Safari", path: "/Applications/Safari.app"),
                AppReference(bundleIdentifier: "com.apple.mail", name: "Mail"),
            ],
            tile: TileAppearance(
                kind: .grid,
                backgroundStyle: .glass,
                backgroundColor: TileColor(normalizedRed: 0.1, green: 0.5, blue: 0.9)
            ),
            isPinned: true,
            popup: PopupOverrides(columns: .fixed(4), maxRows: 3, showsTitles: false, anchor: .dockIcon)
        )
        #expect(try roundTrip(group) == group)
    }

    @Test func autoColumnsSurviveRoundTrip() throws {
        let popup = PopupOverrides(columns: .auto)
        #expect(try roundTrip(popup) == popup)
    }

    @Test func minimalRecordGetsDefaults() throws {
        let json = #"{ "id": "8D9A5E2C-6B1F-4F7E-9C3A-2B4D6E8F0A1B", "name": "Minimal" }"#
        let group = try JSONDecoder().decode(DockGroup.self, from: Data(json.utf8))
        #expect(group.name == "Minimal")
        #expect(group.emoji == DockGroup.defaultEmoji)
        #expect(group.apps.isEmpty)
        #expect(group.tile == TileAppearance())
        #expect(group.isPinned == false)
        #expect(group.popup.isEmpty)
    }

    @Test func unknownPreferenceValuesFallBackInsteadOfFailing() throws {
        let json = """
        {
          "id": "8D9A5E2C-6B1F-4F7E-9C3A-2B4D6E8F0A1B",
          "name": "Future",
          "isPinned": "yes",
          "tile": { "kind": "hologram", "backgroundStyle": "glass", "backgroundColor": "not-a-color" },
          "popup": { "columns": 99, "maxRows": 0, "showsTitles": true, "anchor": "moon" }
        }
        """
        let group = try JSONDecoder().decode(DockGroup.self, from: Data(json.utf8))
        #expect(group.isPinned == false)
        #expect(group.tile.kind == .emoji)
        #expect(group.tile.backgroundStyle == .glass)
        #expect(group.tile.backgroundColor == .defaultTileBackground)
        #expect(group.popup == PopupOverrides(showsTitles: true))
    }

    @Test func missingIdentityIsAnError() {
        let json = #"{ "name": "No ID" }"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(DockGroup.self, from: Data(json.utf8))
        }
    }

    @Test func colorsUseHexStrings() throws {
        let color = try #require(TileColor(hex: "#2f6feb"))
        #expect(color == TileColor(red: 0x2F, green: 0x6F, blue: 0xEB))
        #expect(color.hexString == "#2F6FEB")
        #expect(TileColor(hex: "2F6FEB") == color)
        #expect(TileColor(hex: "#2F6FE") == nil)
        #expect(TileColor(hex: "#GGGGGG") == nil)
        let encoded = try JSONEncoder().encode([color])
        #expect(String(decoding: encoded, as: UTF8.self) == ##"["#2F6FEB"]"##)
    }

    @Test func colorComponentsAreClampedAndQuantized() {
        let color = TileColor(normalizedRed: -1, green: 2, blue: 0.5)
        #expect(color == TileColor(red: 0, green: 255, blue: 128))
    }

    @Test func sanitizing() {
        #expect(DockGroup.sanitizedName("  Work  ") == "Work")
        #expect(DockGroup.sanitizedName(" \n ") == nil)
        #expect(DockGroup.sanitizedEmoji("🗂️😀") == "😀")
        #expect(DockGroup.sanitizedEmoji(" 👩‍💻 ") == "👩‍💻")
        #expect(DockGroup.sanitizedEmoji("") == nil)
    }
}
