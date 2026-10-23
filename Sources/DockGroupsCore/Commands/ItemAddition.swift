import Foundation

/// Turns what the user chose in an open panel into group items: adding files and folders
/// ("Add Files or Folders…") and pointing a missing one at where it is now ("Locate…").
///
/// Each location is looked at once, symbolic links followed (it was just chosen, so the app may
/// read it): an app bundle becomes an app, a plain folder a folder, anything else — a document
/// package included — a file. Programs, scripts, installers, location files and alias files
/// aren't added (`FileItemPolicy`); every location that isn't added gets a line saying why.
@MainActor
public enum ItemAddition {
    /// What the chosen locations give.
    public struct ChosenItems: Equatable {
        /// The items to add, in the order chosen.
        public var items: [GroupItem]
        /// Why each location that isn't among `items` wasn't added, one line each, in the order chosen.
        public var problems: [String]
    }

    /// Classifies and checks the chosen `urls`.
    public static func items(
        for urls: [URL],
        locator: ItemLocating,
        readApplication: (URL) throws -> GroupItem = { try AppReference(applicationURL: $0) }
    ) -> ChosenItems {
        var result = ChosenItems(items: [], problems: [])
        for url in urls {
            switch item(for: url, locator: locator, readApplication: readApplication) {
            case .success(let item): result.items.append(item)
            case .failure(let problem): result.problems.append(problem.message)
            }
        }
        return result
    }

    /// Adds the items `urls` give to the group, then — when some couldn't be added — hands the
    /// reasons to `presentProblems` (once, with all of them). Items the group has already are
    /// skipped silently. Returns how many items were added.
    @discardableResult
    public static func add(
        _ urls: [URL],
        toGroup id: DockGroup.ID,
        in store: GroupStore,
        locator: ItemLocating,
        readApplication: (URL) throws -> GroupItem = { try AppReference(applicationURL: $0) },
        presentProblems: ([String]) -> Void
    ) -> Int {
        guard !urls.isEmpty else { return 0 }
        let result = items(for: urls, locator: locator, readApplication: readApplication)
        let added = store.addItems(result.items, toGroup: id)
        if !result.problems.isEmpty {
            presentProblems(result.problems)
        }
        return added
    }

    /// Why a location can't be added.
    public struct Problem: Error, Equatable {
        public let message: String
    }

    /// The item for one chosen location, or why there's none.
    public static func item(
        for url: URL,
        locator: ItemLocating,
        readApplication: (URL) throws -> GroupItem = { try AppReference(applicationURL: $0) }
    ) -> Swift.Result<GroupItem, Problem> {
        let name = FileLocation.defaultName(for: url)
        guard let info = locator.typeInfo(at: url) else {
            return .failure(Problem(message: uncheckedMessage(name)))
        }
        let isApplication = info.typeIdentifiers.contains("com.apple.application-bundle")
            || (info.isPackage && url.pathExtension.lowercased() == "app")
        if isApplication {
            do {
                return .success(try readApplication(url))
            } catch {
                return .failure(Problem(message: error.localizedDescription))
            }
        }
        if let refusal = FileItemPolicy.refusal(byName: url) ?? FileItemPolicy.refusal(for: info, name: name) {
            return .failure(Problem(message: refusal.localizedDescription))
        }
        let item = GroupItem(fileURL: url, kind: info.itemKind)
        guard FileItemPolicy.acceptsByIdentity(item) else {
            return .failure(Problem(message: FileItemRefusal.program(name: name).localizedDescription))
        }
        return .success(item)
    }

    /// Why `url` can't take the place of the missing file or folder `item` ("Locate…"), or `nil`
    /// when it can: it's readable, of the item's kind, and not refused (`FileItemPolicy`).
    /// Whether the group already has an item there is the store's to say (`relinkItem`).
    public static func relinkProblem(for item: GroupItem, to url: URL, locator: ItemLocating) -> String? {
        let name = FileLocation.defaultName(for: url)
        guard let info = locator.typeInfo(at: url) else { return uncheckedMessage(name) }
        if let refusal = FileItemPolicy.refusal(byName: url) ?? FileItemPolicy.refusal(for: info, name: name) {
            return refusal.localizedDescription
        }
        guard info.itemKind == item.kind else {
            return Localization.format("core.item.locate.wrongKind", "“%@” isn't the same kind of item.", name)
        }
        return nil
    }

    private static func uncheckedMessage(_ name: String) -> String {
        Localization.format("core.item.unchecked", "macOS didn't let the app check “%@”.", name)
    }
}
