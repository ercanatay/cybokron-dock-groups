import Foundation

/// The published releases behind Settings → Updates → "Other Versions…", which installs any of them,
/// older or newer than the running version.
public enum ReleaseHistory {
    /// The first version with the built-in updater. Older ones can't install another version
    /// themselves; going back up from one means downloading from the releases page.
    public static let firstSelfUpdatingVersion = SemanticVersion(major: 0, minor: 5, patch: 1)

    /// The first version with the 2026-10 security fixes (Developer ID update signatures required,
    /// the disk image checked before it's mounted, link limits, …). "Other Versions…" warns before
    /// installing an older one.
    public static let minimumSecurityVersion = SemanticVersion(major: 0, minor: 6, patch: 5)

    /// Whether `version` predates `minimumSecurityVersion`.
    public static func lacksSecurityFixes(_ version: SemanticVersion) -> Bool {
        version < minimumSecurityVersion
    }

    /// The first version whose groups can hold files and folders, and items with an alias, tags
    /// or task notes. An older one shows files and folders as missing apps, ignores the details,
    /// and drops them when it saves the groups (`DowngradeProtection`).
    public static let firstGroupItemsVersion = SemanticVersion(major: 0, minor: 6, patch: 8)

    /// Whether `version` predates `firstGroupItemsVersion`.
    public static func lacksGroupItems(_ version: SemanticVersion) -> Bool {
        version < firstGroupItemsVersion
    }

    /// The first version with Start and Finish, launch options and protected apps. An older one
    /// ignores them, and drops them when it saves the groups or the settings (`DowngradeProtection`).
    public static let firstContextSwitchingVersion = SemanticVersion(major: 0, minor: 8, patch: 0)

    /// Whether `version` predates `firstContextSwitchingVersion`.
    public static func lacksContextSwitching(_ version: SemanticVersion) -> Bool {
        version < firstContextSwitchingVersion
    }

    /// The first version with group keyboard shortcuts, archived groups and templates. An older one
    /// ignores them, and drops shortcuts and the archive when it saves the groups
    /// (`DowngradeProtection`); `templates.json` it never opens.
    public static let firstGroupShortcutsVersion = SemanticVersion(major: 0, minor: 9, patch: 0)

    /// Whether `version` predates `firstGroupShortcutsVersion`.
    public static func lacksGroupShortcuts(_ version: SemanticVersion) -> Bool {
        version < firstGroupShortcutsVersion
    }

    /// The releases to list: neither drafts nor prereleases, one per version (the first listed
    /// wins), newest first.
    public static func installable(_ releases: [ReleaseInfo]) -> [ReleaseInfo] {
        var seen: Set<SemanticVersion> = []
        return releases
            .filter { !$0.isDraft && !$0.isPrerelease && !$0.version.isPrerelease }
            .filter { seen.insert($0.version).inserted }
            .sorted { $0.version > $1.version }
    }

    /// The direction of installing `target` while `current` runs.
    public static func change(from current: SemanticVersion, to target: SemanticVersion) -> VersionChange {
        if target < current { return .downgrade }
        if target > current { return .upgrade }
        return .reinstall
    }

    /// The listed versions newer than `version`, newest first.
    public static func versions(newerThan version: SemanticVersion, in releases: [ReleaseInfo]) -> [SemanticVersion] {
        installable(releases).map(\.version).filter { $0 > version }
    }

    /// What going back from `current` to `target` skips: the listed versions newer than `target`,
    /// and `current` itself even when it isn't listed (yet), newest first.
    public static func versionsSkipped(goingBackTo target: SemanticVersion, from current: SemanticVersion, in releases: [ReleaseInfo]) -> [SemanticVersion] {
        let listed = versions(newerThan: target, in: releases)
        let all = listed.contains(current) || current <= target || current.isPrerelease ? listed : listed + [current]
        return all.sorted(by: >)
    }

    /// The update state once `target` replaced `current` from "Other Versions…", so automatic checks
    /// don't keep offering what the user just left:
    ///
    /// - Going back (`target` older): every listed release newer than `target` is skipped, and the
    ///   version left behind, together with earlier skips that are still newer than it. "Check for Updates…" still offers them, and
    ///   going up from "Other Versions…" again clears the list.
    /// - Going up (`target` newer): the skipped versions are cleared — back on the latest path.
    /// - The same version again: nothing changes.
    public static func state(
        _ state: UpdateState,
        afterInstalling target: SemanticVersion,
        over current: SemanticVersion,
        published releases: [ReleaseInfo]
    ) -> UpdateState {
        var result = state
        switch change(from: current, to: target) {
        case .downgrade:
            let kept = state.skippedVersions.compactMap(SemanticVersion.init).filter { $0 > target }
            result.skippedVersions = (kept + versionsSkipped(goingBackTo: target, from: current, in: releases)).map(\.description)
        case .upgrade:
            result.skippedVersions = []
        case .reinstall:
            break
        }
        return result
    }
}

/// How an installed version relates to the running one.
public enum VersionChange: Equatable, Sendable {
    case downgrade
    case upgrade
    case reinstall
}
