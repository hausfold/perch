import XCTest
@testable import Perch

/// The folder Settings ▸ Watched Folders offers to watch. None of this is a permission
/// — the grant still comes from the panel, and the offer only ever *adds* a
/// folder — so what these pin is the precedence: macOS's own answer first, the
/// haus drop as a fallback, the Desktop when neither speaks, and never a path
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

    /// haus writes its own key by *setting* the system one, so the two agree
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
    /// source, and an empty system value must not shadow a good haus one.
    func testEmptyValuesAreNotAnswers() {
        XCTAssertEqual(resolve(system: "", rice: ""), home.appending(path: "Desktop").path)
        XCTAssertEqual(resolve(system: "", rice: "~/Shots"), home.appending(path: "Shots").path)
    }

    /// The reading overload with no drop and nothing from the system: the
    /// Desktop, and never a path built out of the process's working directory.
    func testTheResolvingOverloadFallsBackToTheDesktop() {
        XCTAssertEqual(
            ScreenshotsFolder.resolve(
                configURL: home.appending(path: "absent.json"),
                home: home,
                systemValue: nil
            ).path,
            home.appending(path: "Desktop").path
        )
    }

    /// The drop's path through the reading overload. `systemValue` is handed
    /// in rather than skipped around: a Mac that sets a screenshot location —
    /// which outranks the drop, and is exactly the Mac this feature is for —
    /// would otherwise leave this untested.
    func testTheDropIsReadThroughTheResolvingOverload() throws {
        let url = try writeConfig(["screenshotsFolder": "~/Pictures/Screenshots"])
        XCTAssertEqual(
            ScreenshotsFolder.resolve(configURL: url, home: home, systemValue: nil).path,
            home.appending(path: "Pictures/Screenshots").path
        )
    }

    /// And the system still outranks it through that same overload.
    func testTheSystemLocationOutranksTheDropThroughTheResolvingOverload() throws {
        let url = try writeConfig(["screenshotsFolder": "~/Pictures/Screenshots"])
        XCTAssertEqual(
            ScreenshotsFolder.resolve(configURL: url, home: home, systemValue: "/Volumes/Shots").path,
            "/Volumes/Shots"
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
        // Not a legal URL — `URL(string:)` may refuse it, and refusing must not
        // drop through to the home-relative branch and name a folder "file:".
        XCTAssertEqual(resolve(system: "file:///Users/someone/Screen Shots"),
                       "/Users/someone/Screen Shots")
        XCTAssertEqual(resolve(system: "file://localhost/Users/someone/Shots"),
                       "/Users/someone/Shots")
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
