import XCTest
@testable import Perch

final class UpdateCheckTests: XCTestCase {

    // MARK: - Cohort detection
    //
    // The trap these pin: the rice (modules/perch, postActivation) and a
    // Homebrew cask BOTH end up at /Applications/Perch.app, so the path alone
    // can't tell them apart from a drag-install. The receipts do — when the
    // sandbox lets them be read.

    func testNixStorePathIsNix() {
        XCTAssertEqual(
            InstallKind.detect(
                bundlePath: "/nix/store/abc123-perch-2026.08.01/Applications/Perch.app",
                home: "/Users/testuser",
                hasRiceMarker: false,
                hasCaskReceipt: false
            ),
            .nix
        )
    }

    func testRiceMarkerWinsOverTheSharedApplicationsPath() {
        XCTAssertEqual(
            InstallKind.detect(
                bundlePath: "/Applications/Perch.app",
                home: "/Users/testuser",
                hasRiceMarker: true,
                hasCaskReceipt: false
            ),
            .rice
        )
    }

    /// A machine that has been both keeps taking updates from the rice: its
    /// activation script reinstalls the bundle on every rebuild.
    func testRiceMarkerOutranksALeftoverCaskReceipt() {
        XCTAssertEqual(
            InstallKind.detect(
                bundlePath: "/Applications/Perch.app",
                home: "/Users/testuser",
                hasRiceMarker: true,
                hasCaskReceipt: true
            ),
            .rice
        )
    }

    func testCaskReceiptMakesApplicationsAHomebrewInstall() {
        XCTAssertEqual(
            InstallKind.detect(
                bundlePath: "/Applications/Perch.app",
                home: "/Users/testuser",
                hasRiceMarker: false,
                hasCaskReceipt: true
            ),
            .homebrew
        )
    }

    func testApplicationsWithoutAnyReceiptIsADragInstall() {
        for path in ["/Applications/Perch.app", "/Users/testuser/Applications/Perch.app"] {
            XCTAssertEqual(
                InstallKind.detect(
                    bundlePath: path,
                    home: "/Users/testuser",
                    hasRiceMarker: false,
                    hasCaskReceipt: false
                ),
                .direct,
                path
            )
        }
    }

    /// A marker is only the rice's when the bundle sits where the rice puts it.
    func testUserApplicationsIsNotClaimedByTheRiceMarker() {
        XCTAssertEqual(
            InstallKind.detect(
                bundlePath: "/Users/testuser/Applications/Perch.app",
                home: "/Users/testuser",
                hasRiceMarker: true,
                hasCaskReceipt: false
            ),
            .direct
        )
    }

    func testCaskroomPathStillResolves() {
        XCTAssertEqual(
            InstallKind.detect(
                bundlePath: "/opt/homebrew/Caskroom/perch/2026.08.01/Perch.app",
                home: "/Users/testuser",
                hasRiceMarker: false,
                hasCaskReceipt: true
            ),
            .homebrew
        )
    }

    /// The sandbox backstop: both receipts live outside perch's container, so
    /// `fileExists` may answer false for a receipt that is really there. The
    /// rice's theme drop — the one path the entitlements do grant — then stands
    /// in for the marker, and only at the rice's own install path.
    func testTheRiceThemeDropStandsInForAnUnreadableMarker() {
        XCTAssertEqual(
            InstallKind.detect(
                bundlePath: "/Applications/Perch.app",
                home: "/Users/testuser",
                hasRiceMarker: false,
                hasCaskReceipt: false,
                hasRiceThemeDrop: true
            ),
            .rice
        )
        // A drop next to a drag-install in ~/Applications proves nothing: the
        // rice only ever installs to /Applications.
        XCTAssertEqual(
            InstallKind.detect(
                bundlePath: "/Users/testuser/Applications/Perch.app",
                home: "/Users/testuser",
                hasRiceMarker: false,
                hasCaskReceipt: false,
                hasRiceThemeDrop: true
            ),
            .direct
        )
        // A readable cask receipt outranks the drop — it is the stronger signal.
        XCTAssertEqual(
            InstallKind.detect(
                bundlePath: "/Applications/Perch.app",
                home: "/Users/testuser",
                hasRiceMarker: false,
                hasCaskReceipt: true,
                hasRiceThemeDrop: true
            ),
            .homebrew
        )
    }

    /// A build running out of DerivedData is nobody's install.
    func testUnknownPathIsUnknown() {
        XCTAssertEqual(
            InstallKind.detect(
                bundlePath: "/Users/testuser/Library/Developer/Xcode/DerivedData/Perch-abc/Build/Products/Debug/Perch.app",
                home: "/Users/testuser",
                hasRiceMarker: false,
                hasCaskReceipt: false
            ),
            .unknown
        )
    }

    // MARK: - Cohort copy
    //
    // Perch is sandboxed, so NO cohort self-updates: the button
    // either copies this install's command or opens the release page. A cohort
    // handed the wrong command is the only way this feature can mislead.

    func testNoCohortIsOfferedASelfUpdate() {
        for kind in InstallKind.allCases {
            XCTAssertNotEqual(kind.buttonLabel, "Update & Restart", "\(kind)")
        }
    }

    func testEachCohortGetsItsOwnNextStep() {
        XCTAssertEqual(InstallKind.rice.updateCommand, "haus update")
        XCTAssertEqual(InstallKind.nix.updateCommand, "nix flake update perch")
        XCTAssertEqual(InstallKind.homebrew.updateCommand, "brew upgrade --cask perch")
        // Nothing to run — these open the release page instead.
        XCTAssertNil(InstallKind.direct.updateCommand)
        XCTAssertNil(InstallKind.unknown.updateCommand)

        XCTAssertEqual(InstallKind.rice.buttonLabel, "Copy Command")
        XCTAssertEqual(InstallKind.nix.buttonLabel, "Copy Command")
        XCTAssertEqual(InstallKind.homebrew.buttonLabel, "Copy Command")
        XCTAssertEqual(InstallKind.direct.buttonLabel, "Open Releases")
        XCTAssertEqual(InstallKind.unknown.buttonLabel, "Open Releases")
    }

    /// The hint under the version is the one line the user acts on, so it has to
    /// say the same thing the button does.
    func testHintsAgreeWithTheButton() {
        XCTAssertTrue(InstallKind.rice.actionHint.contains("haus update"))
        XCTAssertTrue(InstallKind.nix.actionHint.contains("flake input"))
        XCTAssertTrue(InstallKind.homebrew.actionHint.contains("brew upgrade --cask perch"))
        for kind in InstallKind.allCases {
            XCTAssertFalse(kind.actionHint.isEmpty, "\(kind)")
            XCTAssertFalse(kind.settingsNote.isEmpty, "\(kind)")
        }
    }

    // MARK: - Version ordering

    func testIsNewerCalVerComparison() {
        XCTAssertTrue(UpdateCheck.isNewer("2026.08.01", than: "2026.07.31"))
        XCTAssertTrue(UpdateCheck.isNewer("2026.07.31", than: "2026.07.30"))

        XCTAssertFalse(UpdateCheck.isNewer("2026.07.30", than: "2026.07.30"))
        XCTAssertFalse(UpdateCheck.isNewer("2026.07.29", than: "2026.07.30"))

        // Same-day repeats compare numerically — a string compare would put
        // "-10" before "-2" and silently never nudge.
        XCTAssertTrue(UpdateCheck.isNewer("2026.07.31-2", than: "2026.07.31-1"))
        XCTAssertTrue(UpdateCheck.isNewer("2026.07.31-10", than: "2026.07.31-2"))
        XCTAssertTrue(UpdateCheck.isNewer("2026.07.31-1", than: "2026.07.31"))
        XCTAssertFalse(UpdateCheck.isNewer("2026.07.31-1", than: "2026.07.31-2"))
        XCTAssertFalse(UpdateCheck.isNewer("2026.07.31-1", than: "2026.07.31-1"))
    }

    /// Neither an Xcode build nor a `bench try` branch build ever gets nudged —
    /// "updating" one means throwing the branch away. The project's placeholder
    /// `MARKETING_VERSION` (0.1.0) is the case a naive rule would miss: it
    /// isn't "dev" and it isn't suffixed, and every release sorts above it.
    func testDevBuildsAreNeverNewerThan() {
        XCTAssertTrue(UpdateCheck.isDevVersion("dev"))
        XCTAssertTrue(UpdateCheck.isDevVersion(""))
        XCTAssertTrue(UpdateCheck.isDevVersion("2026.08.01-dev"))
        XCTAssertTrue(UpdateCheck.isDevVersion("0.1.0"))
        XCTAssertFalse(UpdateCheck.isDevVersion("2026.08.01"))
        XCTAssertFalse(UpdateCheck.isDevVersion("2026.08.01-2"))

        XCTAssertFalse(UpdateCheck.isNewer("2026.08.05", than: "dev"))
        XCTAssertFalse(UpdateCheck.isNewer("2026.08.05", than: "2026.08.01-dev"))
        XCTAssertFalse(UpdateCheck.isNewer("2026.08.05", than: "0.1.0"))
    }

    // MARK: - Dismissal

    func testShouldPinAndDismissalExpiration() {
        XCTAssertTrue(UpdateCheck.shouldPin(available: "2026.08.01", dismissed: nil))
        XCTAssertFalse(UpdateCheck.shouldPin(available: "2026.08.01", dismissed: "2026.08.01"))
        // A dismissal must expire when a newer release lands, or "dismiss until
        // the next release" quietly becomes "never tell me again".
        XCTAssertTrue(UpdateCheck.shouldPin(available: "2026.08.05", dismissed: "2026.08.01"))
        XCTAssertFalse(UpdateCheck.shouldPin(available: nil, dismissed: "2026.08.01"))
    }

    // MARK: - Endpoint

    func testEndpointIsPerchsOwnRepo() {
        XCTAssertEqual(
            UpdateCheck.endpoint.absoluteString,
            "https://api.github.com/repos/hausfold/perch/releases/latest"
        )
        XCTAssertEqual(
            UpdateCheck.releasesURL.absoluteString,
            "https://github.com/hausfold/perch/releases/latest"
        )
    }
}
