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

    /// What the user does in Finder after **Show in Finder**.
    @discardableResult
    private func rename(_ item: ShelfItem, to name: String) throws -> URL {
        let staged = try stagedURL(of: item)
        let renamed = staged.deletingLastPathComponent().appending(path: name)
        try FileManager.default.moveItem(at: staged, to: renamed)
        return renamed.standardizedFileURL
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

    // MARK: - A staged file renamed out from under the shelf (#7)

    /// The field-test repro: Show in Finder, rename there, drag the tile out.
    /// The container is the durable identity, so the tile follows the name.
    func testARenamedStagedFileStillResolvesAndStillExports() throws {
        try makeShelf()
        let item = try stageItem(named: "screenshot.png")
        let renamed = try rename(item, to: "keeper.png")

        XCTAssertEqual(repository.resolvedURL(for: item), renamed)

        store.refreshStagedNames()
        let followed = try XCTUnwrap(store.items.first)
        XCTAssertEqual(followed.id, item.id, "same tile, not a re-adopted stranger")
        XCTAssertEqual(followed.displayName, "keeper.png")

        store.liftForExport([followed.id])
        XCTAssertTrue(store.items.isEmpty, "and it leaves the shelf like any other tile")
        store.confirmCopied(followed.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamed.path))
    }

    func testARenameSurvivesRelaunchWithTheSameIdentityAndPin() throws {
        try makeShelf()
        let item = try stageItem(named: "invoice.pdf")
        store.setPinned(true, for: item)
        try rename(item, to: "invoice-final.pdf")

        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let restored = ShelfStore(repository: repository, settings: AppSettings(defaults: defaults))
        restored.restore()

        let survivor = try XCTUnwrap(restored.items.first)
        XCTAssertEqual(restored.items.count, 1, "re-resolved, not dropped and re-adopted")
        XCTAssertEqual(survivor.id, item.id)
        XCTAssertEqual(survivor.displayName, "invoice-final.pdf")
        XCTAssertTrue(survivor.isPinned, "a rename is not a reason to lose the pin")
    }

    /// Ambiguity is refused rather than guessed: handing a destination the
    /// wrong file is worse than refusing the drag.
    func testAContainerWithTwoVisibleChildrenDoesNotGuess() throws {
        try makeShelf()
        let item = try stageItem()
        let staged = try stagedURL(of: item)
        let container = staged.deletingLastPathComponent()
        try FileManager.default.moveItem(at: staged, to: container.appending(path: "one.txt"))
        try Data("other".utf8).write(to: container.appending(path: "two.txt"))

        XCTAssertNil(repository.resolvedURL(for: item))
    }

    /// A promised *batch* shares one container between several items
    /// (`beginPromisedImports`), so the one child left after a sibling's file
    /// is deleted is as likely to be the sibling as this item renamed.
    /// Vending the wrong file is worse than refusing the drag.
    func testASharedBatchContainerIsNeverResolvedToASibling() throws {
        try makeShelf()
        let container = try repository.allocateImportDirectory()
        let mine = container.appending(path: "mine.txt")
        let theirs = container.appending(path: "theirs.txt")
        try Data("mine".utf8).write(to: mine)
        try Data("theirs".utf8).write(to: theirs)
        let mineItem = try repository.item(forStagedURL: mine)
        let theirsItem = try repository.item(forStagedURL: theirs)
        try repository.persist([mineItem, theirsItem])
        store.restore()

        // The user deletes one of the two in Finder.
        try FileManager.default.removeItem(at: mine)

        XCTAssertNil(
            repository.resolvedURL(for: mineItem, alongside: [mineItem, theirsItem]),
            "the surviving child belongs to the sibling, not to this item"
        )
        store.liftForExport([mineItem.id])
        XCTAssertEqual(store.items.map(\.id), [mineItem.id, theirsItem.id], "neither tile moves")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: theirs.path),
            "and the sibling's bytes are untouched"
        )
    }

    /// Detached bytes belong to whatever took an earlier drop — re-resolution
    /// must never be the thing that hands them back out.
    func testResolutionNeverReachesIntoADetachedContainer() throws {
        try makeShelf()
        let item = try stageItem()
        store.liftForExport([item.id])
        store.handOff([item.id])
        try rename(item, to: "renamed.txt")

        XCTAssertNil(repository.resolvedURL(for: item))
    }

    // MARK: - The two independent bugs a rename exposed

    /// `liftForExport` must not take a tile off the shelf when it cannot find
    /// the bytes: nothing can have copied them, so nothing earned the removal.
    func testAnAcceptedDropKeepsATileWhoseBytesAreGoneAndSaysSo() throws {
        try makeShelf()
        let item = try stageItem()
        try FileManager.default.removeItem(at: try stagedURL(of: item))

        store.liftForExport([item.id])

        XCTAssertEqual(store.items.map(\.id), [item.id])
        XCTAssertNotNil(store.latestError, "and the refusal is visible")
    }

    /// `.accepted` is reported inline from the drag session while `.copied` /
    /// `.failed` hop to the main actor from the promise queue, so a promise
    /// that fails fast can be refused before it is ever lifted.
    func testAFailedVerdictArrivingBeforeTheLiftStillLeavesTheItemOnTheShelf() throws {
        try makeShelf()
        let first = try stageItem(named: "first.txt")
        let second = try stageItem(named: "second.txt")
        store.beginExport(of: [first.id, second.id])

        store.returnToShelf(second.id)
        store.liftForExport([first.id, second.id])

        XCTAssertEqual(store.items.map(\.id), [second.id], "the refused one never left")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: try stagedURL(of: second).path),
            "and its bytes are still there to drag again"
        )
    }

    /// The mirror of the above: a fast local copy can report `.copied` before
    /// the drag session reports `.accepted`. Dropping that verdict leaked the
    /// staged bytes, and the next launch re-adopted them as a stranger.
    func testACopiedVerdictArrivingBeforeTheLiftStillSettlesTheBytes() throws {
        try makeShelf()
        let item = try stageItem()
        let staged = try stagedURL(of: item)
        store.beginExport(of: [item.id])

        store.confirmCopied(item.id)
        store.liftForExport([item.id])

        XCTAssertTrue(store.items.isEmpty, "it still leaves the shelf")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: staged.path),
            "and its bytes go, rather than lingering to be re-adopted next launch"
        )
        XCTAssertTrue(repository.load().isEmpty)
    }

    func testAnEarlyCopiedVerdictDoesNotSettleTheNextDrag() throws {
        try makeShelf()
        let item = try stageItem()
        let staged = try stagedURL(of: item)
        store.beginExport(of: [item.id])
        store.confirmCopied(item.id)

        // A new drag: the stale verdict must not delete this one's bytes.
        store.beginExport(of: [item.id])
        store.liftForExport([item.id])

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: staged.path),
            "nothing has reported a copy for *this* drag yet"
        )
        store.returnToShelf(item.id)
        XCTAssertEqual(store.items.map(\.id), [item.id])
    }

    /// A pinned tile never enters the lifted transaction, so its drag's
    /// `.failed` always finds nothing lifted and records a refusal for an id
    /// that is *still on the shelf*. Unpinning and dragging it must work.
    func testAPinnedTilesRefusalDoesNotHauntItAfterUnpinning() throws {
        try makeShelf()
        let item = try stageItem()
        store.setPinned(true, for: item)
        store.beginExport(of: [])
        store.returnToShelf(item.id)

        store.setPinned(false, for: item)
        store.beginExport(of: [item.id])
        store.liftForExport([item.id])

        XCTAssertTrue(store.items.isEmpty)
    }

    /// The refusal is scoped to the drag that produced it — a later drag of the
    /// same tile must lift normally.
    func testAnOutOfOrderRefusalDoesNotSuppressTheNextDrag() throws {
        try makeShelf()
        let item = try stageItem()
        store.beginExport(of: [item.id])
        store.returnToShelf(item.id)
        store.liftForExport([item.id])

        store.beginExport(of: [item.id])
        store.liftForExport([item.id])

        XCTAssertTrue(store.items.isEmpty)
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
