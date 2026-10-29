import Testing
import Foundation
@testable import DockGroupsCore

struct LayoutCoordinateConversionTests {
    // MARK: - Basic coordinate classes

    @Test func convertBasicLeftBottomToTop() throws {
        let input = CGRect(x: 140, y: 140, width: 420, height: 300)
        let result = LayoutCoordinateConversion.convert(input, referenceHeight: 1440)
        let expected = CGRect(x: 140, y: 1000, width: 420, height: 300)
        #expect(result == expected)
    }

    @Test func convertRightSideCoordinate() throws {
        let input = CGRect(x: 2000, y: 500, width: 200, height: 400)
        let result = LayoutCoordinateConversion.convert(input, referenceHeight: 1440)
        #expect(result == CGRect(x: 2000, y: 540, width: 200, height: 400))
    }

    @Test func convertAboveNearTopAppKit() throws {
        // High AppKit y (near top of screen) maps to low AX y (near bottom)
        let input = CGRect(x: 10, y: 1200, width: 100, height: 100)
        let result = LayoutCoordinateConversion.convert(input, referenceHeight: 1440)
        #expect(result == CGRect(x: 10, y: 140, width: 100, height: 100))
    }

    @Test func convertBelowNearBottomAppKit() throws {
        // Low AppKit y (near bottom) maps to high AX y (near top)
        let input = CGRect(x: 10, y: 20, width: 100, height: 100)
        let result = LayoutCoordinateConversion.convert(input, referenceHeight: 1440)
        #expect(result == CGRect(x: 10, y: 1320, width: 100, height: 100))
    }

    @Test func fractionalValues() throws {
        let input = CGRect(x: 140.25, y: 140.75, width: 420.5, height: 300.25)
        let result = LayoutCoordinateConversion.convert(input, referenceHeight: 1440)
        // y = 1440 - (140.75 + 300.25) = 1440 - 441.0 = 999.0
        #expect(result == CGRect(x: 140.25, y: 999.0, width: 420.5, height: 300.25))
    }

    @Test func differentReferenceHeights() throws {
        let input = CGRect(x: 50, y: 30, width: 100, height: 50)
        #expect(LayoutCoordinateConversion.convert(input, referenceHeight: 720) == CGRect(x: 50, y: 640, width: 100, height: 50))
        #expect(LayoutCoordinateConversion.convert(input, referenceHeight: 100) == CGRect(x: 50, y: 20, width: 100, height: 50))
    }

    // MARK: - Involution / floating-point roundtrip (may round or return nil)

    @Test func roundTripTwice() throws {
        let input = CGRect(x: 140, y: 140, width: 420, height: 300)
        let once = LayoutCoordinateConversion.convert(input, referenceHeight: 1440)
        let twice = once.flatMap { LayoutCoordinateConversion.convert($0, referenceHeight: 1440) }
        #expect(twice == input)
    }

    @Test func roundTripWithDifferentReference() throws {
        let input = CGRect(x: 10, y: 20, width: 30, height: 40)
        let mid = LayoutCoordinateConversion.convert(input, referenceHeight: 720)
        let back = mid.flatMap { LayoutCoordinateConversion.convert($0, referenceHeight: 720) }
        #expect(back == input)
    }

    // MARK: - Invalid reference heights

    @Test func invalidReferenceZero() throws {
        let rect = CGRect(x: 1, y: 1, width: 10, height: 10)
        #expect(LayoutCoordinateConversion.convert(rect, referenceHeight: 0) == nil)
    }

    @Test func invalidReferenceNegative() throws {
        let rect = CGRect(x: 1, y: 1, width: 10, height: 10)
        #expect(LayoutCoordinateConversion.convert(rect, referenceHeight: -100) == nil)
    }

    @Test func invalidReferenceNan() throws {
        let rect = CGRect(x: 1, y: 1, width: 10, height: 10)
        #expect(LayoutCoordinateConversion.convert(rect, referenceHeight: CGFloat.nan) == nil)
    }

    @Test func invalidReferencePositiveInfinity() throws {
        let rect = CGRect(x: 1, y: 1, width: 10, height: 10)
        #expect(LayoutCoordinateConversion.convert(rect, referenceHeight: CGFloat.infinity) == nil)
    }

    @Test func invalidReferenceNegativeInfinity() throws {
        let rect = CGRect(x: 1, y: 1, width: 10, height: 10)
        #expect(LayoutCoordinateConversion.convert(rect, referenceHeight: CGFloat.infinity * -1) == nil)
    }

    // MARK: - Non-finite rect components

    @Test func infinityInWidth() throws {
        #expect(LayoutCoordinateConversion.convert(CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10), referenceHeight: 100) == nil)
    }

    @Test func infinityInHeight() throws {
        #expect(LayoutCoordinateConversion.convert(CGRect(x: 0, y: 0, width: 10, height: CGFloat.infinity), referenceHeight: 100) == nil)
    }

    @Test func infinityInX() throws {
        #expect(LayoutCoordinateConversion.convert(CGRect(x: CGFloat.infinity, y: 0, width: 10, height: 10), referenceHeight: 100) == nil)
    }

    @Test func infinityInY() throws {
        #expect(LayoutCoordinateConversion.convert(CGRect(x: 0, y: CGFloat.infinity, width: 10, height: 10), referenceHeight: 100) == nil)
    }

    @Test func negativeInfinityInComponent() throws {
        #expect(LayoutCoordinateConversion.convert(CGRect(x: CGFloat.infinity * -1, y: 1, width: 10, height: 10), referenceHeight: 100) == nil)
    }

    // MARK: - Zero / negative dimensions (collapsed input)

    @Test func zeroWidthReturnsNil() throws {
        #expect(LayoutCoordinateConversion.convert(CGRect(x: 10, y: 10, width: 0, height: 10), referenceHeight: 100) == nil)
    }

    @Test func zeroHeightReturnsNil() throws {
        #expect(LayoutCoordinateConversion.convert(CGRect(x: 10, y: 10, width: 10, height: 0), referenceHeight: 100) == nil)
    }

    @Test func negativeWidthReturnsNil() throws {
        #expect(LayoutCoordinateConversion.convert(CGRect(x: 10, y: 10, width: -5, height: 10), referenceHeight: 100) == nil)
    }

    @Test func negativeHeightReturnsNil() throws {
        #expect(LayoutCoordinateConversion.convert(CGRect(x: 10, y: 10, width: 10, height: -5), referenceHeight: 100) == nil)
    }

    @Test func nanWidthReturnsNil() throws {
        #expect(LayoutCoordinateConversion.convert(CGRect(x: 10, y: 10, width: CGFloat.nan, height: 10), referenceHeight: 100) == nil)
    }

    @Test func nanHeightReturnsNil() throws {
        #expect(LayoutCoordinateConversion.convert(CGRect(x: 10, y: 10, width: 10, height: CGFloat.nan), referenceHeight: 100) == nil)
    }

    @Test func nanInXAndY() throws {
        #expect(LayoutCoordinateConversion.convert(CGRect(x: CGFloat.nan, y: CGFloat.nan, width: 10, height: 10), referenceHeight: 100) == nil)
    }

    // MARK: - Overflow / arithmetic limits

    @Test func overflowSumOfYAndHeight() throws {
        let big = CGFloat.greatestFiniteMagnitude * 0.6
        #expect(LayoutCoordinateConversion.convert(CGRect(x: 0, y: big, width: 10, height: big), referenceHeight: 100) == nil)
    }

    @Test func overflowNearMaxFinite() throws {
        // Sum that overflows to infinity should be rejected.
        let nearMax = CGFloat.greatestFiniteMagnitude
        #expect(LayoutCoordinateConversion.convert(CGRect(x: 0, y: nearMax, width: 10, height: 1), referenceHeight: 100) == nil)
    }

    @Test func nearMaxValidWhenSumFinite() throws {
        let largeY = 1e308
        let smallH = 1.0
        // sum = 1e308 + 1 = 1e308 (finite in double), newY = 1440 - 1e308 = -inf -> reject due to newY non-finite.
        #expect(LayoutCoordinateConversion.convert(CGRect(x: 0, y: largeY, width: 10, height: smallH), referenceHeight: 1440) == nil)
    }

    // MARK: - Collapsed output edges (representational collapse after conversion)

    @Test func collapsedOutputRejected() throws {
        // With standard positive dimensions output should not collapse; verify via overflow that can produce non-finite.
        // Explicit collapsed output is impossible with positive width/height and finite newY, so test via near-overflow.
        #expect(LayoutCoordinateConversion.convert(CGRect(x: 0, y: CGFloat.greatestFiniteMagnitude, width: 1, height: 1), referenceHeight: 1440) == nil)
    }

    // MARK: - Input edge representability (collapsed or non-finite min/max)

    @Test func collapsedInputYEndpointsRejected() throws {
        // y + h overflows into y at 1e16 scale (ULP = 2), so input maxY collapses to minY.
        #expect(LayoutCoordinateConversion.convert(CGRect(x: 0, y: 1e16, width: 10, height: 1), referenceHeight: 1e16) == nil)
    }

    @Test func infiniteMaxXInputAdmittedByCurrentGuard() throws {
        // x = GFSM*0.75, w = GFSM*0.75 -> maxX overflows to infinity;
        // current guard only checks origin.x/width finiteness and min<max, which passes (finite < inf).
        #expect(LayoutCoordinateConversion.convert(CGRect(x: CGFloat.greatestFiniteMagnitude * 0.75, y: 0, width: CGFloat.greatestFiniteMagnitude * 0.75, height: 1), referenceHeight: 100) == nil)
    }

    // MARK: - Result edge finiteness

    @Test func resultMaxXOverflowToInfinity() throws {
        // MaxX = origin.x + width; pick values where this overflows even though width is positive finite.
        let bigX = CGFloat.greatestFiniteMagnitude * 0.999
        let wide = CGFloat.greatestFiniteMagnitude * 0.999
        // sum bigX + wide would overflow, but we only carry x and width through unchanged,
        // so result.maxX = bigX + wide -> infinity here.
        #expect(LayoutCoordinateConversion.convert(CGRect(x: bigX, y: 0, width: wide, height: 1), referenceHeight: 1440) == nil)
    }

    // MARK: - Edge cases at boundary of reference

    @Test func yPlusHeightExactlyReference() throws {
        let input = CGRect(x: 10, y: 500, width: 20, height: 940)
        let result = LayoutCoordinateConversion.convert(input, referenceHeight: 1440)
        #expect(result == CGRect(x: 10, y: 0, width: 20, height: 940))
    }

    @Test func yPlusHeightSlightlyAboveReference() throws {
        let input = CGRect(x: 10, y: 500, width: 20, height: 941)
        let result = LayoutCoordinateConversion.convert(input, referenceHeight: 1440)
        #expect(result == CGRect(x: 10, y: -1, width: 20, height: 941))
    }

    @Test func yAtZero() throws {
        let input = CGRect(x: 0, y: 0, width: 10, height: 10)
        let result = LayoutCoordinateConversion.convert(input, referenceHeight: 1440)
        #expect(result == CGRect(x: 0, y: 1430, width: 10, height: 10))
    }
}
