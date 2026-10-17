import Foundation

extension Array {
    /// Moves the elements at `source` so they end up in front of the element that was at
    /// `destination` (the same semantics as SwiftUI's `onMove`). Invalid offsets are ignored.
    mutating func moveElements(fromOffsets source: IndexSet, toOffset destination: Int) {
        let valid = source.filteredIndexSet { indices.contains($0) }
        guard !valid.isEmpty else { return }
        let clampedDestination = Swift.min(Swift.max(destination, 0), count)
        let moving = valid.map { self[$0] }
        let insertionIndex = clampedDestination - valid.count(in: 0..<clampedDestination)
        for index in valid.reversed() {
            remove(at: index)
        }
        insert(contentsOf: moving, at: insertionIndex)
    }
}
