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

    /// The only layout file that reads Accessibility, and only reads.
    static let observerFile = "LayoutAccessibilityObserver.swift"

    @Test func layoutCoreWritesNoWindowGeometry() throws {
        let sources = try Self.layoutSources()
        #expect(Set(Self.plannerFiles + [Self.observerFile]).isSubset(of: Set(sources.map(\.name))))
        // Writing, acting on or sending input to another app, and asking for access.
        let forbidden = [
            "AXUIElementSetAttributeValue",
            "AXValueCreate",
            "AXUIElementPerformAction",
            "AXUIElementPostKeyboardEvent",
            "AXUIElementCopyActionNames",
            "kAXRaiseAction",
            "kAXPressAction",
            "kAXMainAttribute",
            "kAXFocusedAttribute",
            "AXIsProcessTrustedWithOptions",
            "kAXTrustedCheckOptionPrompt",
            "promptOnce",
            "activate(",
            "unhide(",
            "WindowRestorer",
            "SystemWindowAccessibility",
        ]
        for source in sources {
            for token in forbidden {
                #expect(!source.text.contains(token), "\(source.name) mentions \(token)")
            }
        }
        // Geometry attributes are read by the observer and nowhere else in the layout core.
        for source in sources where source.name != Self.observerFile {
            for token in ["kAXPositionAttribute", "kAXSizeAttribute", "AXUIElement", "AXIsProcessTrusted"] {
                #expect(!source.text.contains(token), "\(source.name) mentions \(token)")
            }
        }
    }

    @Test func observerReadsNoTitleOrContent() throws {
        let observer = try #require(Self.layoutSources().first { $0.name == Self.observerFile })
        let forbidden = [
            "kAXTitleAttribute", "\"AXTitle\"", "kAXDocumentAttribute", "kAXURLAttribute", "kAXValueAttribute",
            "kAXDescriptionAttribute", "kAXFilenameAttribute", "CGWindowList", "NSScreen", "FileManager",
            "UserDefaults", "Process(",
        ]
        for token in forbidden {
            #expect(!observer.text.contains(token), "\(Self.observerFile) mentions \(token)")
        }
        // Copying attribute values is the only call sent to another app.
        let calls = observer.text.components(separatedBy: "AXUIElement").dropFirst().compactMap { rest -> String? in
            let name = rest.prefix { $0.isLetter }
            return name.isEmpty ? nil : String(name)
        }
        #expect(Set(calls).isSubset(of: ["CopyAttributeValue", "CreateApplication", "SetMessagingTimeout", "GetTypeID"]),
                "unexpected AXUIElement calls: \(Set(calls))")
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
