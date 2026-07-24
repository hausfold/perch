import XCTest
@testable import Morsel

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
        XCTAssertEqual(geometry.collapsedFrame.width, 188)
        XCTAssertEqual(geometry.collapsedFrame.maxY, screen.frame.maxY)
        XCTAssertEqual(geometry.expandedFrame.maxY, screen.frame.maxY)
        XCTAssertEqual(geometry.collapsedFrame.midX, screen.frame.midX)
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
        XCTAssertEqual(geometry.collapsedFrame.size, CGSize(width: 154, height: 28))
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
    }
}
