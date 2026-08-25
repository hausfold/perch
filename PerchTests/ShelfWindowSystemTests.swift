import XCTest
@testable import Perch

@MainActor
final class ShelfWindowSystemTests: XCTestCase {
    /// Constructing the window system must put nothing on the notch.
    ///
    /// It used to: the `showOnAllDisplays` sink replayed its current value the
    /// moment it was subscribed, so `init` built every panel and ordered it
    /// front. That is a panel per display created before anything at launch can
    /// decide this process should not own a shelf — a second copy standing down
    /// for the perch already running, or the test host, which is this very app.
    /// Those panels sit at `.statusBar` level over the real shelf's, pixel for
    /// pixel, and the top one silently takes every click and drop.
    func testNoPanelsUntilStart() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let repository = try StagingRepository(rootURL: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings(store: TransientSettings.store())
        let store = ShelfStore(repository: repository, settings: settings)
        let system = ShelfWindowSystem(store: store, settings: settings, theme: ShelfTheme())

        // Deliberately never started: `start()` is what puts panels on screen,
        // and a test process must not leave one there.
        XCTAssertEqual(system.panelCount, 0)
    }
}
