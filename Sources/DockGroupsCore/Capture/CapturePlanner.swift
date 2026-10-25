import Foundation

/// Where captured apps go: into a new group, or added to an existing one.
public enum CaptureTarget: Hashable, Sendable {
    case newGroup
    case group(DockGroup.ID)
}

/// One open app, as capturing lists it: the app item it would add and what to say about it.
public struct CaptureCandidate: Identifiable, Hashable, Sendable {
    /// What the list says next to the app.
    public enum Note: String, Hashable, Sendable, CaseIterable {
        /// Every instance of it is hidden.
        case hidden
        /// None of its instances has a window that counts (`WindowSnapshot`). Only set when the
        /// window list could be read.
        case noWindows
        /// It's in Settings → Switching's protected apps: listed, not selected (spec Decision 2).
        case protected
        /// The target group has it already: shown, but it can't be chosen again.
        case inGroup
    }

    /// An app item (`kind == .application`) that passed `AppItemPolicy`, as Add Apps… would make it.
    public let item: GroupItem
    public let notes: Set<Note>
    /// `false` when the target group has the app already.
    public let isSelectable: Bool

    /// The item's identity, matched without regard to case (`normalizedBundleIdentifier`).
    public var id: String { item.normalizedBundleIdentifier }

    public init(item: GroupItem, notes: Set<Note> = [], isSelectable: Bool = true) {
        self.item = item
        self.notes = notes
        self.isSelectable = isSelectable
    }
}

/// What capturing the open apps offers, planned from one `OpenAppsSnapshot` (`CapturePlanner`): the
/// apps to list, in order, which of them start selected, and how many open apps couldn't be listed.
public struct CapturePlan: Equatable, Sendable {
    /// The most apps one capture adds.
    public static let maximumItems = 50
    /// The most open apps one capture lists.
    public static let maximumCandidates = 200

    public let target: CaptureTarget
    /// In the chosen order, which is the order they're added in.
    public let candidates: [CaptureCandidate]
    /// The candidates that start selected (spec §1.5), in order, at most `maximumItems`.
    public let defaultSelection: [CaptureCandidate.ID]
    /// Regular open apps that can't be app items here: no app bundle, an identity that can't be
    /// kept, or an app without a bundle identifier that runs from a temporary copy (spec §1.3).
    public let unavailableCount: Int
    /// Whether the window list could be read, so the window option means something.
    public let hasWindowInformation: Bool

    public init(
        target: CaptureTarget,
        candidates: [CaptureCandidate],
        defaultSelection: [CaptureCandidate.ID],
        unavailableCount: Int,
        hasWindowInformation: Bool
    ) {
        self.target = target
        self.candidates = candidates
        self.defaultSelection = defaultSelection
        self.unavailableCount = unavailableCount
        self.hasWindowInformation = hasWindowInformation
    }

    /// Whether any listed app can be chosen; `false` when every one is in the group already (or
    /// none is open).
    public var hasSelectableCandidates: Bool {
        candidates.contains(where: \.isSelectable)
    }

    /// The items of the selected candidates, in candidate order: selectable ones only, the first
    /// `maximumItems` of them, whatever `ids` holds. The sheet, Siri and Shortcuts all add these.
    public func items(selecting ids: Set<CaptureCandidate.ID>) -> [GroupItem] {
        let wanted = Set(ids.map { $0.lowercased() })
        return Array(
            candidates.lazy
                .filter { $0.isSelectable && wanted.contains($0.id) }
                .map(\.item)
                .prefix(Self.maximumItems)
        )
    }

    /// The items capturing adds without a sheet (Siri, Shortcuts): `defaultSelection`'s.
    public var defaultItems: [GroupItem] {
        items(selecting: Set(defaultSelection))
    }

    /// The footnote about the open apps that couldn't be listed; `nil` when there are none.
    public var unavailableNote: String? {
        let count = unavailableCount
        guard count > 0 else { return nil }
        if count == 1 {
            return Localization.string(
                "core.capture.unavailable.one",
                "1 open app can't be added here: it isn't an app bundle, or it runs from a temporary copy (move it to Applications first)."
            )
        }
        return Localization.format(
            "core.capture.unavailable.other",
            "%ld open apps can't be added here: they aren't app bundles, or run from a temporary copy (move them to Applications first).",
            count
        )
    }

    /// What the sheet says once `maximumItems` apps are selected.
    public static var limitNote: String {
        let limit = maximumItems
        return Localization.format("core.capture.limit", "You can add up to %ld apps at once.", limit)
    }
}

/// Turns an `OpenAppsSnapshot` into a `CapturePlan`, reading nothing and changing nothing (spec
/// §2.4): which open apps are listed, as which app items, in which order, and which start selected.
///
/// Listed are the regular apps, each once — never this app, another copy of it, a standalone
/// group's own app, Finder, or an app in `leavingOut` — that can be app items: a `.app` bundle,
/// identified by a bundle identifier or, without one, by its bundle's location. Window information
/// only changes the first selection (spec Decision 4); protected apps are listed, unselected
/// (Decision 2).
public enum CapturePlanner {
    /// The longest name and bundle identifier taken from a running app.
    public static let maximumNameLength = 255

    /// - Parameters:
    ///   - targetItems: The target group's items when adding to it, so the apps it has are shown
    ///     as such; empty for a new group.
    ///   - protectedApps: Settings → Switching's list; those apps start unselected.
    ///   - leavingOut: Identities never listed, such as the Shortcuts app when Siri or Shortcuts
    ///     capture (it's the caller, not part of the work).
    public static func plan(
        _ snapshot: OpenAppsSnapshot,
        settings: CaptureSettings,
        target: CaptureTarget,
        targetItems: [GroupItem] = [],
        protectedApps: ProtectedApps = ProtectedApps(),
        leavingOut: Set<String> = []
    ) -> CapturePlan {
        let leftOut = Set(leavingOut.map { $0.lowercased() })
        func isLeftOut(_ identity: String) -> Bool {
            let identity = identity.lowercased()
            return ProtectedApps.isAlwaysProtected(identity: identity, action: .hiding)
                || identity == ProtectedApps.finderBundleIdentifier
                || leftOut.contains(identity)
        }

        // 1–2: eligibility and the item of each instance.
        var unavailable = 0
        var instances: [Instance] = []
        for (index, app) in snapshot.apps.enumerated() where app.isRegular {
            if let identity = RunningAppSnapshot.identity(bundleIdentifier: app.bundleIdentifier, bundleURL: app.bundleURL),
               isLeftOut(identity) {
                continue
            }
            guard let item = item(for: app) else {
                unavailable += 1
                continue
            }
            guard !isLeftOut(item.normalizedBundleIdentifier) else { continue }
            instances.append(Instance(app: app, item: item, index: index))
        }

        // 3–4: most recently used first; the first instance of an app stands for all of them.
        let ranks = snapshot.history.ranks
        let onScreen = Dictionary(
            (snapshot.windows?.onScreenOrder ?? []).enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        let byRecency = instances.sorted { isMoreRecent($0, than: $1, ranks: ranks, onScreen: onScreen) }
        var grouped: [String: [Instance]] = [:]
        var representatives: [Instance] = []
        for instance in byRecency {
            let key = instance.item.normalizedBundleIdentifier
            if grouped[key] == nil {
                representatives.append(instance)
            }
            grouped[key, default: []].append(instance)
        }
        var ordered = representatives.map(\.item)
        if settings.order == .name {
            ordered = DockGroup.sortedByName(ordered)
        }
        // 6: bounded.
        ordered = Array(ordered.prefix(CapturePlan.maximumCandidates))

        // 5: notes and the first selection.
        let inGroup = Set(targetItems.map(\.normalizedBundleIdentifier))
        let windows = snapshot.windows
        var candidates: [CaptureCandidate] = []
        var selection: [CaptureCandidate.ID] = []
        for item in ordered {
            let key = item.normalizedBundleIdentifier
            let all = grouped[key] ?? []
            var notes = Set<CaptureCandidate.Note>()
            if !all.isEmpty, all.allSatisfy(\.app.isHidden) {
                notes.insert(.hidden)
            }
            if let windows, !all.contains(where: { windows.processesWithWindows.contains($0.app.processIdentifier) }) {
                notes.insert(.noWindows)
            }
            if protectedApps.lists(identity: key) {
                notes.insert(.protected)
            }
            let isSelectable = !inGroup.contains(key)
            if !isSelectable {
                notes.insert(.inGroup)
            }
            let candidate = CaptureCandidate(item: item, notes: notes, isSelectable: isSelectable)
            candidates.append(candidate)
            if isSelectable, !notes.contains(.protected),
               !(settings.selectsOnlyAppsWithWindows && notes.contains(.noWindows)),
               selection.count < CapturePlan.maximumItems {
                selection.append(candidate.id)
            }
        }

        return CapturePlan(
            target: target,
            candidates: candidates,
            defaultSelection: selection,
            unavailableCount: unavailable,
            hasWindowInformation: windows != nil
        )
    }

    /// The name a new group of `items` is offered (spec §1.6, Decision 3): the first item's name
    /// ("Xcode"), with how many others there are ("Xcode +3"), or "Open Apps" without items — made
    /// unique among `taken` (the active and archived groups' names) as `GroupNaming.uniqueName`
    /// makes it ("Xcode +3 2").
    public static func suggestedName(for items: [GroupItem], taken: some Sequence<String>) -> String {
        let base: String
        if let first = items.first {
            let name = first.displayName
            let others = items.count - 1
            base = others == 0 ? name : Localization.format("core.capture.name.more", "%1$@ +%2$ld", name, others)
        } else {
            base = Localization.string("core.capture.name.none", "Open Apps")
        }
        return GroupNaming.uniqueName(base, taken: taken)
    }

    // MARK: - Items

    /// The app item for a running app (spec §2.4, step 2), or `nil` when it can't be one: no `.app`
    /// bundle at a valid location; a bundle identifier that's too long or has whitespace, control
    /// characters, "/" or ":"; or, without one, a bundle run from a temporary copy (App
    /// Translocation), whose location changes at every launch. An app with an identifier run from
    /// such a copy is kept without its location: it's found by its identifier.
    static func item(for app: OpenApp) -> GroupItem? {
        guard let url = app.bundleURL, url.isFileURL else { return nil }
        let path = url.standardizedFileURL.path
        guard FileLocation.isAppBundlePath(path) else { return nil }
        let translocated = isTranslocated(path)
        let name = displayName(of: app, bundlePath: path)
        let item: GroupItem
        if let identifier = app.bundleIdentifier, !identifier.isEmpty {
            guard isAcceptableBundleIdentifier(identifier) else { return nil }
            item = GroupItem(bundleIdentifier: identifier, name: name, path: translocated ? nil : path)
        } else {
            guard !translocated else { return nil }
            // As Add Apps… identifies a bundle without an identifier (`AppReference(applicationURL:)`).
            let location = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard FileLocation.isAppBundlePath(location), !isTranslocated(location) else { return nil }
            item = GroupItem(bundleIdentifier: location, name: name, path: path)
        }
        return AppItemPolicy.sanitized(item)
    }

    /// Whether `path` is inside a temporary copy macOS made to run an app from a download.
    static func isTranslocated(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0 == "AppTranslocation" }
    }

    /// A bundle identifier as a running app may give one: not empty, at most `maximumNameLength`
    /// characters, no whitespace or control characters — stricter than stored items need, because
    /// it's new input — and one `AppItemPolicy` keeps.
    static func isAcceptableBundleIdentifier(_ identifier: String) -> Bool {
        guard !identifier.isEmpty, identifier.count <= maximumNameLength,
              AppItemPolicy.isBundleIdentifier(identifier)
        else { return false }
        return !identifier.unicodeScalars.contains { $0.properties.isWhitespace || $0.properties.generalCategory == .control }
    }

    /// The app's name without control characters, at most `maximumNameLength` characters; its
    /// bundle's file name (without ".app") when it has none.
    static func displayName(of app: OpenApp, bundlePath: String) -> String {
        if let name = app.name.flatMap(cleanedName) {
            return name
        }
        let fileName = (bundlePath as NSString).lastPathComponent
        let stem = fileName.lowercased().hasSuffix(".app") ? String(fileName.dropLast(4)) : fileName
        return cleanedName(stem) ?? fileName
    }

    private static func cleanedName(_ raw: String) -> String? {
        let scalars = raw.unicodeScalars.filter { $0.properties.generalCategory != .control }
        let cleaned = DockGroup.sanitizedName(String(String.UnicodeScalarView(scalars)))
        return cleaned.map { String($0.prefix(maximumNameLength)) }
    }

    // MARK: - Order

    /// A running instance of an app that can be listed, with where macOS listed it.
    private struct Instance {
        let app: OpenApp
        let item: GroupItem
        let index: Int
    }

    /// Most recently used first: brought to the front more recently (apps brought to the front
    /// since this app started before the others); then by their frontmost window on screen; then
    /// launched more recently (unknown launch dates last); then by name; then as macOS listed them.
    private static func isMoreRecent(_ lhs: Instance, than rhs: Instance, ranks: [String: Int], onScreen: [pid_t: Int]) -> Bool {
        if let order = compare(ranks[lhs.item.normalizedBundleIdentifier], ranks[rhs.item.normalizedBundleIdentifier], smallerFirst: true) {
            return order
        }
        if let order = compare(onScreen[lhs.app.processIdentifier], onScreen[rhs.app.processIdentifier], smallerFirst: true) {
            return order
        }
        if let order = compare(lhs.app.launchDate, rhs.app.launchDate, smallerFirst: false) {
            return order
        }
        switch lhs.item.displayName.localizedStandardCompare(rhs.item.displayName) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs.index < rhs.index
        }
    }

    /// `true` when `lhs` comes first, `false` when `rhs` does, `nil` when they're equal: known values
    /// before unknown ones, then smaller (or larger) first.
    private static func compare<Value: Comparable>(_ lhs: Value?, _ rhs: Value?, smallerFirst: Bool) -> Bool? {
        switch (lhs, rhs) {
        case (nil, nil): return nil
        case (.some, nil): return true
        case (nil, .some): return false
        case let (.some(left), .some(right)):
            guard left != right else { return nil }
            return smallerFirst ? left < right : left > right
        }
    }
}
