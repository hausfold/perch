import XCTest
@testable import Perch

/// The folder the "Shelf my screenshots" switch offers. None of this is a
/// permission — the grant still comes from the panel — so what these pin is
/// that perch points the panel somewhere sensible whatever the drop says, and
/// never at a path built out of its own working directory.
final class ScreenshotsFolderTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appending(path: "PerchHome-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func writeConfig(_ object: [String: String]) throws -> URL {
        let url = home.appending(path: "config.json")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        return url
    }

    func testNoRiceValueFallsBackToTheDesktop() {
        XCTAssertEqual(
            ScreenshotsFolder.resolve(riceValue: nil, home: home).path,
            home.appending(path: "Desktop").path
        )
    }

    /// The reading overload, pinned against a drop that does not exist — the
    /// machine running this must never be able to change the answer.
    func testNoDropFallsBackToTheDesktop() {
        XCTAssertEqual(
            ScreenshotsFolder.resolve(configURL: home.appending(path: "absent.json"), home: home).path,
            home.appending(path: "Desktop").path
        )
    }

    func testTheDropIsReadThroughTheResolvingOverload() throws {
        let url = try writeConfig(["screenshotsFolder": "~/Pictures/Screenshots"])
        XCTAssertEqual(
            ScreenshotsFolder.resolve(configURL: url, home: home).path,
            home.appending(path: "Pictures/Screenshots").path
        )
    }

    func testEmptyRiceValueFallsBackToTheDesktop() {
        XCTAssertEqual(
            ScreenshotsFolder.resolve(riceValue: "", home: home).path,
            home.appending(path: "Desktop").path
        )
    }

    func testAbsolutePathIsTakenAsWritten() {
        XCTAssertEqual(
            ScreenshotsFolder.resolve(riceValue: "/Volumes/Shots", home: home).path,
            "/Volumes/Shots"
        )
    }

    func testHomeRelativePathExpandsAgainstTheRealHome() {
        XCTAssertEqual(
            ScreenshotsFolder.resolve(riceValue: "~/Pictures/Screenshots", home: home).path,
            home.appending(path: "Pictures/Screenshots").path
        )
    }

    /// A bare `~` is a home a person can plausibly write; it must not become
    /// `<home>/~`.
    func testBareTildeIsTheHome() {
        XCTAssertEqual(ScreenshotsFolder.resolve(riceValue: "~", home: home).path, home.path)
    }

    /// Neither absolute nor `~/`: home-relative, never relative to whatever
    /// directory the process happens to be in.
    func testRelativePathIsHomeRelative() {
        XCTAssertEqual(
            ScreenshotsFolder.resolve(riceValue: "Shots", home: home).path,
            home.appending(path: "Shots").path
        )
    }

    func testReadsTheKeyFromTheRiceDrop() throws {
        let url = try writeConfig([
            "themeDark": "nebelung",
            "themeLight": "nebelung-latte",
            "screenshotsFolder": "/Users/someone/Pictures/Screenshots",
        ])
        XCTAssertEqual(ScreenshotsFolder.riceValue(from: url), "/Users/someone/Pictures/Screenshots")
    }

    /// A drop with only the theme keys is the common case (haus writes the
    /// folder only when it owns `haus.screenshots.location`), and it must read
    /// as "no answer" rather than as a decode failure taking the theme with it.
    func testADropWithoutTheKeyIsNoAnswer() throws {
        let url = try writeConfig(["themeDark": "nebelung", "accent": "mauve"])
        XCTAssertNil(ScreenshotsFolder.riceValue(from: url))
    }

    func testNoDropAtAllIsNoAnswer() {
        XCTAssertNil(ScreenshotsFolder.riceValue(from: home.appending(path: "absent.json")))
    }
}
