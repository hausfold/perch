import XCTest
@testable import Perch

/// The rule that decides whether perch tells someone their drags are being
/// eaten. Only the pure part is testable here: reading `com.apple.dock` needs
/// the sandbox exception and a real Dock, and the test host is the app.
final class MissionControlCheckTests: XCTestCase {
    /// The whole point of the check. macOS ships "Drag windows to top of screen
    /// to enter Mission Control" ON, and a Mac that has never had the key
    /// written reads as absent — so absent must mean armed, or the one hint
    /// that saves a stock Mac's first drag never fires on a stock Mac.
    func testAbsentPreferenceReadsAsArmed() {
        XCTAssertTrue(MissionControlCheck.isArmed(dockPreference: nil))
    }

    /// A denied read is indistinguishable from an absent key — both arrive here
    /// as nil. Pinning them to the same answer records the deliberate choice:
    /// if the entitlement is ever dropped, perch shows a dismissible hint
    /// rather than silently letting every drag fail.
    func testExplicitValuesWin() {
        XCTAssertTrue(MissionControlCheck.isArmed(dockPreference: true))
        XCTAssertFalse(MissionControlCheck.isArmed(dockPreference: false))
    }

    /// The haus desktop writes `false` whenever `haus.shelf.enable` is on, so a
    /// rice install must never see the strip or the menu row.
    func testRiceInstallIsNotArmed() {
        XCTAssertFalse(MissionControlCheck.isArmed(dockPreference: false))
    }

    /// The pane id the button opens. Read off
    /// /System/Library/ExtensionKit/Extensions/DesktopSettings.appex on macOS
    /// 26 — System Settings is ExtensionKit panes now, and the old
    /// `com.apple.preference.dock` prefPane id is gone.
    func testSettingsURLNamesTheDesktopAndDockPane() {
        XCTAssertEqual(
            MissionControlCheck.settingsURL.absoluteString,
            "x-apple.systempreferences:com.apple.Desktop-Settings.extension"
        )
    }

    /// The domain and key perch reads, pinned because the entitlement in
    /// Perch.entitlements names the same domain by hand — a rename in one place
    /// and not the other is a check that silently answers nil forever.
    func testReadsTheDockDomain() {
        XCTAssertEqual(MissionControlCheck.dockDomain, "com.apple.dock")
        XCTAssertEqual(MissionControlCheck.dockKey, "enterMissionControlByTopWindowDrag")
    }
}
