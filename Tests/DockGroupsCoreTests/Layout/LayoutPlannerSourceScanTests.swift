import Foundation
import Testing

/// Source scans that keep window motion out of the layout core until the Accessibility gate in
/// `docs/design/window-layouts-and-cli-spec.md` §5 passes. They read this checkout's sources only.
struct LayoutPlannerSourceScanTests {
    static let layoutDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/DockGroupsCore/Layout", isDirectory: true)

    static let plannerFiles = [
        "LayoutWindowObservation.swift",
        "LayoutCapturePlanner.swift",
        "LayoutRestorePreviewPlanner.swift",
    ]

    static func layoutSources() throws -> [(name: String, text: String)] {
        let names = try FileManager.default.contentsOfDirectory(atPath: layoutDirectory.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        return try names.map { name in
            (name, try String(contentsOf: layoutDirectory.appendingPathComponent(name), encoding: .utf8))
        }
    }

    @Test func layoutCoreWritesNoWindowGeometry() throws {
        let sources = try Self.layoutSources()
        #expect(Set(Self.plannerFiles).isSubset(of: Set(sources.map(\.name))))
        let forbidden = [
            "AXUIElementSetAttributeValue",
            "kAXPositionAttribute",
            "kAXSizeAttribute",
            "AXValueCreate",
            "AXUIElementPerformAction",
        ]
        for source in sources {
            for token in forbidden {
                #expect(!source.text.contains(token), "\(source.name) mentions \(token)")
            }
        }
    }

    @Test func plannersHaveNoSideEffectAPIs() throws {
        let sources = try Self.layoutSources().filter { Self.plannerFiles.contains($0.name) }
        #expect(sources.count == Self.plannerFiles.count)
        let forbidden = [
            "import AppKit", "import ApplicationServices", "import SwiftUI", "AXUIElement",
            "AXIsProcessTrusted", "NSScreen", "CGWindowList", "WindowRestorer", "AXWindow",
            "FileManager", "FileHandle", "contentsOf", "write(to", "UserDefaults", "Process(",
            "NSWorkspace", "GroupStore", "SettingsBackup", "layouts.json",
        ]
        for source in sources {
            for token in forbidden {
                #expect(!source.text.contains(token), "\(source.name) mentions \(token)")
            }
        }
    }
}
