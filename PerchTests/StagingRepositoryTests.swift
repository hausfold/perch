import XCTest
@testable import Perch

final class StagingRepositoryTests: XCTestCase {
    private var root: URL!
    private var repository: StagingRepository!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "PerchTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        repository = try StagingRepository(rootURL: root)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testSameFilenameCanBeStagedTwiceWithoutCollision() throws {
        let firstDirectory = try repository.allocateImportDirectory()
        let secondDirectory = try repository.allocateImportDirectory()
        let firstURL = firstDirectory.appending(path: "photo.jpg")
        let secondURL = secondDirectory.appending(path: "photo.jpg")
        try Data("first".utf8).write(to: firstURL)
        try Data("second".utf8).write(to: secondURL)

        let first = try repository.item(forStagedURL: firstURL)
        let second = try repository.item(forStagedURL: secondURL)

        XCTAssertEqual(first.displayName, second.displayName)
        XCTAssertNotEqual(first.relativePath, second.relativePath)
        XCTAssertNotEqual(first.id, second.id)
    }

    func testManifestRoundTripFiltersMissingFiles() throws {
        let directory = try repository.allocateImportDirectory()
        let url = directory.appending(path: "notes.txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        let item = try repository.item(forStagedURL: url)
        try repository.persist([item])

        let loaded = repository.load()
        XCTAssertEqual(loaded.map(\.id), [item.id])
        XCTAssertEqual(loaded.map(\.relativePath), [item.relativePath])

        try FileManager.default.removeItem(at: directory)
        XCTAssertEqual(repository.load(), [])
    }

    // MARK: - The manifest has to be readable, and unreadable must not mean gone
    //
    // These two pin the fix for a bug that showed up as "flaky tests": the
    // manifest was written with `.completeFileProtectionUnlessOpen`, which makes
    // a file unreadable once closed until the Mac is next unlocked. Every test
    // that round-tripped a persisted manifest failed inside that window, and the
    // one test that wrote a manifest by hand (without the protection class)
    // passed — which is what identified it. In the real app the same window
    // meant: shelf reloads, manifest reads as absent, recovery re-adopts every
    // staged file with a new UUID and no pin state, and writes that back over
    // the real manifest. Pins gone, permanently.

    /// The class perch writes with must be readable for a whole login session.
    func testTheManifestIsNotWrittenWithALockedFileProtectionClass() {
        XCTAssertTrue(StagingRepository.manifestWriteOptions.contains(.atomic))
        XCTAssertFalse(
            StagingRepository.manifestWriteOptions.contains(.completeFileProtectionUnlessOpen),
            "unreadable after a lock — perch reloads its shelf long after one"
        )
        XCTAssertFalse(
            StagingRepository.manifestWriteOptions.contains(.completeFileProtection),
            "unreadable while the screen is locked, same problem"
        )
        XCTAssertTrue(
            StagingRepository.manifestWriteOptions
                .contains(.completeFileProtectionUntilFirstUserAuthentication),
            "still encrypted at rest, just not against its own app"
        )
    }

    /// The safety net, for any other reason a read might fail — a bad sector, a
    /// half-written file, a manifest from a newer perch. Recovery may rebuild
    /// the shelf in memory, but it must never write its guess over the truth.
    func testAnUnreadableManifestIsNeverOverwrittenByRecovery() throws {
        let directory = try repository.allocateImportDirectory()
        let url = directory.appending(path: "pinned.txt")
        try Data("staged".utf8).write(to: url)
        var item = try repository.item(forStagedURL: url)
        item.isPinned = true
        try repository.persist([item])

        // Whatever made it unreadable — here, bytes that will not decode.
        let manifestURL = root.appending(path: "manifest.json")
        let corrupt = Data("this is not a manifest".utf8)
        try corrupt.write(to: manifestURL)

        // The shelf still comes up: the file on disk is adopted so the user
        // isn't shown an empty shelf...
        let loaded = repository.load()
        XCTAssertEqual(loaded.count, 1)

        // ...but the manifest is left exactly as it was found, so nothing about
        // the real item — its id, its pin, when it arrived — was destroyed by a
        // read that might succeed next time.
        XCTAssertEqual(try Data(contentsOf: manifestURL), corrupt)
    }

    /// The ordinary case still writes back: an absent manifest is a fresh
    /// shelf, and recovery is exactly what should populate it.
    func testAnAbsentManifestIsStillWrittenByRecovery() throws {
        let directory = try repository.allocateImportDirectory()
        try Data("staged".utf8).write(to: directory.appending(path: "found.txt"))

        XCTAssertEqual(repository.load().count, 1)

        let manifestURL = root.appending(path: "manifest.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
        // And it round-trips: the id recovery invented is the id a relaunch sees.
        let relaunched = try StagingRepository(rootURL: root)
        XCTAssertEqual(relaunched.load().map(\.id), repository.load().map(\.id))
    }

    func testManifestWrittenBeforePinningRestoresAsUnpinned() throws {
        let id = UUID()
        let directory = try repository.allocateImportDirectory()
        let url = directory.appending(path: "legacy.txt")
        try Data("legacy".utf8).write(to: url)
        let relativePath = "\(directory.lastPathComponent)/legacy.txt"
        let addedAt = Int64(Date().timeIntervalSince1970 * 1_000)
        let manifest = """
        {
          "version": 1,
          "items": [{
            "id": "\(id.uuidString)",
            "displayName": "legacy.txt",
            "relativePath": "\(relativePath)",
            "kind": "text",
            "contentTypeIdentifier": "public.plain-text",
            "byteCount": 6,
            "addedAt": \(addedAt)
          }],
          "updatedAt": \(addedAt)
        }
        """
        try Data(manifest.utf8).write(to: root.appending(path: "manifest.json"))

        let restored = try XCTUnwrap(repository.load().first)

        XCTAssertEqual(restored.id, id)
        XCTAssertFalse(restored.isPinned)
    }

    func testRecoversCompletedFileMissingFromManifest() throws {
        let directory = try repository.allocateImportDirectory()
        let url = directory.appending(path: "recovered.pdf")
        try Data([0x25, 0x50, 0x44, 0x46]).write(to: url)

        let recovered = repository.load()

        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered.first?.displayName, "recovered.pdf")
    }

    /// A drag-out whose destination read the file URL directly (a terminal that
    /// pasted the path) leaves that path live: the item goes, the bytes stay.
    func testDetachKeepsTheBytesButNeverReadoptsTheItem() throws {
        let directory = try repository.allocateImportDirectory()
        let url = directory.appending(path: "dragged.txt")
        try Data("staged".utf8).write(to: url)
        let item = try repository.item(forStagedURL: url)
        try repository.persist([item])

        try repository.detach(item)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "whatever took the drop still points here"
        )
        XCTAssertTrue(repository.load().isEmpty, "and it never comes back as an item")
    }

    /// Detached bytes are kept while the path may still be used, not forever.
    func testDetachedContainersAreSweptOnceTheirGraceHasPassed() throws {
        let directory = try repository.allocateImportDirectory()
        let url = directory.appending(path: "dragged.txt")
        try Data("staged".utf8).write(to: url)
        try repository.detach(try repository.item(forStagedURL: url))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)],
            ofItemAtPath: directory.appending(path: ".detached").path
        )

        let relaunched = try StagingRepository(rootURL: root)
        XCTAssertTrue(relaunched.load().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testRejectsPathOutsideStagingRoot() throws {
        let outside = FileManager.default.temporaryDirectory
            .appending(path: "outside-\(UUID().uuidString).txt")
        try "no".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }

        XCTAssertThrowsError(try repository.item(forStagedURL: outside))
    }

    func testRemoveDeletesWholeImportContainer() throws {
        let directory = try repository.allocateImportDirectory()
        let url = directory.appending(path: "file.dat")
        try Data([1, 2, 3]).write(to: url)
        let item = try repository.item(forStagedURL: url)

        try repository.remove(item)

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testRemovingOneSharedBatchItemPreservesItsSibling() throws {
        let directory = try repository.allocateImportDirectory()
        let firstURL = directory.appending(path: "first.txt")
        let secondURL = directory.appending(path: "second.txt")
        try "first".write(to: firstURL, atomically: true, encoding: .utf8)
        try "second".write(to: secondURL, atomically: true, encoding: .utf8)
        let first = try repository.item(forStagedURL: firstURL)

        try repository.remove(first)

        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    func testInterruptedContainerIsDiscardedInsteadOfRecovered() throws {
        let directory = try repository.allocateImportDirectory()
        try Data().write(to: directory.appending(path: ".receiving"))
        try Data("partial".utf8).write(to: directory.appending(path: "photo.jpg"))

        XCTAssertEqual(repository.load(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
