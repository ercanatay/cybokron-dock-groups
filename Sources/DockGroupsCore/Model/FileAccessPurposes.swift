import Foundation

/// What macOS says when it asks the user to let the app into a place its privacy settings guard
/// (Privacy & Security → Files and Folders): Desktop, Documents, Downloads, removable and network
/// volumes (spec §2.6). The app looks there only to check that the files and folders put in groups
/// are still there and to open them; it never reads their contents.
///
/// They're Info.plist strings: the main app's (`Resources/Info.plist`, kept equal to these by
/// `FileAccessPurposesTests`) and every standalone group's own app's (`AgentInfoPlist`), as macOS
/// asks each of them on its own. English only: `Localizable.strings` doesn't hold Info.plist
/// strings.
public enum FileAccessPurposes {
    public static let infoPlistEntries: [String: String] = [
        "NSDesktopFolderUsageDescription":
            "The app checks that files and folders you put in groups from your Desktop are still there, and opens them when you ask; it never reads their contents.",
        "NSDocumentsFolderUsageDescription":
            "The app checks that files and folders you put in groups from your Documents folder are still there, and opens them when you ask; it never reads their contents.",
        "NSDownloadsFolderUsageDescription":
            "The app checks that files and folders you put in groups from your Downloads folder are still there, and opens them when you ask; it never reads their contents.",
        "NSRemovableVolumesUsageDescription":
            "The app checks that files and folders you put in groups from external drives are still there, and opens them when you ask; it never reads their contents.",
        "NSNetworkVolumesUsageDescription":
            "The app checks that files and folders you put in groups from network volumes are still there, and opens them when you ask; it never reads their contents.",
    ]
}
