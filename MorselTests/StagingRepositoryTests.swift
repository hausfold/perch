import XCTest
@testable import Morsel

final class StagingRepositoryTests: XCTestCase {
    private var root: URL!
    private var repository: StagingRepository!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "MorselTests-\(UUID().uuidString)", directoryHint: .isDirectory)
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

    func testRecoversCompletedFileMissingFromManifest() throws {
        let directory = try repository.allocateImportDirectory()
        let url = directory.appending(path: "recovered.pdf")
        try Data([0x25, 0x50, 0x44, 0x46]).write(to: url)

        let recovered = repository.load()

        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered.first?.displayName, "recovered.pdf")
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
