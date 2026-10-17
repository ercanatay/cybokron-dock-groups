// swift-tools-version:6.0
//
// SwiftPM manifest for building and testing without Xcode (Command Line Tools only).
// The Xcode project (CybokronDockGroups.xcodeproj, generated from project.yml) builds the same
// sources; use scripts/build-app.sh to wrap the SwiftPM binary into an .app bundle.
import PackageDescription

let package = Package(
    name: "CybokronDockGroups",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CybokronDockGroups", targets: ["CybokronDockGroups"]),
        .library(name: "DockGroupsCore", targets: ["DockGroupsCore"]),
    ],
    targets: [
        .target(
            name: "DockGroupsCore",
            path: "Sources/DockGroupsCore"
        ),
        .executableTarget(
            name: "CybokronDockGroups",
            dependencies: ["DockGroupsCore"],
            path: "Sources/CybokronDockGroups"
        ),
        .testTarget(
            name: "DockGroupsCoreTests",
            dependencies: ["DockGroupsCore"],
            path: "Tests/DockGroupsCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
