import Foundation
import Testing
@testable import DockGroupsCore

/// Small fixes: sidecar copies of the JSON files, the updater's backups, automatic checks.
@Suite("Sidecar copies of the JSON files")
struct JSONFileSupportTests {
    @Test func copyAsideKeepsOnlyTheLatestCopyEvenWithinOneSecond() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let file = temporary.url.appending(path: "groups.json")
        let now = Date(timeIntervalSince1970: 1_792_400_000)

        try Data("first".utf8).write(to: file)
        let first = try #require(try JSONFileSupport.copyAside(file, label: "pre-import", now: now))
        try Data("second".utf8).write(to: file)
        let second = try #require(try JSONFileSupport.copyAside(file, label: "pre-import", now: now))

        #expect(first != second)
        #expect(second.lastPathComponent.hasSuffix("-2.json"))
        let copies = try FileManager.default.contentsOfDirectory(atPath: temporary.url.path).filter { $0.hasPrefix("groups.pre-import-") }
        #expect(copies == [second.lastPathComponent])
        #expect(try String(contentsOf: second, encoding: .utf8) == "second")
        #expect(try String(contentsOf: file, encoding: .utf8) == "second", "the original stays")
    }

    @Test func aFailedCopyKeepsThePreviousOne() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let file = temporary.url.appending(path: "preferences.json")
        try Data("saved".utf8).write(to: file)
        let previous = try #require(try JSONFileSupport.copyAside(file, label: "pre-import", now: Date(timeIntervalSince1970: 1_792_400_000)))

        // The file can't be read now, so it can't be copied.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        #expect(throws: (any Error).self) {
            try JSONFileSupport.copyAside(file, label: "pre-import", now: Date(timeIntervalSince1970: 1_792_400_100))
        }

        #expect(FileManager.default.fileExists(atPath: previous.path), "the earlier copy is removed only once a new one exists")
    }

    @Test func movingAsideTwiceInOneSecondKeepsBoth() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let file = temporary.url.appending(path: "usage-stats.json")
        let now = Date(timeIntervalSince1970: 1_792_400_000)

        let first = JSONFileSupport.sidecarURL(for: file, label: "unreadable", now: now)
        try Data("one".utf8).write(to: first)
        let second = JSONFileSupport.sidecarURL(for: file, label: "unreadable", now: now)
        try Data("two".utf8).write(to: second)
        let third = JSONFileSupport.sidecarURL(for: file, label: "unreadable", now: now)

        #expect(first.lastPathComponent.hasPrefix("usage-stats.unreadable-") && first.pathExtension == "json")
        #expect(second.lastPathComponent == first.deletingPathExtension().lastPathComponent + "-2.json")
        #expect(third.lastPathComponent == first.deletingPathExtension().lastPathComponent + "-3.json")

        try Data("broken".utf8).write(to: file)
        let moved = try #require(try JSONFileSupport.moveAside(file))
        #expect(![first, second].contains(moved))
        #expect(try String(contentsOf: first, encoding: .utf8) == "one")
    }
}

@Suite("Update backups and automatic checks")
struct UpdateMaintenanceTests {
    @Test func theNewestBackupIsTheOneTheNameDates() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let directories = UpdateDirectories(root: temporary.url.appending(path: "updates"))
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directories.backups, withIntermediateDirectories: true)
        // Moving an app aside keeps its folder's date: the older backup can hold the newer build.
        let older = directories.backups.appending(path: "Cybokron Dock Groups 20261001-120000.app")
        let newer = directories.backups.appending(path: "Cybokron Dock Groups 20261015-090000.app")
        for (backup, modified) in [(older, 2_000.0), (newer, 1_000.0)] {
            try fileManager.createDirectory(at: backup, withIntermediateDirectories: true)
            try fileManager.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified)], ofItemAtPath: backup.path)
        }

        UpdateInstaller(directories: directories).removeLeftovers(keepingBackups: 1)

        #expect(fileManager.fileExists(atPath: newer.path))
        #expect(!fileManager.fileExists(atPath: older.path))
    }

    @Test func backupDatesComeFromTheNameThenTheFolder() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let named = temporary.url.appending(path: "Cybokron Dock Groups 20261015-090000.app")
        let unnamed = temporary.url.appending(path: "Cybokron Dock Groups.app")
        for backup in [named, unnamed] {
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 5_000)], ofItemAtPath: backup.path)
        }

        #expect(UpdateInstaller.backupDate(of: named) == UpdateInstaller.backupTimestampFormatter.date(from: "20261015-090000"))
        #expect(UpdateInstaller.backupDate(of: unnamed) == Date(timeIntervalSince1970: 5_000))
    }

    @Test func automaticChecksWaitWhileTheWindowShowsAnOfferOrAFailure() {
        var askedForTheWindow = false
        func windowIsShown(_ shown: Bool) -> Bool {
            askedForTheWindow = true
            return shown
        }

        #expect(!UpdateSchedule.mayCheckAutomatically(showsOfferOrFailure: true, windowIsShown: windowIsShown(true)))
        // Remind Me Later closed the window: the next check runs and may offer the update again.
        #expect(UpdateSchedule.mayCheckAutomatically(showsOfferOrFailure: true, windowIsShown: windowIsShown(false)))
        askedForTheWindow = false
        // Outside #expect, which evaluates the arguments it shows.
        let mayCheck = UpdateSchedule.mayCheckAutomatically(showsOfferOrFailure: false, windowIsShown: windowIsShown(true))
        #expect(mayCheck)
        #expect(!askedForTheWindow, "the window isn't looked at (or created) without an offer or failure")
    }
}
