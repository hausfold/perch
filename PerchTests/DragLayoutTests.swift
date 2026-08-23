import CoreGraphics
import XCTest
@testable import Perch

/// #9: fifty folders dropped into an empty Finder window landed in a
/// top-left→bottom-right diagonal. These pin the property that was missing —
/// every item asks for its *own* position — without needing a window server or
/// a real drag.
final class DragLayoutTests: XCTestCase {
    private let center = CGPoint(x: 54, y: 54)

    func testEveryItemGetsADistinctFrame() {
        // The old layout clamped its cascade at five, so items 5...49 shared one
        // frame and Finder had 46 collisions to resolve. That is the diagonal.
        for count in [2, 6, 50, 250] {
            let frames = DragLayout.frames(count: count, center: center)
            XCTAssertEqual(frames.count, count)
            XCTAssertEqual(
                Set(frames.map { "\($0.origin.x),\($0.origin.y)" }).count,
                count,
                "\(count) items must ask for \(count) positions"
            )
        }
    }

    func testFramesNeverOverlap() {
        let frames = DragLayout.frames(count: 50, center: center)
        for (index, frame) in frames.enumerated() {
            for other in frames[(index + 1)...] {
                XCTAssertFalse(
                    frame.intersects(other),
                    "two overlapping frames are two Finder has to de-overlap"
                )
            }
        }
    }

    /// A block, not a 50-wide line — Finder receives an arrangement it can fit
    /// in a window rather than one that runs off the right edge.
    func testTheGridWrapsIntoRows() {
        let frames = DragLayout.frames(count: 50, center: center)
        let columns = Set(frames.map(\.origin.x)).count
        let rows = Set(frames.map(\.origin.y)).count
        XCTAssertEqual(columns, DragLayout.maximumColumns)
        XCTAssertEqual(rows, 7)
    }

    /// The single-tile drag is the common one and must not move: its image sits
    /// on the tile, so it tracks the pointer exactly as before.
    func testOneItemSitsOnTheTile() {
        let frames = DragLayout.frames(count: 1, center: center)
        XCTAssertEqual(frames, [CGRect(x: 30, y: 30, width: 48, height: 48)])
        XCTAssertTrue(DragLayout.frames(count: 0, center: center).isEmpty)
    }

    /// The block is centred on the tile, not hung off its corner — the pointer
    /// stays in the middle of the pile it is carrying.
    func testTheBlockIsCentredOnTheTile() {
        let frames = DragLayout.frames(count: 9, center: center)
        let union = frames.dropFirst().reduce(frames[0]) { $0.union($1) }
        XCTAssertEqual(union.midX, center.x, accuracy: 0.001)
        XCTAssertEqual(union.midY, center.y, accuracy: 0.001)
    }
}
