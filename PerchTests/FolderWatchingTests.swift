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

    func testIdentityTokenSurvivesRenameButChangesOnRewrite() throws {
        let directory = try makeTemporaryDirectory()
        let original = directory.appending(path: "a.txt")
        try Data("one".utf8).write(to: original)
        let token = try FolderWatchRules.identityToken(forFileAt: original)

        // Renaming keeps the inode and birth date, and does not touch the
        // contents — so the identity holds, and a shelved file the user renames
        // must not land twice.
        let renamed = directory.appending(path: "b.txt")
        try FileManager.default.moveItem(at: original, to: renamed)
        XCTAssertEqual(try FolderWatchRules.identityToken(forFileAt: renamed), token)

        // Rewriting it does change the identity: same inode, new contents is a
        // new arrival (#6 — that is what `curl -o` to an existing path does).
        let handle = try FileHandle(forWritingTo: renamed)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" two".utf8))
        try handle.close()
        XCTAssertNotEqual(try FolderWatchRules.identityToken(forFileAt: renamed), token)

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
        store.flushPendingWrites()

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
        store.flushPendingWrites()
        XCTAssertTrue(store.folders.isEmpty)
        XCTAssertTrue(WatchedFolderStore(fileURL: configURL, bookmarking: .plain).folders.isEmpty)
    }
}

final class FolderWatcherTests: XCTestCase {
    /// Everything a watcher reported, safe to poke from its queue and the test.
    private final class ImportLog: @unchecked Sendable {
        private let lock = NSLock()
        private var imported: [(name: String, sizeAtImport: Int, token: String)] = []
        private var ledgers: [Set<String>] = []

        func recordImport(of url: URL, token: String = "") {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
            lock.withLock { imported.append((url.lastPathComponent, size, token)) }
        }

        func recordLedger(_ tokens: Set<String>) {
            lock.withLock { ledgers.append(tokens) }
        }

        var importedNames: [String] { lock.withLock { imported.map(\.name) } }
        var importedSizes: [Int] { lock.withLock { imported.map(\.sizeAtImport) } }
        var importedTokens: [String] { lock.withLock { imported.map(\.token) } }
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
            onImport: { url, token in
                log.recordImport(of: url, token: token)
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
        watcher.start(seedExisting: false)

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
        watcher.start(seedExisting: true)

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
        watcher.start(seedExisting: false)

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
        watcher.start(seedExisting: false)

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
        let goneToken = "\(FolderWatchRules.tokenFormat):" + String(repeating: "0", count: 64)

        let log = ImportLog()
        let landed = expectation(description: "unledgered file caught up")
        let watcher = makeWatcher(
            over: directory,
            ledger: [stayedToken, goneToken],
            log: log,
            onImport: landed
        )
        watcher.start(seedExisting: false)

        wait(for: [landed], timeout: 5)
        XCTAssertEqual(log.importedNames, ["arrived-while-quit.png"])
        XCTAssertEqual(log.replacedLedgers, [[stayedToken]])
    }

    /// #6, the half that is fixed here: a rewritten file is no longer deduped
    /// against its own earlier contents. `curl -o ~/Downloads/x.bin` truncates
    /// and rewrites an existing path, keeping its inode and birth date, so an
    /// identity built from those alone matched the first download forever.
    ///
    /// Note what this test has to do to make it land: create a *second* file to
    /// fire a directory event. A directory kqueue reports entries appearing,
    /// disappearing and being renamed — never a write into a file that is
    /// already there. So the rewrite alone still produces no event and no scan;
    /// see the Run D notes in `docs/field-test-2026-08-22.md`.
    func testARewrittenFileIsNoLongerDedupedAgainstItsOwnEarlierContents() throws {
        let directory = try makeTemporaryDirectory()
        let target = directory.appending(path: "slow.bin")
        try Data("first".utf8).write(to: target)

        let log = ImportLog()
        // No expectation here: this file is meant to import twice, and an
        // XCTestExpectation traps on the second fulfill.
        let watcher = makeWatcher(over: directory, log: log)
        watcher.start(seedExisting: false)
        waitUntil("the first download lands") { log.importedNames == ["slow.bin"] }

        // Same path, same inode, new contents — what `curl -o` does.
        let handle = try FileHandle(forWritingTo: target)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("a second, longer download".utf8))
        try handle.close()
        // Any directory event at all is enough to make the watcher look again.
        try Data("nudge".utf8).write(to: directory.appending(path: "other.txt"))

        waitUntil("the rewritten file lands again") {
            log.importedNames.filter { $0 == "slow.bin" }.count == 2
        }
        let slowImports = log.importedTokens.enumerated()
            .filter { log.importedNames[$0.offset] == "slow.bin" }
            .map(\.element)
        XCTAssertNotEqual(slowImports.first, slowImports.last)
    }

    /// A pure rename must still not re-import — the property the token exists
    /// for, and the one the content half must not cost.
    func testARenameStillDoesNotReimport() throws {
        let directory = try makeTemporaryDirectory()
        let original = directory.appending(path: "scan.pdf")
        try Data("contents".utf8).write(to: original)

        let log = ImportLog()
        let landed = expectation(description: "file imported once")
        let watcher = makeWatcher(over: directory, log: log, onImport: landed)
        watcher.start(seedExisting: false)
        wait(for: [landed], timeout: 5)

        try FileManager.default.moveItem(at: original, to: directory.appending(path: "scan-final.pdf"))
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(log.importedNames, ["scan.pdf"])
    }

    /// D1: the ledger records arrivals that *landed*. A file whose staging
    /// failed has to be reachable again, or one transient error makes it
    /// permanently invisible to the watcher.
    func testAFailedImportIsRetriedOnTheNextEvent() throws {
        let directory = try makeTemporaryDirectory()
        let log = ImportLog()
        let watcher = makeWatcher(over: directory, log: log)
        watcher.start(seedExisting: false)

        let file = directory.appending(path: "flaky.txt")
        try Data("hello".utf8).write(to: file)
        waitUntil("the first attempt") { log.importedNames == ["flaky.txt"] }

        // Staging failed: the center hands the token back.
        watcher.forgetImport(log.importedTokens[0])
        // Any later directory event re-probes it.
        try Data("nudge".utf8).write(to: directory.appending(path: "other.txt"))

        waitUntil("the failed file is retried") { log.importedNames.filter { $0 == "flaky.txt" }.count == 2 }
    }

    /// A ledger written before the token recipe changed matches nothing, so
    /// pruning it would empty it and the catch-up scan would import the whole
    /// folder at once. Adopt what is there instead — once, on that launch.
    func testALedgerInAnOlderTokenFormatIsAdoptedRatherThanReimported() throws {
        let directory = try makeTemporaryDirectory()
        try Data("one".utf8).write(to: directory.appending(path: "a.txt"))
        try Data("two".utf8).write(to: directory.appending(path: "b.txt"))

        let log = ImportLog()
        // 64 hex chars, no format prefix: exactly what perch used to persist.
        let watcher = makeWatcher(
            over: directory,
            ledger: [String(repeating: "a", count: 64)],
            log: log
        )
        watcher.start(seedExisting: false)

        waitUntil("the ledger is re-seeded") { log.replacedLedgers.count == 1 }
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(log.importedNames, [], "an upgrade must not flood the shelf")
        XCTAssertEqual(log.replacedLedgers.first?.count, 2)
        XCTAssertTrue(log.replacedLedgers.first?.allSatisfy(FolderWatchRules.isCurrentFormat) == true)
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
