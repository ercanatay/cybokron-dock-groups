import Foundation
import Testing
@testable import DockGroupsCore

/// Small fixes: sidecar copies of the JSON files, the updater's backups, automatic checks.
@Suite("Sidecar copies of the JSON files")
struct JSONFileSupportTests {
    @Test func copyAsideKeepsTheLatestThreeCopiesEvenWithinOneSecond() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let file = temporary.url.appending(path: "groups.json")
        let now = Date(timeIntervalSince1970: 1_792_400_000)
        #expect(JSONFileSupport.keptCopies == 3)

        var made: [URL] = []
        for text in ["first", "second", "third", "fourth"] {
            try Data(text.utf8).write(to: file)
            made.append(try #require(try JSONFileSupport.copyAside(file, label: "pre-import", now: now)))
        }

        #expect(Set(made).count == 4, "collision-safe names")
        #expect(made[1].lastPathComponent.hasSuffix("-2.json"))
        let copies = try FileManager.default.contentsOfDirectory(atPath: temporary.url.path).filter { $0.hasPrefix("groups.pre-import-") }
        #expect(Set(copies) == Set(made.suffix(3).map(\.lastPathComponent)), "the oldest of four is removed")
        #expect(try String(contentsOf: made[3], encoding: .utf8) == "fourth")
        #expect(try String(contentsOf: file, encoding: .utf8) == "fourth", "the original stays")
    }

    @Test func copiesAreOrderedByTimeThenCounterNumerically() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let file = temporary.url.appending(path: "preferences.json")
        try Data("x".utf8).write(to: file)
        // Eleven copies in one second (counters up to -11), and an older second.
        let older = Date(timeIntervalSince1970: 1_792_399_000)
        let now = Date(timeIntervalSince1970: 1_792_400_000)
        let old = try #require(try JSONFileSupport.copyAside(file, label: "pre-import", now: older, keeping: 100))
        var made: [URL] = []
        for _ in 0..<11 {
            made.append(try #require(try JSONFileSupport.copyAside(file, label: "pre-import", now: now, keeping: 100)))
        }
        // Another label and an unreadable file kept aside aren't touched.
        let unreadable = temporary.url.appending(path: "preferences.unreadable-20200101-000000.json")
        try Data("{".utf8).write(to: unreadable)

        let latest = try #require(try JSONFileSupport.copyAside(file, label: "pre-import", now: now))

        let copies = try FileManager.default.contentsOfDirectory(atPath: temporary.url.path).filter { $0.hasPrefix("preferences.pre-import-") }
        #expect(latest.lastPathComponent.hasSuffix("-12.json"))
        #expect(Set(copies) == [made[9].lastPathComponent, made[10].lastPathComponent, latest.lastPathComponent], "-10 and -11 sort after -9")
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: unreadable.path))
    }

    @Test func theNewCopyIsKeptEvenWhenOthersLookNewer() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let file = temporary.url.appending(path: "groups.json")
        try Data("x".utf8).write(to: file)
        // Copies from a clock that ran ahead.
        for name in ["groups.pre-import-20991231-235959.json", "groups.pre-import-20991231-235958.json", "groups.pre-import-20991231-235957.json"] {
            try Data("future".utf8).write(to: temporary.url.appending(path: name))
        }

        let copy = try #require(try JSONFileSupport.copyAside(file, label: "pre-import", now: Date(timeIntervalSince1970: 1_792_400_000)))

        let copies = try FileManager.default.contentsOfDirectory(atPath: temporary.url.path).filter { $0.hasPrefix("groups.pre-import-") }
        #expect(copies.count == 3)
        #expect(copies.contains(copy.lastPathComponent))
        #expect(!copies.contains("groups.pre-import-20991231-235957.json"))
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
