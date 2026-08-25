import XCTest

@testable import Perch

/// The two paths that could destroy the only copy of something with nobody
/// asking: the expiry timer, and Clear.
///
/// A staged copy is deleted outright rather than trashed — perch is sandboxed,
/// so its Trash is inside its own container and Finder never shows it — and for
/// a dragged-in promise, a link, typed text, or anything a paired iPhone sent,
/// the shelf copy is the only copy. Hence: the timer is off unless asked for,
/// pinned items are exempt even when it is on, and Clear asks first.
@MainActor
final class ShelfRetentionTests: XCTestCase {
    private var suiteNames: [String] = []
    private var roots: [URL] = []

    // The async variant, because the sync `tearDown()` is nonisolated and this
    // class is `@MainActor` — reaching the stored properties from it is a
    // concurrency warning, and the fixture it is trying to clean up is exactly
    // the state that must not leak between tests.
    override func tearDown() async throws {
        // Each test mints a throwaway suite; without this they accumulate as
        // real plists for the test host, and a leaked suite is a test that can
        // pass because of what a previous run left behind.
        for name in suiteNames {
            UserDefaults().removePersistentDomain(forName: name)
        }
        suiteNames = []
        for root in roots {
            try? FileManager.default.removeItem(at: root)
        }
        roots = []
        try await super.tearDown()
    }

    private func makeDefaults() throws -> UserDefaults {
        let name = "PerchRetention-\(UUID().uuidString)"
        suiteNames.append(name)
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    /// A throwaway directory, cleaned up in `tearDown`. Every file fixture
    /// here goes through it: a settings file left behind is state a later test
    /// can pass because of.
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "PerchRetention-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }

    /// A settings store on its own file, with no declaration — the shape of a
    /// standalone install, and the only shape that keeps a test off the real
    /// `~/.config/perch/config.json` of whichever Mac is running it.
    private func makeStore() throws -> ConfigFileStore {
        ConfigFileStore(file: try makeRoot().appending(path: "settings.json"), declaration: nil)
    }

    private func makeRepository() throws -> StagingRepository {
        try StagingRepository(rootURL: try makeRoot())
    }

    /// A real staged file, dated however the test needs it.
    private func stage(
        _ name: String,
        in repository: StagingRepository,
        addedAt: Date,
        pinned: Bool = false
    ) throws -> (item: ShelfItem, url: URL) {
        let directory = try repository.allocateImportDirectory()
        let url = directory.appending(path: name)
        try Data(name.utf8).write(to: url)
        let staged = try repository.item(forStagedURL: url)
        let item = ShelfItem(
            id: staged.id,
            displayName: staged.displayName,
            relativePath: staged.relativePath,
            kind: staged.kind,
            contentTypeIdentifier: staged.contentTypeIdentifier,
            byteCount: staged.byteCount,
            addedAt: addedAt,
            isPinned: pinned
        )
        return (item, url)
    }

    // MARK: - The cutoff rule

    func testRetentionOffYieldsNoCutoff() {
        XCTAssertNil(
            ShelfStore.expiryCutoff(retentionDays: 0),
            "0 days means never — there must be no cutoff to compare against."
        )
    }

    /// Defensive: a negative can only arrive from a hand-edited defaults plist,
    /// and the safe reading of "minus three days" is "don't".
    func testNegativeRetentionYieldsNoCutoff() {
        XCTAssertNil(ShelfStore.expiryCutoff(retentionDays: -3))
    }

    func testPositiveRetentionCutsAtThatManyDaysBack() throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let cutoff = try XCTUnwrap(ShelfStore.expiryCutoff(retentionDays: 7, now: now))
        XCTAssertEqual(cutoff, try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -7, to: now)))
        XCTAssertLessThan(cutoff, now)
    }

    // MARK: - The default, and the two migrations

    func testRetentionIsOffOnAFreshInstall() throws {
        let settings = AppSettings(store: try makeStore(), defaults: try makeDefaults())
        XCTAssertEqual(
            settings.retentionDays, 0,
            "Nothing may be deleted on a timer until someone turns the timer on."
        )
        XCTAssertNil(ShelfStore.expiryCutoff(retentionDays: settings.retentionDays))
    }

    /// A stored 0 has to survive the read. The old init clamped with `max(1,)`,
    /// which made "never" unrepresentable — anyone who chose it got a one-day
    /// expiry instead, the most destructive setting on the menu.
    func testStoredNeverIsNotClampedUpToOneDay() throws {
        let store = try makeStore()
        XCTAssertNil(store.update { $0.retentionDays = 0 })
        XCTAssertEqual(AppSettings(store: store, defaults: try makeDefaults()).retentionDays, 0)
    }

    /// Every stored retention was chosen against a stepper that said "Discard",
    /// started at 1, and never mentioned that discarding is a delete with no
    /// Trash behind it. That consent doesn't carry forward, so it is handed back
    /// once — and the *cleared* value is what reaches the file, not the value it
    /// was cleared from.
    func testARetentionChosenUnderTheOldUIIsTurnedOffOnce() throws {
        let defaults = try makeDefaults()
        let store = try makeStore()
        defaults.set(14, forKey: "retentionDays")

        XCTAssertEqual(AppSettings(store: store, defaults: defaults).retentionDays, 0)
        XCTAssertTrue(defaults.bool(forKey: "retentionOptInMigrated"))
        XCTAssertEqual(store.current().retentionDays, 0, "and the file agrees")
    }

    /// …and only once. A choice made *after* the migration, against the new
    /// wording, is the user's and stands.
    func testARetentionChosenAfterTheMigrationIsKept() throws {
        let defaults = try makeDefaults()
        let store = try makeStore()
        defaults.set(14, forKey: "retentionDays")
        let settings = AppSettings(store: store, defaults: defaults)

        settings.retentionDays = 30
        XCTAssertEqual(AppSettings(store: store, defaults: defaults).retentionDays, 30)
    }

    /// The `UserDefaults` builds are what the file replaced, so whatever they
    /// stored has to arrive intact — otherwise an update silently re-decides
    /// settings its user already made.
    func testTheOldUserDefaultsSettingsMoveIntoTheFileOnce() throws {
        let defaults = try makeDefaults()
        let store = try makeStore()
        defaults.set(true, forKey: "retentionOptInMigrated")
        defaults.set(false, forKey: "showOnAllDisplays")
        defaults.set(false, forKey: "mobileEnabled")
        defaults.set(7, forKey: "retentionDays")

        let settings = AppSettings(store: store, defaults: defaults)
        XCTAssertFalse(settings.showOnAllDisplays)
        XCTAssertFalse(settings.mobileEnabled)
        XCTAssertEqual(settings.retentionDays, 7)
        XCTAssertEqual(store.current().retentionDays, 7, "the file is where they live now")
        XCTAssertNil(
            defaults.object(forKey: "retentionDays"),
            "and the old copy is gone, so it can never be migrated a second time"
        )
    }

    /// A key nobody ever touched has no entry in `UserDefaults`, so the
    /// migration has nothing to carry for it: the file gets that key at its
    /// compiled-in default, not at a value the migration invented.
    func testAKeyNobodyEverChangedKeepsItsDefault() throws {
        let defaults = try makeDefaults()
        let store = try makeStore()
        defaults.set(true, forKey: "retentionOptInMigrated")
        defaults.set(false, forKey: "mobileEnabled")

        let settings = AppSettings(store: store, defaults: defaults)
        XCTAssertFalse(settings.mobileEnabled, "the one setting that was actually made")
        XCTAssertEqual(settings.showOnAllDisplays, AppConfig().showOnAllDisplays)
        XCTAssertEqual(store.current().showOnAllDisplays, AppConfig().showOnAllDisplays)
    }

    /// The file is a later, more deliberate decision than a switch flipped in a
    /// previous build — most of all when the *rice* wrote it, where a migration
    /// that won would take a machine whose settings are declared and quietly
    /// hand it the old ones instead.
    func testTheFileWinsOverAStaleUserDefaultsValue() throws {
        let defaults = try makeDefaults()
        let store = try makeStore()
        defaults.set(true, forKey: "retentionOptInMigrated")
        defaults.set(14, forKey: "retentionDays")
        XCTAssertNil(store.update { $0.retentionDays = 30 })

        XCTAssertEqual(AppSettings(store: store, defaults: defaults).retentionDays, 30)
    }

    // MARK: - What a declaration does to the pane

    func testADeclaredRetentionIsReadOnlyAndRefusesToMove() throws {
        let root = try makeRoot()
        let declaration = root.appending(path: "config.json")
        try #"{ "retentionDays": 30 }"#.write(to: declaration, atomically: true, encoding: .utf8)
        let store = ConfigFileStore(file: root.appending(path: "settings.json"), declaration: declaration)

        let settings = AppSettings(store: store, defaults: try makeDefaults())
        XCTAssertEqual(settings.retentionDays, 30)
        XCTAssertTrue(settings.isDeclared(AppConfig.Key.retentionDays))

        settings.retentionDays = 0
        XCTAssertEqual(settings.retentionDays, 30, "the switch springs back to what the file says")
        XCTAssertNotNil(settings.writeError, "and says why, rather than moving over a file that didn't")
    }

    // MARK: - What prune actually does to the bytes

    func testPruneDeletesTheBytesOfAnExpiredItem() throws {
        let repository = try makeRepository()
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let old = try stage("old.txt", in: repository, addedAt: now.addingTimeInterval(-40 * 86_400))
        let fresh = try stage("fresh.txt", in: repository, addedAt: now)

        let cutoff = try XCTUnwrap(ShelfStore.expiryCutoff(retentionDays: 30, now: now))
        let retained = try repository.prune(olderThan: cutoff, items: [old.item, fresh.item])

        XCTAssertEqual(retained.map(\.id), [fresh.item.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.url.path))
    }

    /// `prune` keeps `addedAt >= cutoff`, so an item dated exactly on the line
    /// survives. Worth pinning: the off-by-one here is a deleted file.
    func testAnItemDatedExactlyAtTheCutoffSurvives() throws {
        let repository = try makeRepository()
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let cutoff = try XCTUnwrap(ShelfStore.expiryCutoff(retentionDays: 30, now: now))
        let edge = try stage("edge.txt", in: repository, addedAt: cutoff)

        let retained = try repository.prune(olderThan: cutoff, items: [edge.item])

        XCTAssertEqual(retained.map(\.id), [edge.item.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: edge.url.path))
    }

    /// A pin means "this one stays" to drag-out, to the tile drag and to the
    /// take-everything handle. Expiry has to mean it too, or the timer takes
    /// exactly the tiles someone pinned because they mattered.
    func testPruneSparesPinnedItems() throws {
        let repository = try makeRepository()
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let ancient = now.addingTimeInterval(-400 * 86_400)
        let pinned = try stage("pinned.txt", in: repository, addedAt: ancient, pinned: true)
        let loose = try stage("loose.txt", in: repository, addedAt: ancient)

        let cutoff = try XCTUnwrap(ShelfStore.expiryCutoff(retentionDays: 30, now: now))
        let retained = try repository.prune(olderThan: cutoff, items: [pinned.item, loose.item])

        XCTAssertEqual(retained.map(\.id), [pinned.item.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: pinned.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: loose.url.path))
    }

    // MARK: - Clear asks first

    func testFirstPressOnlyArms() {
        var confirmation = ClearConfirmation()
        let shelf = [UUID(), UUID()]

        XCTAssertFalse(confirmation.activate(itemIDs: shelf), "The first press must not clear.")
        XCTAssertTrue(confirmation.isArmed)
    }

    func testSecondPressOnTheSameShelfClears() {
        var confirmation = ClearConfirmation()
        let shelf = [UUID(), UUID()]

        _ = confirmation.activate(itemIDs: shelf)
        XCTAssertTrue(confirmation.activate(itemIDs: shelf))
        XCTAssertFalse(confirmation.isArmed, "Firing must leave it disarmed, not armed for the next click.")
    }

    /// The panel is collapsed, not destroyed, when the shelf hides — and items
    /// arrive while it is collapsed. An arming made against two items must not
    /// greet the next expansion pointed at nine.
    func testAnArmingDoesNotSurviveItemsArriving() {
        var confirmation = ClearConfirmation()
        let shelf = [UUID(), UUID()]
        _ = confirmation.activate(itemIDs: shelf)

        confirmation.revalidate(against: shelf + [UUID()])

        XCTAssertFalse(confirmation.isArmed)
    }

    /// The reason this compares identities rather than a count: a remove and an
    /// add inside the same window leave the count untouched while changing
    /// every part of what "clear everything" would mean.
    func testAnArmingDoesNotSurviveASwapThatKeepsTheCount() {
        var confirmation = ClearConfirmation()
        let kept = UUID()
        _ = confirmation.activate(itemIDs: [kept, UUID()])

        confirmation.revalidate(against: [kept, UUID()])

        XCTAssertFalse(confirmation.isArmed)
    }

    func testRevalidatingAgainstTheSameShelfLeavesItArmed() {
        var confirmation = ClearConfirmation()
        let shelf = [UUID(), UUID()]
        _ = confirmation.activate(itemIDs: shelf)

        confirmation.revalidate(against: shelf)

        XCTAssertTrue(confirmation.isArmed)
    }

    /// What the timeout and the collapse both call.
    func testDisarmClearsTheRememberedShelf() {
        var confirmation = ClearConfirmation()
        let shelf = [UUID()]
        _ = confirmation.activate(itemIDs: shelf)

        confirmation.disarm()

        XCTAssertFalse(confirmation.isArmed)
        XCTAssertFalse(
            confirmation.activate(itemIDs: shelf),
            "After disarming, the next press is a first press again."
        )
    }
}
