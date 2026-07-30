import XCTest
@testable import Perch

/// The drag-out half of the shelf: an accepted drop lifts the item straight
/// away, and what happens to its staged bytes is settled afterwards.
@MainActor
final class ShelfStoreExportTests: XCTestCase {
    private var root: URL!
    private var suiteName: String!
    private var store: ShelfStore!
    private var repository: StagingRepository!
    private var staged: [ShelfItem] = []

    /// A shelf on a throwaway staging root. Built per test rather than in
    /// `setUp`, which runs off the main actor.
    private func makeShelf() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "PerchExport-\(UUID().uuidString)", directoryHint: .isDirectory)
        suiteName = "PerchExportSettings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        repository = try StagingRepository(rootURL: root)
        store = ShelfStore(repository: repository, settings: AppSettings(defaults: defaults))
        addTeardownBlock { [root, suiteName] in
            if let root {
                try? FileManager.default.removeItem(at: root)
            }
            if let suiteName {
                UserDefaults().removePersistentDomain(forName: suiteName)
            }
        }
    }

    /// Stages a file the way an import would and puts it on the shelf.
    @discardableResult
    private func stageItem(named name: String = "dropped.txt") throws -> ShelfItem {
        let directory = try repository.allocateImportDirectory()
        let url = directory.appending(path: name)
        try Data("staged".utf8).write(to: url)
        let item = try repository.item(forStagedURL: url)
        staged.append(item)
        try repository.persist(staged)
        store.restore()
        return item
    }

    private func stagedURL(of item: ShelfItem) throws -> URL {
        try XCTUnwrap(item.fileURL(inside: root))
    }

    func testAnAcceptedDropLiftsTheItemBeforeAnythingReadsIt() throws {
        try makeShelf()
        let item = try stageItem()

        store.liftForExport([item.id])

        XCTAssertTrue(store.items.isEmpty, "the shelf empties on release, not on the receiver's report")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: try stagedURL(of: item).path),
            "the destination still has to read these bytes"
        )
    }

    func testARefusedDropPutsTheItemBackInItsOldSlot() throws {
        try makeShelf()
        let first = try stageItem(named: "first.txt")
        let second = try stageItem(named: "second.txt")
        let third = try stageItem(named: "third.txt")

        store.liftForExport([second.id])
        store.returnToShelf(second.id)

        XCTAssertEqual(store.items.map(\.id), [first.id, second.id, third.id])
    }

    func testAConfirmedCopyDeletesTheStagedBytes() throws {
        try makeShelf()
        let item = try stageItem()
        let staged = try stagedURL(of: item)

        store.liftForExport([item.id])
        store.confirmCopied(item.id)

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    func testAConfirmedCopyKeepsAPinnedItemReadyForAnotherDrag() throws {
        try makeShelf()
        let item = try stageItem()
        let staged = try stagedURL(of: item)
        store.setPinned(true, for: item)

        store.liftForExport([item.id])
        store.confirmCopied(item.id)

        XCTAssertEqual(store.items.map(\.id), [item.id])
        XCTAssertTrue(try XCTUnwrap(store.items.first).isPinned)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
    }

    func testAPlainURLHandOffAlsoKeepsAPinnedItemReadyForAnotherDrag() throws {
        try makeShelf()
        let item = try stageItem()
        let staged = try stagedURL(of: item)
        store.setPinned(true, for: item)

        store.liftForExport([item.id])
        store.handOff([item.id])

        XCTAssertEqual(store.items.map(\.id), [item.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertEqual(repository.load().map(\.id), [item.id])
    }

    func testPinStateSurvivesRelaunchAndCanBeTurnedOff() throws {
        try makeShelf()
        let item = try stageItem()
        store.setPinned(true, for: item)

        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let restored = ShelfStore(repository: repository, settings: AppSettings(defaults: defaults))
        restored.restore()
        XCTAssertTrue(try XCTUnwrap(restored.items.first).isPinned)

        restored.setPinned(false, for: item)
        restored.liftForExport([item.id])

        XCTAssertTrue(restored.items.isEmpty)
    }

    /// A terminal pasted the path; nothing will ever confirm a copy, and the
    /// path has to keep resolving.
    func testAHandOffKeepsTheStagedBytesButNotTheItem() throws {
        try makeShelf()
        let item = try stageItem()
        let staged = try stagedURL(of: item)

        store.liftForExport([item.id])
        store.handOff([item.id])

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertTrue(repository.load().isEmpty, "and it is never re-adopted")
    }
}
