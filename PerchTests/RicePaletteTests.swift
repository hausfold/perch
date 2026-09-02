import SwiftUI
import XCTest
@testable import Perch

final class RicePaletteTests: XCTestCase {
    private var themes: URL!

    override func setUpWithError() throws {
        themes = FileManager.default.temporaryDirectory
            .appending(path: "PerchThemes-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: themes)
    }

    private func write(_ name: String, _ map: [String: String]) throws {
        let data = try JSONSerialization.data(withJSONObject: map)
        try data.write(to: themes.appending(path: "\(name).json"))
    }

    /// A full nebelung variant file — every catppuccin role, of which perch
    /// uses seven. The extra keys must be ignored, not rejected: this is the
    /// file haus copies out of nebelung verbatim.
    private var nebelungFile: [String: String] {
        [
            "text": "d7d7d7", "subtext1": "c3c3c3", "subtext0": "aeaeae",
            "overlay1": "858585", "overlay0": "717171",
            "surface2": "5c5c5c", "surface1": "494949", "surface0": "343434",
            "base": "202020", "mantle": "191919", "crust": "121212",
            "pink": "f2c4e5", "mauve": "c9a8f1", "red": "ed8fa9",
            "maroon": "e6a3ad", "peach": "f5b58e", "yellow": "f7e2b5",
            "green": "abe1a6", "teal": "9be0d5", "sky": "91dbe8",
            "sapphire": "7dc6e7", "blue": "8db4f3", "lavender": "b5bff8",
        ]
    }

    // MARK: - Parsing

    func testParsesAFullNebelungFileAndIgnoresUnusedRoles() {
        let palette = RicePalette(name: "nebelung", hex: nebelungFile)
        XCTAssertNotNil(palette)
        XCTAssertFalse(palette!.isLight)
    }

    func testAcceptsHexWithOrWithoutHash() {
        var map = nebelungFile
        map["green"] = "#abe1a6"
        XCTAssertNotNil(RicePalette(name: "hashed", hex: map))
    }

    func testRejectsAMissingOrMalformedRole() {
        var missing = nebelungFile
        missing["green"] = nil
        XCTAssertNil(RicePalette(name: "truncated", hex: missing))

        var malformed = nebelungFile
        malformed["base"] = "not-a-color"
        XCTAssertNil(RicePalette(name: "mangled", hex: malformed))
    }

    func testPolarityComesFromTheBaseLuminance() {
        XCTAssertFalse(RicePalette.nebelung.isLight)
        XCTAssertFalse(RicePalette.nebelungHighContrast.isLight)
        XCTAssertTrue(RicePalette.nebelungLatte.isLight)
        XCTAssertTrue(RicePalette.nebelungLatteHighContrast.isLight)
    }

    // MARK: - Resolution

    func testUnknownNameFallsBackToCompiledNebelung() {
        XCTAssertEqual(RicePalette.named("gruvbox", themesDirectory: themes), .nebelung)
    }

    func testBuiltInVariantsResolveWithoutAnyFiles() {
        XCTAssertEqual(
            RicePalette.named("nebelung-latte", themesDirectory: themes),
            .nebelungLatte
        )
        XCTAssertEqual(
            RicePalette.named("nebelung-latte-high-contrast", themesDirectory: themes),
            .nebelungLatteHighContrast
        )
    }

    func testAFileShadowsTheBuiltInOfTheSameName() throws {
        var bumped = nebelungFile
        bumped["green"] = "00ff00"
        try write("nebelung", bumped)

        let palette = RicePalette.named("nebelung", themesDirectory: themes)
        XCTAssertEqual(palette.name, "nebelung")
        XCTAssertNotEqual(palette, .nebelung)
    }

    func testAMalformedFileFallsBackInsteadOfBreakingTheShelf() throws {
        try write("nebelung-latte", ["base": "f1f1f1"])
        XCTAssertEqual(
            RicePalette.named("nebelung-latte", themesDirectory: themes),
            .nebelungLatte
        )
    }

    func testRuntimeOnlyPaletteResolves() throws {
        try write("gruvbox", nebelungFile)
        XCTAssertEqual(RicePalette.named("gruvbox", themesDirectory: themes).name, "gruvbox")
    }

    func testNamesThatCouldWalkOutOfTheThemesDirectoryAreRefused() throws {
        XCTAssertNil(RicePalette.loaded("../config", in: themes))
        XCTAssertNil(RicePalette.loaded(".hidden", in: themes))
        XCTAssertNil(RicePalette.loaded("", in: themes))
    }

    // MARK: - What haus writes

    func testConfigNamesThePairAndTheAppearancePicksTheHalf() {
        let defaults = RiceThemeDefaults(
            themeDark: "nebelung-high-contrast",
            themeLight: "nebelung-latte-high-contrast"
        )
        XCTAssertEqual(
            RiceTheme.name(systemIsLight: false, defaults: defaults),
            "nebelung-high-contrast"
        )
        XCTAssertEqual(
            RiceTheme.name(systemIsLight: true, defaults: defaults),
            "nebelung-latte-high-contrast"
        )
    }

    func testWithoutAConfigTheCompiledNebelungPairApplies() {
        XCTAssertEqual(RiceTheme.name(systemIsLight: false, defaults: nil), "nebelung")
        XCTAssertEqual(RiceTheme.name(systemIsLight: true, defaults: nil), "nebelung-latte")
    }

    func testAHalfWrittenConfigOnlyOverridesItsOwnPolarity() {
        let pinnedDark = RiceThemeDefaults(themeDark: "nebelung-high-contrast", themeLight: nil)
        XCTAssertEqual(
            RiceTheme.name(systemIsLight: false, defaults: pinnedDark),
            "nebelung-high-contrast"
        )
        XCTAssertEqual(RiceTheme.name(systemIsLight: true, defaults: pinnedDark), "nebelung-latte")

        let empty = RiceThemeDefaults(themeDark: "", themeLight: "")
        XCTAssertEqual(RiceTheme.name(systemIsLight: false, defaults: empty), "nebelung")
    }

    func testConfigFileDecodesAndSurvivesGarbage() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "PerchConfig-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "config.json")

        XCTAssertNil(RiceThemeDefaults.load(from: url))

        try Data(#"{"themeDark":"nebelung","themeLight":"nebelung-latte"}"#.utf8).write(to: url)
        XCTAssertEqual(
            RiceThemeDefaults.load(from: url),
            RiceThemeDefaults(themeDark: "nebelung", themeLight: "nebelung-latte")
        )

        // A future haus key perch does not know about must not break the file.
        try Data(#"{"themeDark":"nebelung","accent":"mauve"}"#.utf8).write(to: url)
        XCTAssertEqual(RiceThemeDefaults.load(from: url)?.themeDark, "nebelung")

        try Data("not json".utf8).write(to: url)
        XCTAssertNil(RiceThemeDefaults.load(from: url))
    }

    func testPaletteResolutionEndToEnd() throws {
        try write("nebelung-latte", nebelungFile)  // a dark palette under a light name
        let defaults = RiceThemeDefaults(themeDark: "nebelung", themeLight: "nebelung-latte")

        let light = RiceTheme.palette(
            systemIsLight: true,
            defaults: defaults,
            themesDirectory: themes
        )
        // The file wins over the built-in, so the "light" slot really is what
        // haus dropped there — including its polarity.
        XCTAssertEqual(light.name, "nebelung-latte")
        XCTAssertFalse(light.isLight)
    }

    // MARK: - Painting helpers

    func testShadowsThinOutOnALightPalette() {
        XCTAssertEqual(RicePalette.nebelung.shadow(0.4), .black.opacity(0.4))
        XCTAssertEqual(RicePalette.nebelungLatte.shadow(0.4), .black.opacity(0.4 * 0.35))
    }

    func testAccentLabelColorFollowsTheFillNotThePanel() {
        // Stock nebelung: a pastel accent on a dark panel wants dark ink.
        XCTAssertEqual(RicePalette.nebelung.onAccent, RicePalette.nebelung.crust)
        XCTAssertEqual(RicePalette.nebelung.onRed, RicePalette.nebelung.crust)
        // Latte: saturated accents, light ink.
        XCTAssertEqual(RicePalette.nebelungLatte.onAccent, RicePalette.nebelungLatte.base)
        XCTAssertEqual(RicePalette.nebelungLatte.onRed, RicePalette.nebelungLatte.base)

        // The combination stock palettes never produce: a *pale* accent on a
        // *light* panel. Reaching for crust there would be light grey on pale
        // green; the ink has to come from the dark end of a latte instead.
        let pale = RicePalette.nebelungLatte.accented(by: "#abe1a6")
        XCTAssertEqual(pale.onAccent, RicePalette.nebelungLatte.text)

        // And its mirror: a deep accent on a dark panel wants light ink, where
        // the palette's own pastel green wanted `crust`.
        let deep = RicePalette.nebelung.accented(by: "#1e3a8a")
        XCTAssertEqual(deep.onAccent, RicePalette.nebelung.text)
    }

    // MARK: - The accent

    func testTheDefaultAccentIsTheMarkGreen() {
        XCTAssertEqual(RicePalette.nebelung.accent, RicePalette.nebelung.green)
        XCTAssertEqual(RicePalette.nebelungLatte.accent, RicePalette.nebelungLatte.green)
    }

    func testARoleNameResolvesAgainstThePaletteInForce() throws {
        try write("nebelung", nebelungFile)
        let palette = RicePalette.named("nebelung", themesDirectory: themes)
            .accented(by: "mauve")
        XCTAssertEqual(palette.accent, Color(.sRGB, red: 0xC9 / 255, green: 0xA8 / 255, blue: 0xF1 / 255))
        // Everything else about the palette is untouched.
        XCTAssertEqual(palette.green, RicePalette.nebelung.green)
    }

    func testALiteralHexWorksForAStandaloneInstall() {
        let palette = RicePalette.nebelung.accented(by: "#8db4f3")
        XCTAssertEqual(palette.accent, Color(.sRGB, red: 0x8D / 255, green: 0xB4 / 255, blue: 0xF3 / 255))
        XCTAssertEqual(RicePalette.nebelung.accented(by: "8db4f3").accent, palette.accent)
    }

    func testAnUnresolvableAccentLeavesTheShelfOnGreen() {
        // A role the compiled-in table doesn't carry (it has only the seven
        // perch paints with), a typo, and nothing at all.
        XCTAssertEqual(RicePalette.nebelung.accented(by: "mauve").accent, RicePalette.nebelung.green)
        XCTAssertEqual(RicePalette.nebelung.accented(by: "chartreuse").accent, RicePalette.nebelung.green)
        XCTAssertEqual(RicePalette.nebelung.accented(by: "").accent, RicePalette.nebelung.green)
        XCTAssertEqual(RicePalette.nebelung.accented(by: nil).accent, RicePalette.nebelung.green)
    }

    func testTheRiceAccentReachesTheResolvedPalette() throws {
        try write("nebelung", nebelungFile)
        try write("nebelung-latte", nebelungFile.merging(["green": "4a9e3a", "teal": "179299"]) { _, new in new })
        let defaults = RiceThemeDefaults(
            themeDark: "nebelung",
            themeLight: "nebelung-latte",
            accent: "teal"
        )

        let dark = RiceTheme.palette(systemIsLight: false, defaults: defaults, themesDirectory: themes)
        let light = RiceTheme.palette(systemIsLight: true, defaults: defaults, themesDirectory: themes)

        // One key, resolved against whichever half is in force — so the accent
        // is that flavor's teal on each side, not one hex on both.
        XCTAssertEqual(dark.accent, Color(.sRGB, red: 0x9B / 255, green: 0xE0 / 255, blue: 0xD5 / 255))
        XCTAssertEqual(light.accent, Color(.sRGB, red: 0x17 / 255, green: 0x92 / 255, blue: 0x99 / 255))
    }

    func testConfigFileCarriesTheAccent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "PerchConfig-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "config.json")

        try Data(#"{"themeDark":"nebelung","themeLight":"nebelung-latte","accent":"mauve"}"#.utf8)
            .write(to: url)
        XCTAssertEqual(RiceThemeDefaults.load(from: url)?.accent, "mauve")

        // A desktop that predates the option, or a standalone install: no key.
        try Data(#"{"themeDark":"nebelung"}"#.utf8).write(to: url)
        XCTAssertNil(RiceThemeDefaults.load(from: url)?.accent)
    }
}
