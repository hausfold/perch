import SwiftUI
import XCTest
@testable import Perch

/// The family perch draws in is one string in `~/.config/perch/config.json`,
/// and everything interesting about it happens before a `Font` exists: what
/// counts as "no family", and which names mean macOS's own. Those are the
/// answers a view body can't be asked for, so they are pure and they live here.
final class ShelfFontTests: XCTestCase {
    func testAnUnnamedFamilyIsTheSystemFont() {
        XCTAssertNil(ShelfFont.resolve(nil))
        XCTAssertNil(ShelfFont.resolve(""))
        XCTAssertNil(ShelfFont.resolve("   "))
    }

    /// The case a desktop generating this file actually hits: it writes the
    /// family it was configured with, and the usual default *is* macOS's own.
    /// `Font.custom(".AppleSystemUIFont", …)` would draw — and would freeze the
    /// optical size and weight SwiftUI picks per text style, so "left at the
    /// default" would render subtly unlike leaving the key out.
    func testTheSystemFontsOwnNamesResolveToTheSystemFont() {
        XCTAssertNil(ShelfFont.resolve(".AppleSystemUIFont"))
        XCTAssertNil(ShelfFont.resolve("system"))
        XCTAssertNil(ShelfFont.resolve("-apple-system"))
    }

    func testANamedFamilyIsPassedThroughVerbatimAndTrimmed() {
        XCTAssertEqual(ShelfFont.resolve("Atkinson Hyperlegible"), "Atkinson Hyperlegible")
        XCTAssertEqual(ShelfFont.resolve("  Inter \n"), "Inter")
    }

    /// The claim the whole change rests on: a perch nobody named a family for
    /// draws in exactly the `Font`s it drew before this key existed, not in a
    /// look-alike. `Font` is `Equatable`, so this is checkable.
    func testWithNoFamilyEveryCallIsTheFontPerchAlreadyDrew() {
        for style: Font.TextStyle in [.caption2, .caption, .footnote, .subheadline, .callout, .body, .headline, .title3, .title2] {
            XCTAssertEqual(ShelfFont.style(style, family: nil), .system(style))
        }
        XCTAssertEqual(ShelfFont.size(19, weight: .semibold, family: nil), .system(size: 19, weight: .semibold))
        XCTAssertEqual(ShelfFont.size(11, family: nil), .system(size: 11))
    }

    /// With one named, the style keeps macOS's own point size for that style
    /// rather than a number written down in perch — a hard-coded table would be
    /// right until Apple moved one — and asks the face for the semibold the
    /// system face gives `.headline` away free.
    func testANamedFamilyKeepsTheStylesOwnSizeAndWeight() {
        XCTAssertEqual(
            ShelfFont.style(.headline, family: "Helvetica"),
            .custom("Helvetica", size: ShelfFont.pointSize(of: .headline), relativeTo: .headline).weight(.semibold)
        )
        XCTAssertEqual(
            ShelfFont.style(.callout, family: "Helvetica"),
            .custom("Helvetica", size: ShelfFont.pointSize(of: .callout), relativeTo: .callout).weight(.regular)
        )
        XCTAssertEqual(ShelfFont.size(22, family: "Helvetica"), .custom("Helvetica", fixedSize: 22))
        XCTAssertNotEqual(ShelfFont.style(.body, family: "Helvetica"), .system(.body))
    }

    func testOnlyHeadlineCarriesAWeightOfItsOwn() {
        XCTAssertEqual(ShelfFont.weight(of: .headline), .semibold)
        for style: Font.TextStyle in [.caption2, .caption, .footnote, .subheadline, .callout, .body, .title3, .title2] {
            XCTAssertEqual(ShelfFont.weight(of: style), .regular)
        }
    }

    /// The key rides in beside the palette names and the accent, and a file
    /// that predates it — a standalone install, or a desktop that hasn't been
    /// rebuilt — is not a broken file.
    func testTheFamilyIsReadOutOfTheSameConfigFileHausAlreadyWrites() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "PerchFont-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "config.json")

        try Data(#"{"themeDark":"nebelung","fontFamily":"Atkinson Hyperlegible"}"#.utf8).write(to: url)
        XCTAssertEqual(RiceThemeDefaults.load(from: url)?.fontFamily, "Atkinson Hyperlegible")

        try Data(#"{"themeDark":"nebelung"}"#.utf8).write(to: url)
        XCTAssertNil(RiceThemeDefaults.load(from: url)?.fontFamily)
    }
}
