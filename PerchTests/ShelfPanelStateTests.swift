import XCTest
@testable import Perch

@MainActor
final class ShelfPanelStateTests: XCTestCase {
    private func makeState() -> ShelfPanelState {
        ShelfPanelState(hasCameraHousing: true, expandedContentWidth: 600)
    }

    /// A receiver that reads the plain file URL (a terminal, an editor) never
    /// reports anything, so nothing else would ever resolve the drag: the tile
    /// would sit collapsed while the header still counted the item.
    func testAnUnreportedDropHandsTheItemOff() async throws {
        let state = makeState()
        let id = UUID()
        var handedOff: Set<UUID> = []
        state.onExportHandOff = { handedOff = $0 }

        state.beginExport(of: [id])
        state.startExportGrace(after: .milliseconds(20))
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(handedOff, [id])
        XCTAssertTrue(state.draggingOutIDs.isEmpty)
    }

    /// A destination that engaged the promise reports for itself, however long
    /// its copy runs — handing that item off would race a real copy.
    func testAPromiseEngagedItemIsNeverHandedOff() async throws {
        let state = makeState()
        let id = UUID()
        var handedOff: Set<UUID> = []
        state.onExportHandOff = { handedOff = $0 }

        state.beginExport(of: [id])
        state.markPromiseEngaged(id)
        state.startExportGrace(after: .milliseconds(20))
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(handedOff.isEmpty)
        XCTAssertEqual(state.draggingOutIDs, [id], "stays collapsed until the copy reports")
    }

    /// A new drag must keep its own tiles collapsed even if the previous drag's
    /// grace timer is still pending.
    func testANewDragCancelsThePendingGrace() async throws {
        let state = makeState()
        var handOffs = 0
        state.onExportHandOff = { _ in handOffs += 1 }
        state.beginExport(of: [UUID()])
        state.startExportGrace(after: .milliseconds(20))

        let dragged = UUID()
        state.beginExport(of: [dragged])
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(handOffs, 0)
        XCTAssertTrue(state.draggingOutIDs.contains(dragged))
    }

    func testAFailedDropSpringsTheTileBack() {
        let state = makeState()
        let id = UUID()
        state.beginExport(of: [id])

        state.finishExport(of: id)

        XCTAssertTrue(state.draggingOutIDs.isEmpty)
    }
}
