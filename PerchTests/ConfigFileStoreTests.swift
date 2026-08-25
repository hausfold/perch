import XCTest

@testable import Perch

/// The settings files are the source of truth, which makes these the tests that
/// say what "source of truth" actually means here: a partial file is normal, a
/// broken one changes nothing, a write keeps what perch didn't write, an edit
/// made while perch runs reaches the app — and the rice drop, which perch may
/// only ever read, wins over the file perch writes.
final class ConfigFileStoreTests: XCTestCase {
    private var directory: URL!
    private var file: URL!
    private var declaration: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("perch-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("settings.json")
        declaration = directory.appendingPathComponent("config.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ json: String, to url: URL) throws {
        try json.write(to: url, atomically: true, encoding: .utf8)
    }

    private func contents() throws -> [String: Any] {
        let data = try Data(contentsOf: file)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func makeStore() -> ConfigFileStore {
        ConfigFileStore(file: file, declaration: declaration)
    }

    // MARK: - The file perch writes

    func testNoFileMeansEverySettingIsAtItsDefault() {
        XCTAssertEqual(makeStore().current(), AppConfig())
    }

    func testAPartialFileLeavesTheRestAtTheirDefaults() throws {
        try write(#"{ "mobileEnabled": false }"#, to: file)
        let store = makeStore()
        XCTAssertFalse(store.current().mobileEnabled)
        XCTAssertTrue(store.current().showOnAllDisplays, "a key the file doesn't name is that key's default")
        XCTAssertEqual(store.namedKeys(), ["mobileEnabled"])
    }

    func testAWriteNamesEverySettingSoTheFileIsSelfDocumenting() throws {
        let store = makeStore()
        XCTAssertNil(store.update { $0.retentionDays = 7 })
        let json = try contents()
        XCTAssertEqual(json[AppConfig.Key.retentionDays] as? Int, 7)
        XCTAssertEqual(
            Set(json.keys),
            [
                AppConfig.Key.showOnAllDisplays, AppConfig.Key.retentionDays,
                AppConfig.Key.mobileEnabled, AppConfig.Key.automaticUpdateChecks,
            ],
            "every switch perch owns is written, not just the changed one"
        )
    }

    /// macOS holds this one, and a file perch wrote saying "yes" would be a
    /// standing instruction to put itself back into Login Items — the reason it
    /// is declaration-only.
    func testAWriteNeverNamesLaunchAtLogin() throws {
        let store = makeStore()
        XCTAssertNil(store.update { $0.showOnAllDisplays = false })
        XCTAssertNil(try contents()[AppConfig.Key.launchAtLogin])
    }

    func testAWriteKeepsKeysPerchDoesNotKnow() throws {
        try write(#"{ "somethingNewer": 42, "mobileEnabled": false }"#, to: file)
        let store = makeStore()
        XCTAssertNil(store.update { $0.showOnAllDisplays = false })
        XCTAssertEqual(try contents()["somethingNewer"] as? Int, 42)
        XCTAssertEqual(
            try contents()[AppConfig.Key.mobileEnabled] as? Bool, false,
            "and the setting it wasn't asked to change"
        )
    }

    func testAWriteThatChangesNothingIsNotAWrite() throws {
        let store = makeStore()
        XCTAssertNil(store.update { $0.showOnAllDisplays = AppConfig().showOnAllDisplays })
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: file.path),
            "no file is created for a change that isn't one"
        )
    }

    func testAMalformedFileKeepsThePreviousSettings() throws {
        try write(#"{ "mobileEnabled": false }"#, to: file)
        let store = makeStore()
        let expectation = expectation(description: "the store notices the file")
        expectation.isInverted = true
        store.start { _ in expectation.fulfill() }

        try write("{ this is not json", to: file)
        wait(for: [expectation], timeout: 1.5)
        XCTAssertFalse(store.current().mobileEnabled, "a typo must not turn a setting back on")
    }

    func testAnEditWhilePerchRunsReachesTheApp() throws {
        try write(#"{ "mobileEnabled": true }"#, to: file)
        let store = makeStore()
        let changed = expectation(description: "onChange fires with the edited value")
        store.start { config in
            if !config.mobileEnabled { changed.fulfill() }
        }

        try write(#"{ "mobileEnabled": false }"#, to: file)
        wait(for: [changed], timeout: 5)
        XCTAssertFalse(store.current().mobileEnabled)
    }

    /// The bug this is here for: the watcher re-arms after every write, and an
    /// implementation that closes its own descriptor while re-arming stops
    /// noticing edits after the *first* toggle — which is exactly the moment
    /// nobody re-tests by hand.
    func testTheWatcherStillFollowsTheFileAfterPerchWritesItItself() throws {
        let store = makeStore()
        let changed = expectation(description: "onChange fires after a self-write")
        store.start { config in
            if config.retentionDays == 3 { changed.fulfill() }
        }

        XCTAssertNil(store.update { $0.showOnAllDisplays = false })
        try write(#"{ "retentionDays": 3 }"#, to: file)
        wait(for: [changed], timeout: 5)
    }

    // MARK: - The file the rice declares

    func testADeclarationWinsOverPerchsOwnFile() throws {
        try write(#"{ "retentionDays": 7, "mobileEnabled": false }"#, to: file)
        try write(#"{ "retentionDays": 0 }"#, to: declaration)
        let store = makeStore()
        XCTAssertEqual(store.current().retentionDays, 0, "the declaration is the last word")
        XCTAssertFalse(store.current().mobileEnabled, "and says nothing about the keys it doesn't name")
    }

    func testADeclaredSettingIsRefusedRatherThanWritten() throws {
        try write(#"{ "showOnAllDisplays": false }"#, to: declaration)
        let store = makeStore()
        let error = store.update { $0.showOnAllDisplays = true }

        XCTAssertEqual(
            error as? ConfigWriteError,
            .declared(keys: [AppConfig.Key.showOnAllDisplays], file: declaration)
        )
        XCTAssertFalse(
            store.current().showOnAllDisplays,
            "refused before anything in memory moved — a second click must not appear to succeed"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: file.path),
            "and nothing was written to a file that would be overruled on the next read"
        )
    }

    func testASettingTheDeclarationIsSilentAboutStillWrites() throws {
        try write(#"{ "showOnAllDisplays": false }"#, to: declaration)
        let store = makeStore()
        XCTAssertNil(store.update { $0.retentionDays = 14 })
        XCTAssertEqual(try contents()[AppConfig.Key.retentionDays] as? Int, 14)
        XCTAssertEqual(store.current().retentionDays, 14)
    }

    /// The rice drop is a shared file: the theme keys have lived in it since
    /// before any of this existed. Locking a Settings row because that file
    /// names *something* would grey out the whole window on every haus desktop.
    func testTheThemeKeysInThatFileDeclareNothing() throws {
        try write(
            #"{ "themeDark": "nebelung", "accent": "mauve", "screenshotsFolder": "~/Pictures" }"#,
            to: declaration
        )
        let store = makeStore()
        XCTAssertEqual(store.declaredKeys(), [])
        XCTAssertNil(store.update { $0.showOnAllDisplays = false })
    }

    func testDeclaredKeysAreOnlyTheOnesPerchTreatsAsSettings() throws {
        try write(#"{ "themeDark": "nebelung", "retentionDays": 30 }"#, to: declaration)
        XCTAssertEqual(makeStore().declaredKeys(), [AppConfig.Key.retentionDays])
    }

    /// A standalone install has no `~/.config/perch/config.json` at all, and a
    /// `haus rebuild` writing one for the first time should reach a running
    /// perch — which means watching the directory until the file shows up.
    func testADeclarationThatAppearsLaterIsFollowed() throws {
        let store = makeStore()
        let declared = expectation(description: "onChange fires for the new declaration")
        store.start { config in
            if config.retentionDays == 30 { declared.fulfill() }
        }

        try write(#"{ "retentionDays": 30 }"#, to: declaration)
        wait(for: [declared], timeout: 5)
        XCTAssertEqual(store.declaredKeys(), [AppConfig.Key.retentionDays])
    }

    func testARemovedDeclarationHandsTheSettingBack() throws {
        try write(#"{ "retentionDays": 7 }"#, to: file)
        try write(#"{ "retentionDays": 30 }"#, to: declaration)
        let store = makeStore()
        XCTAssertEqual(store.current().retentionDays, 30)

        let handedBack = expectation(description: "onChange fires with perch's own value")
        store.start { config in
            if config.retentionDays == 7 { handedBack.fulfill() }
        }
        try FileManager.default.removeItem(at: declaration)
        wait(for: [handedBack], timeout: 5)
        XCTAssertEqual(store.declaredKeys(), [], "and the row is editable again")
        XCTAssertNil(store.update { $0.retentionDays = 1 })
    }

    // MARK: - Decoding

    /// A stored 0 is "never expire", and it has to survive every read intact:
    /// a floor of one day makes "never" unrepresentable and silently turns the
    /// safest setting on the menu into the most destructive one.
    func testZeroRetentionSurvivesAndNegativesReadAsNever() throws {
        try write(#"{ "retentionDays": 0 }"#, to: file)
        XCTAssertEqual(makeStore().current().retentionDays, 0)

        try write(#"{ "retentionDays": -3 }"#, to: file)
        XCTAssertEqual(makeStore().current().retentionDays, 0)
    }

    func testAKeyOfTheWrongTypeIsIgnoredRatherThanCoerced() throws {
        try write(#"{ "retentionDays": "thirty", "mobileEnabled": false }"#, to: file)
        let store = makeStore()
        XCTAssertEqual(store.current().retentionDays, 0, "a string is not a number of days")
        XCTAssertFalse(store.current().mobileEnabled, "and the rest of the file still counts")
    }

    func testLaunchAtLoginIsNilUntilAFileNamesIt() throws {
        XCTAssertNil(makeStore().current().launchAtLogin, "macOS's answer stands unless declared")
        try write(#"{ "launchAtLogin": false }"#, to: declaration)
        XCTAssertEqual(makeStore().current().launchAtLogin, false)
        XCTAssertEqual(makeStore().declaredKeys(), [AppConfig.Key.launchAtLogin])
    }
}
