import Foundation
import Testing
@testable import DockGroupsCore

@Suite("File item locations")
struct FileLocationTests {
    @Test func identitiesAreStandardizedFileURLs() {
        #expect(FileLocation.identity(for: URL(fileURLWithPath: "/Users/me/Q3 Report.pdf"), kind: .file) == "file:///Users/me/Q3%20Report.pdf")
        #expect(FileLocation.identity(for: URL(fileURLWithPath: "/Users/me/Projects"), kind: .folder) == "file:///Users/me/Projects/")
        #expect(FileLocation.identity(for: URL(fileURLWithPath: "/Users/me/Projects/", isDirectory: true), kind: .folder) == "file:///Users/me/Projects/")
        #expect(FileLocation.identity(for: URL(fileURLWithPath: "/Users/me/Projects/", isDirectory: true), kind: .file) == "file:///Users/me/Projects")
        #expect(FileLocation.identity(for: URL(fileURLWithPath: "/Users/me/old/../Projects/./x.txt"), kind: .file) == "file:///Users/me/Projects/x.txt")
        #expect(FileLocation.identity(for: URL(fileURLWithPath: "/"), kind: .folder) == "file:///")
    }

    @Test func identitiesNameTheirLocationBack() throws {
        for path in ["/Users/me/Çalışma/Fatura #3?.pdf", "/Volumes/Backup SSD/Shots.zip", "/Users/me/100% done.txt"] {
            let identity = FileLocation.identity(for: URL(fileURLWithPath: path), kind: .file)
            #expect(!identity.contains(" ") && !identity.contains("#") && !identity.contains("?"))
            #expect(try #require(FileLocation.url(fromIdentity: identity)).path == path)
        }
        #expect(FileLocation.url(fromIdentity: "file://localhost/Users/me/a.pdf")?.path == "/Users/me/a.pdf")
        #expect(FileLocation.url(fromIdentity: "FILE:///Users/me/a.pdf")?.path == "/Users/me/a.pdf")
        #expect(FileLocation.url(fromIdentity: "file:///Users/me/Projects/")?.hasDirectoryPath == true)
    }

    @Test(arguments: [
        "",
        "/Users/me/a.pdf",
        "Users/me/a.pdf",
        "file:Users/me/a.pdf",
        "https://example.com/a.pdf",
        "file://example.com/a.pdf",
        "file://me@localhost/a.pdf",
        "file:///Users/me/a.pdf?x=1",
        "file:///Users/me/a.pdf#top",
        "file:///Users/me/../etc/hosts",
        "file:///Users/./me/a.pdf",
        "file:///Users/me/a%2F..%2F..%2Fetc",
        "file:///Users/me/a%00.pdf",
        "file:///Users/me/a%2f..%2f..%2fetc",
        "file:///" + String(repeating: "a", count: Int(PATH_MAX)),
    ])
    func invalidIdentitiesNameNoLocation(identity: String) {
        #expect(FileLocation.url(fromIdentity: identity) == nil)
        #expect(!FileLocation.isValidIdentity(identity, kind: .file))
        #expect(!FileLocation.isValidIdentity(identity, kind: .folder))
    }

    @Test func pathMaxIsTheLimit() {
        let longest = "/" + String(repeating: "a", count: Int(PATH_MAX) - 2)
        #expect(FileLocation.url(fromIdentity: "file://" + longest)?.path == longest)
        #expect(FileLocation.url(fromIdentity: "file://" + longest + "a") == nil)
    }

    @Test func aFoldersIdentityEndsInASlashAndAFilesDoesnt() {
        #expect(FileLocation.isValidIdentity("file:///Users/me/a.pdf", kind: .file))
        #expect(!FileLocation.isValidIdentity("file:///Users/me/a.pdf", kind: .folder))
        #expect(FileLocation.isValidIdentity("file:///Users/me/Projects/", kind: .folder))
        #expect(!FileLocation.isValidIdentity("file:///Users/me/Projects/", kind: .file))
        #expect(!FileLocation.isValidIdentity("file:///Users/me/a.pdf", kind: .application))
        #expect(!FileLocation.isValidIdentity("file:///Users/me/a.pdf", kind: .website))
    }

    @Test func appBundlePathsAreTheSameAsBefore() {
        #expect(SettingsBackup.isAppBundlePath("/Applications/Safari.app"))
        #expect(!SettingsBackup.isAppBundlePath("/Applications/.app"))
        #expect(!SettingsBackup.isAppBundlePath("/tmp/run.command"))
        #expect(!SettingsBackup.isAppBundlePath("/Applications/../tmp/X.app"))
        #expect(!SettingsBackup.isAppBundlePath("Applications/X.app"))
    }
}

@Suite("File item policy")
struct FileItemPolicyTests {
    @Test(arguments: [
        ("/Users/me/Run.command", FileItemRefusal.program(name: "Run.command")),
        ("/Users/me/install.SH", .program(name: "install.SH")),
        ("/Users/me/tool.py", .program(name: "tool.py")),
        ("/Users/me/Home.webloc", .program(name: "Home.webloc")),
        ("/Users/me/Server.inetloc", .program(name: "Server.inetloc")),
        ("/Users/me/Notes.fileloc", .program(name: "Notes.fileloc")),
        ("/Users/me/Setup.pkg", .program(name: "Setup.pkg")),
        ("/Users/me/Profile.mobileconfig", .program(name: "Profile.mobileconfig")),
        ("/Users/me/Shell.terminal", .program(name: "Shell.terminal")),
        ("/Users/me/Clean.workflow", .program(name: "Clean.workflow")),
        ("/Users/me/Hello.scpt", .program(name: "Hello.scpt")),
        ("/Users/me/Widget.appex", .program(name: "Widget.appex")),
        ("/Applications/Safari.app", .application(name: "Safari.app")),
    ])
    func refusedByName(path: String, refusal: FileItemRefusal) {
        #expect(FileItemPolicy.refusal(byName: URL(fileURLWithPath: path)) == refusal)
    }

    @Test(arguments: ["/Users/me/Q3 Report.pdf", "/Users/me/Notes.rtfd", "/Users/me/Projects", "/Users/me/Makefile", "/Users/me/a.zip", "/Users/me/Disk.dmg"])
    func allowedByName(path: String) {
        #expect(FileItemPolicy.refusal(byName: URL(fileURLWithPath: path)) == nil)
    }

    @Test func refusedByType() {
        func info(_ types: Set<String>, directory: Bool = false, package: Bool = false) -> ItemTypeInfo {
            ItemTypeInfo(typeIdentifiers: types, isDirectory: directory, isPackage: package)
        }
        #expect(FileItemPolicy.refusal(for: info(["public.unix-executable", "public.executable", "public.data"]), name: "tool") == .program(name: "tool"))
        #expect(FileItemPolicy.refusal(for: info(["public.shell-script", "public.script", "public.text"]), name: "a") == .program(name: "a"))
        #expect(FileItemPolicy.refusal(for: info(["com.apple.terminal.shell-script", "public.shell-script", "public.script"]), name: "a") == .program(name: "a"))
        #expect(FileItemPolicy.refusal(for: info(["com.apple.alias-file", "public.data"]), name: "a") == .program(name: "a"))
        #expect(FileItemPolicy.refusal(for: info(["com.apple.file-internet-location", "com.apple.internet-location"]), name: "a") == .program(name: "a"))
        #expect(FileItemPolicy.refusal(for: info(["com.sun.java-archive", "public.executable"]), name: "a") == .program(name: "a"))
        #expect(FileItemPolicy.refusal(
            for: info(["com.apple.application-bundle", "com.apple.application", "com.apple.package", "public.executable"], directory: true, package: true),
            name: "Fake.pdf"
        ) == .application(name: "Fake.pdf"))
        // Documents, document packages and plain folders are fine.
        #expect(FileItemPolicy.refusal(for: info(["com.adobe.pdf", "public.data"]), name: "a") == nil)
        #expect(FileItemPolicy.refusal(for: info(["com.apple.rtfd", "com.apple.package"], directory: true, package: true), name: "a") == nil)
        #expect(FileItemPolicy.refusal(for: info(["public.folder", "public.directory"], directory: true), name: "a") == nil)
    }

    @Test func aPackageIsAFileAndOnlyAPlainFolderIsAFolder() {
        #expect(ItemTypeInfo(typeIdentifiers: ["com.apple.rtfd"], isDirectory: true, isPackage: true).itemKind == .file)
        #expect(ItemTypeInfo(typeIdentifiers: ["public.folder"], isDirectory: true, isPackage: false).itemKind == .folder)
        #expect(ItemTypeInfo(typeIdentifiers: ["com.adobe.pdf"], isDirectory: false, isPackage: false).itemKind == .file)
    }

    @Test func itemsAcceptedByIdentity() {
        func file(_ path: String, _ kind: AppReference.Kind = .file) -> GroupItem {
            GroupItem(fileURL: URL(fileURLWithPath: path), kind: kind)
        }
        #expect(FileItemPolicy.acceptsByIdentity(file("/Users/me/Q3 Report.pdf")))
        #expect(FileItemPolicy.acceptsByIdentity(file("/Users/me/Projects", .folder)))
        #expect(!FileItemPolicy.acceptsByIdentity(file("/Users/me/Run.command")))
        #expect(!FileItemPolicy.acceptsByIdentity(file("/Applications/Safari.app", .folder)))
        #expect(FileItemPolicy.acceptsByIdentity(AppReference(bundleIdentifier: "com.apple.Safari", name: "Safari")))
        #expect(FileItemPolicy.acceptsByIdentity(AppReference(websiteURL: URL(string: "https://github.com")!)))
    }

    @Test func refusalsSayWhatsWrong() {
        #expect(FileItemRefusal.program(name: "run.command").localizedDescription == "“run.command” is a program or script, so it can't be added as a file.")
        #expect(FileItemRefusal.application(name: "Safari.app").name == "Safari.app")
    }
}
