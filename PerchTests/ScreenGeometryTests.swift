import XCTest
@testable import Perch

final class ScreenGeometryTests: XCTestCase {
    func testNotchedScreenUsesCameraHousingGapAndTopAnchor() {
        let screen = ScreenDescriptor(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 38, width: 1512, height: 944),
            safeAreaTop: 32,
            auxiliaryTopLeftArea: CGRect(x: 0, y: 950, width: 672, height: 32),
            auxiliaryTopRightArea: CGRect(x: 840, y: 950, width: 672, height: 32)
        )

        let geometry = ShelfGeometry(screen: screen)

        XCTAssertTrue(geometry.hasCameraHousing)
        XCTAssertEqual(screen.cameraHousingWidth, 168)
        // Wide catch band: 42% of the screen, clamped to [360, 640] (1512·0.42 = 635.04).
        XCTAssertEqual(geometry.collapsedFrame.width, 635.04, accuracy: 0.01)
        XCTAssertEqual(geometry.collapsedFrame.maxY, screen.frame.maxY)
        // The expanded panel bleeds 4pt above the top edge (topBleed) so the
        // glass rim lands off-screen.
        XCTAssertEqual(geometry.expandedFrame.maxY, screen.frame.maxY + 4)
        XCTAssertEqual(geometry.collapsedFrame.midX, screen.frame.midX)
        // Expand only grows downward: the window keeps the catch-zone width and
        // stays centered, so no sideways motion can kick a pointer/drag out.
        XCTAssertEqual(geometry.expandedFrame.width, geometry.collapsedFrame.width)
        XCTAssertEqual(geometry.expandedFrame.midX, screen.frame.midX)
        // The visible glass is trimmed narrower than the window and drawn
        // centered within it (1512 → min(540, 1512−48) = 540).
        XCTAssertEqual(geometry.expandedContentWidth, 540)
        XCTAssertLessThan(geometry.expandedContentWidth, geometry.expandedFrame.width)
    }

    func testNotchlessScreenGetsCompactCenteredFallback() {
        let screen = ScreenDescriptor(
            frame: CGRect(x: 1512, y: 100, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 1512, y: 100, width: 1920, height: 1055),
            safeAreaTop: 0,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil
        )

        let geometry = ShelfGeometry(screen: screen)

        XCTAssertFalse(geometry.hasCameraHousing)
        // Compact centered fallback: 32% of the screen, clamped to [300, 460]
        // (1920·0.32 = 614.4 → 460), 44pt tall.
        XCTAssertEqual(geometry.collapsedFrame.size, CGSize(width: 460, height: 44))
        XCTAssertEqual(geometry.collapsedFrame.midX, screen.frame.midX)
        XCTAssertEqual(geometry.collapsedFrame.maxY, screen.frame.maxY)
    }

    func testExpandedShelfStaysInsideNarrowDisplay() {
        let screen = ScreenDescriptor(
            frame: CGRect(x: 0, y: 0, width: 380, height: 600),
            visibleFrame: CGRect(x: 0, y: 0, width: 380, height: 575),
            safeAreaTop: 0,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil
        )

        let geometry = ShelfGeometry(screen: screen)

        XCTAssertLessThanOrEqual(geometry.expandedFrame.width, screen.frame.width - 48)
        XCTAssertGreaterThanOrEqual(geometry.expandedFrame.minX, screen.frame.minX)
        XCTAssertLessThanOrEqual(geometry.expandedFrame.maxX, screen.frame.maxX)
        // The trimmed glass can never exceed the window it is centered in — on a
        // display this narrow the catch band is the smaller of the two, so the
        // content follows it down rather than overflowing.
        XCTAssertLessThanOrEqual(geometry.expandedContentWidth, geometry.expandedFrame.width)
    }
}
