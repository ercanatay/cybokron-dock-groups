import CoreGraphics

/// Converts between AppKit (bottom-left origin) and AX / CG (top-left origin)
/// coordinate axes for a rectangle within a menu-bar-screen of full height
/// `referenceHeight`. The mathematical transform is an involution: applying it
/// twice with the same reference height returns the original rectangle.
/// Floating-point roundtrip may round or return `nil`; callers should not
/// assume an exact roundtrip.
///
/// - AX global origin: top-left of the menu-bar screen (documented at
///   https://developer.apple.com/documentation/applicationservices/kaxpositionattribute)
/// - AppKit global origin: bottom-left of the menu-bar screen (documented at
///   https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CocoaDrawingGuide/Transforms/Transforms.html)
///
/// Input `referenceHeight` is the full menu-bar-screen height, not `visibleFrame`.
/// The caller supplies it; no display lookup occurs.
internal enum LayoutCoordinateConversion {
    static func convert(_ rect: CGRect, referenceHeight: CGFloat) -> CGRect? {
        // Reject non-finite reference or non-positive reference height.
        guard referenceHeight.isFinite, referenceHeight > 0 else { return nil }

        // Reject non-finite components or non-positive raw dimensions.
        guard rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.size.width.isFinite,
              rect.size.height.isFinite,
              rect.size.width > 0,
              rect.size.height > 0 else { return nil }

        // Validate input edges: all min/max edges must be finite and strictly increasing.
        let inputMinX = rect.minX
        let inputMaxX = rect.maxX
        let inputMinY = rect.minY
        let inputMaxY = rect.maxY
        guard inputMinX.isFinite, inputMaxX.isFinite,
              inputMinY.isFinite, inputMaxY.isFinite,
              inputMinX < inputMaxX,
              inputMinY < inputMaxY else { return nil }

        // Guard arithmetic overflow when summing origin.y + height.
        let sum = rect.origin.y + rect.size.height
        guard sum.isFinite else { return nil }

        let newY = referenceHeight - sum
        guard newY.isFinite else { return nil }

        let result = CGRect(x: rect.origin.x,
                            y: newY,
                            width: rect.size.width,
                            height: rect.size.height)

        // Validate result edges: all min/max edges must be finite and strictly increasing.
        let resultMinX = result.minX
        let resultMaxX = result.maxX
        let resultMinY = result.minY
        let resultMaxY = result.maxY
        guard resultMinX.isFinite, resultMaxX.isFinite,
              resultMinY.isFinite, resultMaxY.isFinite,
              resultMinX < resultMaxX,
              resultMinY < resultMaxY else { return nil }

        return result
    }
}
