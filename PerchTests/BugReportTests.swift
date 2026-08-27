import XCTest
@testable import Perch

final class BugReportTests: XCTestCase {

    // MARK: - The template is the whole point
    //
    // These pin the one mistake that makes the menu row worthless without
    // looking broken: a URL that opens GitHub's *blank* editor instead of the
    // generated form. It still opens an issue, so nothing fails — the reporter
    // just never sees the fields, the preamble or the labels. Pounce's palette
    // command shipped that version for a year.

    func testFormURLNamesTheTemplate() {
        let url = BugReport.destination(diagnostics: "Perch dev").url
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "template" }?.value, "bug.yml")
    }

    func testDiagnosticsRideInTheQueryAndNotThePasteboard() {
        let destination = BugReport.destination(diagnostics: "Perch 2026.08.20 (homebrew)")
        XCTAssertNil(destination.pasteboard)
        let query = URLComponents(url: destination.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "diagnostics" }?.value, "Perch 2026.08.20 (homebrew)")
    }

    func testNewlinesSurviveEncoding() {
        let block = "Perch 2026.08.20 (direct)\nmacOS 26.0.1 (25A354)\nMac16,10"
        let destination = BugReport.destination(diagnostics: block)
        let query = URLComponents(url: destination.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "diagnostics" }?.value, block)
    }

    // MARK: - `+` is the one that bites
    //
    // `URLComponents.queryItems` encodes with `CharacterSet.urlQueryAllowed`,
    // which contains `+` — so it leaves it literal, and a literal `+` in a
    // query decodes as a SPACE at the far end. Perch's own block has none;
    // pounce puts hotkey combos (`cmd+space`) through the same field and the
    // shape is shared, so this pins the strict encoder rather than trusting
    // that perch will never grow a plus.

    func testAPlusIsEncodedRatherThanArrivingAsASpace() {
        let url = BugReport.destination(diagnostics: "hotkey cmd+space").url.absoluteString
        XCTAssertTrue(url.contains("cmd%2Bspace"), url)
        XCTAssertFalse(url.contains("cmd+space"), url)
    }

    func testTheAmpersandCannotStartASecondParameter() {
        let url = BugReport.destination(diagnostics: "a&template=nope").url
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.count, 2)
        XCTAssertEqual(query.first { $0.name == "template" }?.value, "bug.yml")
        XCTAssertEqual(query.first { $0.name == "diagnostics" }?.value, "a&template=nope")
    }

    // MARK: - The length guard
    //
    // GitHub refuses a URL past roughly 8 KB. Perch's block is ~150 bytes, so
    // this path is a guard rail rather than a live one — it exists so that the
    // day someone adds a log tail to `diagnostics()`, the row still opens a
    // form instead of a server error.

    func testAnOverlongBlockTravelsByPasteboardWithTheFormStillOpening() {
        let huge = String(repeating: "x", count: BugReport.maximumURLLength + 1)
        let destination = BugReport.destination(diagnostics: huge)
        XCTAssertEqual(destination.pasteboard, huge)
        XCTAssertLessThanOrEqual(destination.url.absoluteString.count, BugReport.maximumURLLength)
        let query = URLComponents(url: destination.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "template" }?.value, "bug.yml")
        XCTAssertNil(query.first { $0.name == "diagnostics" })
    }

    // MARK: - What lands in a public issue
    //
    // A reporter reads this block before they hit Submit, but they read it in a
    // form the app filled in — so it has to be a block nobody would want to
    // redact. No paths, no usernames, nothing off the shelf.

    func testDiagnosticsAreThreeLinesAndNameTheInstallCohort() {
        let block = BugReport.diagnostics(
            version: "2026.08.20",
            install: .rice,
            operatingSystem: "26.0.1 (25A354)",
            model: "Mac16,10"
        )
        XCTAssertEqual(block, """
            Perch 2026.08.20 (rice)
            macOS 26.0.1 (25A354)
            Mac16,10
            """)
    }

    func testTheLiveModelAndOSReadBackFromSysctl() {
        XCTAssertFalse(BugReport.currentModel.isEmpty)
        XCTAssertNotEqual(BugReport.currentModel, "unknown Mac")
        XCTAssertTrue(BugReport.currentOperatingSystem.contains("("), BugReport.currentOperatingSystem)
    }
}
