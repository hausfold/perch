import Foundation
import XCTest
@testable import Perch

final class FolderWatchRulesTests: XCTestCase {
    func testInProgressAndHiddenNamesAreNotCandidates() {
        XCTAssertTrue(FolderWatchRules.isCandidateName("report.pdf"))
        XCTAssertTrue(FolderWatchRules.isCandidateName("Makefile"))
        XCTAssertTrue(FolderWatchRules.isCandidateName("Screenshot 2026-08-15 at 09.00.00.png"))

        XCTAssertFalse(FolderWatchRules.isCandidateName(".DS_Store"))
        XCTAssertFalse(FolderWatchRules.isCandidateName(".partial-download.png"))
        XCTAssertFalse(FolderWatchRules.isCandidateName("movie.mkv.part"))
        XCTAssertFalse(FolderWatchRules.isCandidateName("archive.zip.crdownload"))
        XCTAssertFalse(FolderWatchRules.isCandidateName("Safari.download"))
        XCTAssertFalse(FolderWatchRules.isCandidateName("thing.PARTIAL"))
        XCTAssertFalse(FolderWatchRules.isCandidateName("scratch.tmp"))
        XCTAssertFalse(FolderWatchRules.isCandidateName(""))
    }

    func testIdentityTokenSurvivesRenameAndEditButNotRecreation() throws {
        let directory = try makeTemporaryDirectory()
        let original = directory.appending(path: "a.txt")
        try Data("one".utf8).write(to: original)
        let token = try FolderWatchRules.identityToken(forFileAt: original)

        // Renaming and editing keep the inode and birth date, so the identity
        // holds — a shelved file touched up in place must not land twice.
        let renamed = directory.appending(path: "b.txt")
        try FileManager.default.moveItem(at: original, to: renamed)
        XCTAssertEqual(try FolderWatchRules.identityToken(forFileAt: renamed), token)

        let handle = try FileHandle(forWritingTo: renamed)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" two".utf8))
        try handle.close()
        XCTAssertEqual(try FolderWatchRules.identityToken(forFileAt: renamed), token)

        // A different file is a different identity.
        let other = directory.appending(path: "c.txt")
        try Data("three".utf8).write(to: other)
        XCTAssertNotEqual(try FolderWatchRules.identityToken(forFileAt: other), token)
    }
}

@MainActor
final class WatchedFolderStoreTests: XCTestCase {
    func testFoldersAndLedgersSurviveAReload() throws {
        let directory = try makeTemporaryDirectory()
        let configURL = directory.appending(path: "watched-folders.json")
        let watched = directory.appending(path: "Watched", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)

        let store = WatchedFolderStore(fileURL: configURL, bookmarking: .plain)
        let folder = try store.add(folderAt: watched)
        store.markImported("token-1", for: folder.id)
        store.setTokens(["token-2", "token-3"], for: folder.id)

        let reloaded = WatchedFolderStore(fileURL: configURL, bookmarking: .plain)
        XCTAssertEqual(reloaded.folders.count, 1)
        XCTAssertEqual(reloaded.folders.first?.id, folder.id)
        XCTAssertEqual(reloaded.folders.first?.importedTokens, ["token-2", "token-3"])
        let resolved = try reloaded.bookmarking.resolve(try XCTUnwrap(reloaded.folders.first).bookmark)
        XCTAssertEqual(
            resolved.url.standardizedFileURL.resolvingSymlinksInPath().path,
            watched.standardizedFileURL.resolvingSymlinksInPath().path
        )

        store.remove(folder.id)
        XCTAssertTrue(store.folders.isEmpty)
        XCTAssertTrue(WatchedFolderStore(fileURL: configURL, bookmarking: .plain).folders.isEmpty)
    }
}

final class FolderWatcherTests: XCTestCase {
    /// Everything a watcher reported, safe to poke from its queue and the test.
    private final class ImportLog: @unchecked Sendable {
        private let lock = NSLock()
        private var imported: [(name: String, sizeAtImport: Int)] = []
        private var ledgers: [Set<String>] = []

        func recordImport(of url: URL) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
            lock.withLock { imported.append((url.lastPathComponent, size)) }
        }

        func recordLedger(_ tokens: Set<String>) {
            lock.withLock { ledgers.append(tokens) }
        }

        var importedNames: [String] { lock.withLock { imported.map(\.name) } }
        var importedSizes: [Int] { lock.withLock { imported.map(\.sizeAtImport) } }
        var replacedLedgers: [Set<String>] { lock.withLock { ledgers } }
    }

    private func makeWatcher(
        over directory: URL,
        ledger: Set<String> = [],
        requiredStableProbes: Int = 2,
        log: ImportLog,
        onImport: XCTestExpectation? = nil
    ) -> FolderWatcher {
        let watcher = FolderWatcher(
            folderID: UUID(),
            folderURL: directory,
            ledger: ledger,
            holdsSecurityScope: false,
            probeInterval: 0.05,
            requiredStableProbes: requiredStableProbes,
            onImport: { url, _ in
                log.recordImport(of: url)
                onImport?.fulfill()
            },
            onLedgerReplaced: { tokens in
                log.recordLedger(tokens)
            }
        )
        addTeardownBlock {
            watcher.stop()
        }
        return watcher
    }

    func testANewStableFileLandsExactlyOnce() throws {
        let directory = try makeTemporaryDirectory()
        let log = ImportLog()
        let landed = expectation(description: "new file imported")
        let watcher = makeWatcher(over: directory, log: log, onImport: landed)
        XCTAssertTrue(watcher.start(seedExisting: false))

        try Data("hello".utf8).write(to: directory.appending(path: "fresh.txt"))
        wait(for: [landed], timeout: 5)
        // Give a double-import every chance to happen before asserting once.
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(log.importedNames, ["fresh.txt"])
    }

    func testSeedingShelvesNothingButANewArrivalStillLands() throws {
        let directory = try makeTemporaryDirectory()
        try Data("history".utf8).write(to: directory.appending(path: "old-download.zip"))

        let log = ImportLog()
        let landed = expectation(description: "only the new file imported")
        let watcher = makeWatcher(over: directory, log: log, onImport: landed)
        XCTAssertTrue(watcher.start(seedExisting: true))

        // The seed pass must complete (and ledger the history) before the
        // arrival, or this would just be racing the initial scan.
        waitUntil("folder was seeded") { !log.replacedLedgers.isEmpty }
        XCTAssertEqual(log.replacedLedgers.first?.count, 1)

        try Data("new".utf8).write(to: directory.appending(path: "arrival.txt"))
        wait(for: [landed], timeout: 5)
        XCTAssertEqual(log.importedNames, ["arrival.txt"])
    }

    func testAGrowingFileWaitsUntilItHoldsStill() throws {
        let directory = try makeTemporaryDirectory()
        let log = ImportLog()
        let landed = expectation(description: "grown file imported once complete")
        // Four stable probes at 50 ms is a ~150 ms quiet window; appending
        // every 25 ms keeps the file visibly in motion until the writer stops.
        let watcher = makeWatcher(
            over: directory,
            requiredStableProbes: 4,
            log: log,
            onImport: landed
        )
        XCTAssertTrue(watcher.start(seedExisting: false))

        let url = directory.appending(path: "big.bin")
        let chunk = Data(repeating: 7, count: 1024)
        try chunk.write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        for _ in 0..<12 {
            Thread.sleep(forTimeInterval: 0.025)
            try handle.seekToEnd()
            try handle.write(contentsOf: chunk)
        }
        try handle.close()

        wait(for: [landed], timeout: 10)
        XCTAssertEqual(log.importedNames, ["big.bin"])
        // The probe must have held the import until writing stopped: the size
        // it shelved at is the finished size, not whatever it first saw.
        XCTAssertEqual(log.importedSizes, [chunk.count * 13])
    }

    func testAnInProgressDownloadLandsOnlyAfterItsRename() throws {
        let directory = try makeTemporaryDirectory()
        let log = ImportLog()
        let landed = expectation(description: "renamed download imported")
        let watcher = makeWatcher(over: directory, log: log, onImport: landed)
        XCTAssertTrue(watcher.start(seedExisting: false))

        let partial = directory.appending(path: "archive.zip.crdownload")
        try Data("bytes".utf8).write(to: partial)
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(log.importedNames, [], "an in-progress name must never import")

        try FileManager.default.moveItem(
            at: partial,
            to: directory.appending(path: "archive.zip")
        )
        wait(for: [landed], timeout: 5)
        XCTAssertEqual(log.importedNames, ["archive.zip"])
    }

    func testLaunchScanPrunesGoneFilesAndCatchesUpOnUnledgeredOnes() throws {
        let directory = try makeTemporaryDirectory()
        let stayed = directory.appending(path: "already-shelved.pdf")
        try Data("kept".utf8).write(to: stayed)
        let missed = directory.appending(path: "arrived-while-quit.png")
        try Data("missed".utf8).write(to: missed)

        let stayedToken = try FolderWatchRules.identityToken(forFileAt: stayed)
        let goneToken = String(repeating: "0", count: 64)

        let log = ImportLog()
        let landed = expectation(description: "unledgered file caught up")
        let watcher = makeWatcher(
            over: directory,
            ledger: [stayedToken, goneToken],
            log: log,
            onImport: landed
        )
        XCTAssertTrue(watcher.start(seedExisting: false))

        wait(for: [landed], timeout: 5)
        XCTAssertEqual(log.importedNames, ["arrived-while-quit.png"])
        XCTAssertEqual(log.replacedLedgers, [[stayedToken]])
    }

    private func waitUntil(
        _ what: String,
        timeout: TimeInterval = 5,
        condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                return XCTFail("Timed out waiting until \(what)")
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "PerchFolderWatch-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
