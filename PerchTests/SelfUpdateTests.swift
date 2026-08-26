import XCTest
@testable import Perch

/// The one-click update for the drag-install cohort. What is pinned here is the
/// half that decides *whether* to install and *what* — the swap itself lives in
/// `PerchUpdater`, outside this test host, and is feel-tested (see
/// `docs/feel-testing.md`).
final class SelfUpdateTests: XCTestCase {

    // MARK: - Who gets the click
    //
    // The trap: a cohort whose bytes belong to a package manager. Self-updating
    // a rice or cask install replaces a bundle `haus update` / `brew upgrade`
    // owns, and the next activation silently puts the old build back — an
    // update that un-happens is worse than one that never offered.

    func testOnlyTheDragInstallCohortSelfUpdates() {
        XCTAssertTrue(InstallKind.direct.canSelfUpdate)
        for kind in [InstallKind.homebrew, .rice, .nix, .unknown] {
            XCTAssertFalse(kind.canSelfUpdate, "\(kind) must not replace its own bundle")
        }
    }

    func testEveryOtherCohortStillGetsItsOwnCommand() {
        XCTAssertEqual(InstallKind.homebrew.updateCommand, "brew upgrade --cask perch")
        XCTAssertEqual(InstallKind.rice.updateCommand, "haus update")
        XCTAssertEqual(InstallKind.nix.updateCommand, "nix flake update perch")
        XCTAssertNil(InstallKind.direct.updateCommand)
        XCTAssertEqual(InstallKind.direct.buttonLabel, "Update Now")
        XCTAssertEqual(InstallKind.unknown.buttonLabel, "Open Releases")
    }

    // MARK: - What the updater may replace
    //
    // The security argument for shipping an un-sandboxed helper at all: it can
    // name exactly one target, derived from where it is, and a request naming
    // anything else is refused.

    func testTheUpdaterResolvesTheBundleItIsNestedIn() {
        XCTAssertEqual(
            UpdateHandoff.enclosingAppBundle(
                ofUpdaterAt: URL(fileURLWithPath: "/Applications/Perch.app/Contents/Library/PerchUpdater.app")
            ),
            URL(fileURLWithPath: "/Applications/Perch.app")
        )
    }

    func testAnUpdaterSomewhereElseResolvesNothing() {
        // Loose in a folder, or nested at the wrong depth: both must answer nil
        // rather than name a neighbour.
        XCTAssertNil(
            UpdateHandoff.enclosingAppBundle(ofUpdaterAt: URL(fileURLWithPath: "/tmp/PerchUpdater.app"))
        )
        XCTAssertNil(
            UpdateHandoff.enclosingAppBundle(
                ofUpdaterAt: URL(fileURLWithPath: "/Applications/Perch.app/Contents/MacOS/PerchUpdater.app")
            )
        )
        XCTAssertNil(
            UpdateHandoff.enclosingAppBundle(
                ofUpdaterAt: URL(fileURLWithPath: "/Users/someone/Downloads/Library/PerchUpdater.app")
            )
        )
    }

    // MARK: - The handoff file
    //
    // Two processes, two different ideas of `~`: the app is sandboxed and sees
    // its container, the updater is not and sees the real home. They must land
    // on the same file.

    func testBothSidesDeriveTheSameRequestPath() {
        let realHome = URL(fileURLWithPath: "/Users/testuser")
        let container = UpdateHandoff.containerHome(appBundleID: "com.hausfold.perch", realHome: realHome)
        XCTAssertEqual(container.path, "/Users/testuser/Library/Containers/com.hausfold.perch/Data")
        // What the app computes from NSHomeDirectory() inside the sandbox…
        let fromApp = UpdateHandoff.requestURL(home: container)
        // …and what the updater computes from the outside.
        let fromUpdater = UpdateHandoff.requestURL(
            home: UpdateHandoff.containerHome(appBundleID: "com.hausfold.perch", realHome: realHome)
        )
        XCTAssertEqual(fromApp, fromUpdater)
        XCTAssertEqual(
            fromApp.path,
            "/Users/testuser/Library/Containers/com.hausfold.perch/Data/Library/Application Support/Perch/update-request.json"
        )
    }

    func testTheRequestSurvivesTheRoundTrip() throws {
        let request = UpdateRequest(
            version: "2026.08.26",
            payloadPath: "/Users/testuser/Library/Containers/com.hausfold.perch/Data/Library/Caches/Updates/unpacked/Perch.app",
            targetPath: "/Applications/Perch.app",
            appPID: 4242,
            relaunch: true,
            requestedAt: 1_772_000_000
        )
        let decoded = try JSONDecoder().decode(
            UpdateRequest.self, from: JSONEncoder().encode(request)
        )
        XCTAssertEqual(decoded, request)
    }

    func testTheResultSurvivesTheRoundTrip() throws {
        let result = UpdateResult(
            version: "2026.08.26", succeeded: true,
            message: "Updated to Perch 2026.08.26", finishedAt: 1_772_000_042
        )
        let decoded = try JSONDecoder().decode(
            UpdateResult.self, from: JSONEncoder().encode(result)
        )
        XCTAssertEqual(decoded, result)
    }

    // MARK: - Picking the download

    private func release(tag: String, assets: [(String, String)]) -> [String: Any] {
        [
            "tag_name": tag,
            "assets": assets.map { ["name": $0.0, "browser_download_url": $0.1] },
        ]
    }

    func testPicksTheMacZipFromTheRelease() throws {
        let url = try SelfUpdate.selectAsset(
            from: release(tag: "v2026.08.26", assets: [
                ("perch-v2026.08.26-macos.zip",
                 "https://github.com/hausfold/perch/releases/download/v2026.08.26/perch-v2026.08.26-macos.zip"),
            ]),
            version: "2026.08.26"
        )
        XCTAssertEqual(url.host, "github.com")
        XCTAssertTrue(url.path.hasSuffix("perch-v2026.08.26-macos.zip"))
    }

    func testRefusesWhenTheReleaseMovedOnUnderUs() {
        // The nudge offered .26; by the time the click landed, .27 was latest.
        // Installing .27 silently would be installing something nobody offered.
        XCTAssertThrowsError(
            try SelfUpdate.selectAsset(
                from: release(tag: "v2026.08.27", assets: [
                    ("perch-v2026.08.27-macos.zip",
                     "https://github.com/hausfold/perch/releases/download/v2026.08.27/perch-v2026.08.27-macos.zip"),
                ]),
                version: "2026.08.26"
            )
        )
    }

    func testRefusesADownloadThatIsNotOnGitHub() {
        XCTAssertThrowsError(
            try SelfUpdate.selectAsset(
                from: release(tag: "v2026.08.26", assets: [
                    ("perch-v2026.08.26-macos.zip", "https://cdn.example.com/perch.zip"),
                ]),
                version: "2026.08.26"
            )
        )
        XCTAssertThrowsError(
            try SelfUpdate.selectAsset(
                from: release(tag: "v2026.08.26", assets: [
                    ("perch-v2026.08.26-macos.zip", "http://github.com/hausfold/perch/perch.zip"),
                ]),
                version: "2026.08.26"
            )
        )
    }

    func testRefusesAReleaseWithNoMacDownload() {
        XCTAssertThrowsError(
            try SelfUpdate.selectAsset(
                from: release(tag: "v2026.08.26", assets: [
                    ("perch-v2026.08.26-ios.ipa",
                     "https://github.com/hausfold/perch/releases/download/v2026.08.26/perch-v2026.08.26-ios.ipa"),
                ]),
                version: "2026.08.26"
            )
        )
    }

    // MARK: - The requirement the download must satisfy
    //
    // A literal, because a requirement assembled at runtime from the running
    // bundle's own signature would be satisfied by whatever signed that bundle.

    func testThePayloadRequirementNamesOurTeamAndNotarization() {
        XCTAssertEqual(PerchSigning.teamID, "88M28542LQ")
        XCTAssertTrue(PerchSigning.payloadRequirement.contains("88M28542LQ"))
        XCTAssertTrue(PerchSigning.payloadRequirement.contains("notarized"))
        XCTAssertTrue(PerchSigning.payloadRequirement.contains("anchor apple generic"))
    }

    func testAnUnsignedBundleFailsVerification() throws {
        // The test host itself: built here, ad-hoc or dev signed, never
        // notarized — exactly the thing that must not be allowed to install.
        XCTAssertThrowsError(try PerchSigning.verify(bundle: Bundle.main.bundleURL))
    }

    // MARK: - Version rules, shared with the updater

    func testTheUpdaterAndTheNudgeAgreeOnWhatIsNewer() {
        // Same two functions, so a downgrade the nudge would never offer is one
        // the updater would never install either.
        XCTAssertEqual(CalVer.isNewer("2026.08.26", than: "2026.08.25"), UpdateCheck.isNewer("2026.08.26", than: "2026.08.25"))
        XCTAssertTrue(CalVer.isNewer("2026.08.25-10", than: "2026.08.25-2"))
        XCTAssertFalse(CalVer.isNewer("2026.08.25", than: "2026.08.26"))
        XCTAssertTrue(CalVer.isDev("0.1.0"))
        XCTAssertTrue(CalVer.isDev("2026.08.26-dev"))
        XCTAssertFalse(CalVer.isDev("2026.08.26-2"))
    }
}
