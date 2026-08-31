import XCTest
@testable import Perch

/// The folder Settings ▸ Folders offers to watch. None of this is a permission
/// — the grant still comes from the panel, and the offer only ever *adds* a
/// folder — so what these pin is the precedence: macOS's own answer first, the
/// rice drop as a fallback, the Desktop when neither speaks, and never a path
/// built out of perch's working directory.
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

    private func resolve(system: String? = nil, rice: String? = nil) -> String {
        ScreenshotsFolder.resolve(systemValue: system, riceValue: rice, home: home).path
    }

    // MARK: Precedence

    /// The whole point of reading `com.apple.screencapture`: a Mac whose
    /// captures do not go to the Desktop is exactly the one a guess got wrong.
    func testTheSystemLocationWins() {
        XCTAssertEqual(
            resolve(system: "/Users/someone/Downloads", rice: "~/Desktop"),
            "/Users/someone/Downloads"
        )
    }

    /// haus writes the rice key by *setting* the system one, so the two agree
    /// until somebody changes the location afterwards — at which point the
    /// later, more deliberate act is the system's.
    func testTheDropAnswersWhenTheSystemIsSilent() {
        XCTAssertEqual(resolve(system: nil, rice: "~/Pictures/Screenshots"),
                       home.appending(path: "Pictures/Screenshots").path)
    }

    func testNeitherSourceFallsBackToTheDesktop() {
        XCTAssertEqual(resolve(), home.appending(path: "Desktop").path)
    }

    /// An empty string is a key someone cleared, not an answer — from either
    /// source, and an empty system value must not shadow a good rice one.
    func testEmptyValuesAreNotAnswers() {
        XCTAssertEqual(resolve(system: "", rice: ""), home.appending(path: "Desktop").path)
        XCTAssertEqual(resolve(system: "", rice: "~/Shots"), home.appending(path: "Shots").path)
    }

    /// The reading overload, pinned against a drop that does not exist. It
    /// still asks the real `com.apple.screencapture`, so this asserts only the
    /// part the machine cannot move: with no drop and no system location, the
    /// answer is the Desktop — and on a machine that *has* one, it is at least
    /// never built out of the process's working directory.
    func testTheResolvingOverloadNeverBuildsARelativePath() {
        let resolved = ScreenshotsFolder.resolve(
            configURL: home.appending(path: "absent.json"),
            home: home
        )
        XCTAssertTrue(resolved.path.hasPrefix("/"))
        if ScreenshotsFolder.systemValue() == nil {
            XCTAssertEqual(resolved.path, home.appending(path: "Desktop").path)
        }
    }

    func testTheDropIsReadThroughTheResolvingOverload() throws {
        let url = try writeConfig(["screenshotsFolder": "~/Pictures/Screenshots"])
        try XCTSkipUnless(ScreenshotsFolder.systemValue() == nil,
                          "This Mac sets com.apple.screencapture location, which outranks the drop.")
        XCTAssertEqual(
            ScreenshotsFolder.resolve(configURL: url, home: home).path,
            home.appending(path: "Pictures/Screenshots").path
        )
    }

    // MARK: Expanding what either source wrote

    func testAbsolutePathIsTakenAsWritten() {
        XCTAssertEqual(resolve(system: "/Volumes/Shots"), "/Volumes/Shots")
    }

    func testHomeRelativePathExpandsAgainstTheRealHome() {
        XCTAssertEqual(resolve(rice: "~/Pictures/Screenshots"),
                       home.appending(path: "Pictures/Screenshots").path)
    }

    /// A bare `~` is a home a person can plausibly write; it must not become
    /// `<home>/~`.
    func testBareTildeIsTheHome() {
        XCTAssertEqual(resolve(rice: "~"), home.path)
    }

    /// Neither absolute nor `~/`: home-relative, never relative to whatever
    /// directory the process happens to be in.
    func testRelativePathIsHomeRelative() {
        XCTAssertEqual(resolve(rice: "Shots"), home.appending(path: "Shots").path)
    }

    /// `defaults write … location` takes a path, but scripts in the wild write
    /// a file URL. Taken as a path it would name a folder called "file:".
    func testAFileURLIsUnwrapped() {
        XCTAssertEqual(resolve(system: "file:///Users/someone/Pictures/Screenshots"),
                       "/Users/someone/Pictures/Screenshots")
        XCTAssertEqual(resolve(system: "file:///Users/someone/Screen%20Shots"),
                       "/Users/someone/Screen Shots")
    }

    // MARK: Reading the drop

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
