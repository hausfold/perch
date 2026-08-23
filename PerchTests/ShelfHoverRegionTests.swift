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

    // MARK: - The gate

    private func gateInBand(_ gate: inout ShelfHoverGate) -> ShelfHoverGate.Edge {
        gate.update(.sample, isInBand: true)
    }

    func testEnteringTheBandReportsOneEnter() {
        var gate = ShelfHoverGate()
        XCTAssertEqual(gate.update(.sample, isInBand: true), .entered)
        // The hosting view's full-bounds area reports the same crossing.
        XCTAssertEqual(gate.update(.sample, isInBand: true), .none)
        XCTAssertTrue(gate.isInBand)
    }

    /// #1 itself: a sample from the wide drag-catch band must not open the shelf.
    func testASampleBesideTheNotchNeverEnters() {
        var gate = ShelfHoverGate()
        XCTAssertEqual(gate.update(.sample, isInBand: false), .none)
        XCTAssertFalse(gate.isInBand)
    }

    /// The regression the edge-gated first cut introduced: hover the shelf open,
    /// move down into its body (leaving the band), then leave the panel. That
    /// last exit is the *only* passive path back to a collapsed shelf, so it has
    /// to be reported even though the band was already behind us.
    func testLeavingThePanelAlwaysReportsAnExitEvenAfterLeavingTheBand() {
        var gate = ShelfHoverGate()
        XCTAssertEqual(gateInBand(&gate), .entered)
        // Down into the expanded body — an exit, harmlessly re-checked against
        // the live pointer by scheduleCollapse.
        XCTAssertEqual(gate.update(.sample, isInBand: false), .exited)
        // Out of the panel entirely.
        XCTAssertEqual(gate.update(.left, isInBand: false), .exited)
        XCTAssertFalse(gate.isInBand)
    }

    /// `hoverSuppressed` (set by Hide) is cleared on exit, so a Hide clicked
    /// from the expanded body — well outside the band — must still re-arm.
    func testAnExitFromOutsideTheBandStillReports() {
        var gate = ShelfHoverGate()
        XCTAssertEqual(gate.update(.left, isInBand: false), .exited)
    }

    func testReenteringAfterLeavingOpensAgain() {
        var gate = ShelfHoverGate()
        XCTAssertEqual(gateInBand(&gate), .entered)
        XCTAssertEqual(gate.update(.left, isInBand: false), .exited)
        XCTAssertEqual(gateInBand(&gate), .entered)
    }
}
