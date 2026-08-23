import XCTest
@testable import Perch

/// The passive-hover band (#1). These run without a window server, which is the
/// point: the previous trigger could only be judged by sweeping a real menu bar.
final class ShelfHoverRegionTests: XCTestCase {
    // A notched 14" panel: 635pt catch band, 180pt hover band, 38pt deep.
    private let bounds = CGRect(x: 0, y: 0, width: 635, height: 66)
    private let bandWidth: CGFloat = 180
    private let bandHeight: CGFloat = 38

    private func band(isFlipped: Bool = false) -> CGRect {
        ShelfHoverRegion.rect(
            in: bounds,
            width: bandWidth,
            height: bandHeight,
            isFlipped: isFlipped
        )
    }

    func testBandIsCenteredAndAnchoredToTheTopEdge() {
        let rect = band()
        XCTAssertEqual(rect.width, bandWidth)
        XCTAssertEqual(rect.height, bandHeight)
        XCTAssertEqual(rect.midX, bounds.midX)
        // Unflipped (AppKit default): "top" is maxY.
        XCTAssertEqual(rect.maxY, bounds.maxY)
    }

    func testFlippedBandAnchorsToMinY() {
        XCTAssertEqual(band(isFlipped: true).minY, bounds.minY)
    }

    /// The bug: a pointer one notch-width to the side of the housing is inside
    /// the wide drag-catch bounds, and used to open the shelf because the
    /// hosting view's own full-bounds tracking area fired our `mouseEntered`.
    func testPointerBesideTheNotchIsOutsideTheBand() {
        let rect = band()
        let oneNotchLeft = CGPoint(x: bounds.midX - bandWidth, y: bounds.maxY - 4)
        let oneNotchRight = CGPoint(x: bounds.midX + bandWidth, y: bounds.maxY - 4)
        XCTAssertFalse(rect.contains(oneNotchLeft))
        XCTAssertFalse(rect.contains(oneNotchRight))
        XCTAssertTrue(bounds.contains(oneNotchLeft), "still inside the drag-catch band")
        XCTAssertTrue(bounds.contains(oneNotchRight), "still inside the drag-catch band")
    }

    func testPointerOverTheHousingIsInsideTheBand() {
        XCTAssertTrue(band().contains(CGPoint(x: bounds.midX, y: bounds.maxY - 4)))
    }

    /// A pointer below the housing but still inside the (deliberately generous)
    /// drag-catch height must not hover-open either.
    func testPointerBelowTheHousingIsOutsideTheBand() {
        let deep = CGPoint(x: bounds.midX, y: bounds.maxY - bandHeight - 4)
        XCTAssertFalse(band().contains(deep))
        XCTAssertTrue(bounds.contains(deep))
    }

    func testNilTriggersFallBackToTheWholeView() {
        let rect = ShelfHoverRegion.rect(in: bounds, width: nil, height: nil, isFlipped: false)
        XCTAssertEqual(rect, bounds)
    }

    func testTriggersWiderThanBoundsAreClampedToBounds() {
        let rect = ShelfHoverRegion.rect(in: bounds, width: 5000, height: 5000, isFlipped: false)
        XCTAssertEqual(rect, bounds)
    }
}
