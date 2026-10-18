/// Where each app of a group sits in the popup grid while Free Layout is on.
///
/// Every app keeps the cell it was put in: dropping an app on an empty cell moves only that app,
/// and dropping it on another app swaps the two, so the rest of the grid never shifts. The grid
/// has as many cells as the rows the popup shows anyway (`PopupGridLayout.slotCount`), so turning
/// Free Layout on doesn't change the popup's size or shape. Apps without a usable cell of their
/// own — newly added ones, or ones whose cell no longer fits the grid — take the first free cells,
/// in list order.
public struct FreeLayout: Equatable, Sendable {
    /// Number of cells; never fewer than the group's apps.
    public let slotCount: Int
    /// Cell (row by row) of each app, keyed by normalized bundle identifier. Every app has one,
    /// and no two share one.
    public private(set) var slots: [String: Int]

    /// - Parameter savedSlots: The group's `freeLayoutSlots`.
    public init(apps: [AppReference], savedSlots: [String: Int], slotCount: Int) {
        let ids = Self.uniqueIDs(of: apps)
        self.slotCount = max(slotCount, ids.count)
        slots = Self.placement(of: ids, savedSlots: savedSlots, slotLimit: self.slotCount)
    }

    public func slot(of app: AppReference) -> Int? {
        slots[app.normalizedBundleIdentifier]
    }

    /// The layout after `app` is dropped on cell `slot` (clamped to the grid): an empty cell just
    /// takes it, and the app in an occupied cell moves to the cell `app` came from.
    public func moving(_ app: AppReference, to slot: Int) -> FreeLayout {
        let id = app.normalizedBundleIdentifier
        guard let source = slots[id] else { return self }
        let target = min(max(slot, 0), slotCount - 1)
        guard target != source else { return self }
        var layout = self
        if let occupant = slots.first(where: { $0.value == target })?.key {
            layout.slots[occupant] = source
        }
        layout.slots[id] = target
        return layout
    }

    /// The layout without `app`; the other apps stay where they are.
    public func removing(_ app: AppReference) -> FreeLayout {
        var layout = self
        layout.slots[app.normalizedBundleIdentifier] = nil
        return layout
    }

    // MARK: - Placement

    /// Every app of `ids` (in list order) gets a cell: its saved one when that's below
    /// `slotLimit` (if given) and not taken by an app earlier in the list, otherwise the lowest
    /// free cell.
    static func placement(of ids: [String], savedSlots: [String: Int], slotLimit: Int?) -> [String: Int] {
        var placement: [String: Int] = [:]
        var taken = Set<Int>()
        var unplaced: [String] = []
        for id in ids {
            if let slot = savedSlots[id], slot >= 0, slot < (slotLimit ?? Int.max), taken.insert(slot).inserted {
                placement[id] = slot
            } else {
                unplaced.append(id)
            }
        }
        var next = 0
        for id in unplaced {
            while taken.contains(next) {
                next += 1
            }
            placement[id] = next
            taken.insert(next)
        }
        return placement
    }

    static func uniqueIDs(of apps: [AppReference]) -> [String] {
        var seen = Set<String>()
        return apps.map(\.normalizedBundleIdentifier).filter { seen.insert($0).inserted }
    }
}

extension DockGroup {
    /// After the app list was reordered: the apps fill the cells the group's apps occupied in Free
    /// Layout, in their new order, so the arrangement keeps its shape and reads row by row in list
    /// order. Nothing changes while the group has no Free Layout cells.
    mutating func refillFreeLayoutSlots(previousApps: [AppReference]) {
        guard !freeLayoutSlots.isEmpty else { return }
        let occupied = FreeLayout.placement(
            of: FreeLayout.uniqueIDs(of: previousApps),
            savedSlots: freeLayoutSlots,
            slotLimit: nil
        ).values.sorted()
        freeLayoutSlots = Dictionary(
            zip(FreeLayout.uniqueIDs(of: apps), occupied).map { ($0, $1) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// The group with its apps placed in the given Free Layout cells (keyed by normalized bundle
    /// identifier) and its app list in the order the cells read, row by row, so the Dock tile,
    /// Open All and the group window follow the popup. Apps without a cell keep their relative
    /// order after the placed ones.
    func arranged(inFreeLayoutSlots slots: [String: Int]) -> DockGroup {
        var group = self
        group.freeLayoutSlots = Self.sanitizedFreeLayoutSlots(slots, apps: apps)
        group.apps = apps.enumerated()
            .sorted { lhs, rhs in
                let left = group.freeLayoutSlots[lhs.element.normalizedBundleIdentifier] ?? Int.max
                let right = group.freeLayoutSlots[rhs.element.normalizedBundleIdentifier] ?? Int.max
                return left != right ? left < right : lhs.offset < rhs.offset
            }
            .map(\.element)
        return group
    }
}
