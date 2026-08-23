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
        XCTAssertNil(folder.lastEventID, "a folder perch has never caught up on has no position")
        store.markImported("token-1", for: folder.id)
        store.setTokens(["token-2", "token-3"], for: folder.id)
        store.setLastEventID(4_815_162_342, for: folder.id)
        store.flushPendingWrites()

        let reloaded = WatchedFolderStore(fileURL: configURL, bookmarking: .plain)
        XCTAssertEqual(reloaded.folders.count, 1)
        XCTAssertEqual(reloaded.folders.first?.id, folder.id)
        XCTAssertEqual(reloaded.folders.first?.importedTokens, ["token-2", "token-3"])
        // The stream position is what makes a relaunch resume rather than
        // start blind at `kFSEventStreamEventIdSinceNow`.
        XCTAssertEqual(reloaded.folders.first?.lastEventID, 4_815_162_342)
        let resolved = try reloaded.bookmarking.resolve(try XCTUnwrap(reloaded.folders.first).bookmark)
        XCTAssertEqual(
            resolved.url.standardizedFileURL.resolvingSymlinksInPath().path,
            watched.standardizedFileURL.resolvingSymlinksInPath().path
        )

        // A config written before positions were persisted still decodes, and
        // reads as "no position" rather than failing the whole file.
        let legacy = directory.appending(path: "legacy.json")
        try Data("""
        [{"id":"\(folder.id.uuidString)","bookmark":"","importedTokens":["token-2"]}]
        """.utf8).write(to: legacy)
        let upgraded = WatchedFolderStore(fileURL: legacy, bookmarking: .plain)
        XCTAssertEqual(upgraded.folders.count, 1)
        XCTAssertNil(upgraded.folders.first?.lastEventID)

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
        private var adopted: [String] = []
        private var eventIDs: [UInt64] = []

        func recordImport(of url: URL, token: String = "") {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
            lock.withLock { imported.append((url.lastPathComponent, size, token)) }
        }

        func recordLedger(_ tokens: Set<String>) {
            lock.withLock { ledgers.append(tokens) }
        }

        func recordAdoption(of token: String) {
            lock.withLock { adopted.append(token) }
        }

        var adoptedTokens: [String] { lock.withLock { adopted } }

        var importedNames: [String] { lock.withLock { imported.map(\.name) } }
        var importedSizes: [Int] { lock.withLock { imported.map(\.sizeAtImport) } }
        var importedTokens: [String] { lock.withLock { imported.map(\.token) } }
        var replacedLedgers: [Set<String>] { lock.withLock { ledgers } }

        func recordEventID(_ eventID: UInt64) {
            lock.withLock { eventIDs.append(eventID) }
        }

        var reportedEventIDs: [UInt64] { lock.withLock { eventIDs } }
    }

    private func makeWatcher(
        over directory: URL,
        ledger: Set<String> = [],
        sinceEventID: UInt64? = nil,
        requiredStableProbes: Int = 2,
        positionReportInterval: TimeInterval = 0,
        exportLedger: ExportLedger = ExportLedger(),
        log: ImportLog,
        onImport: XCTestExpectation? = nil,
        onAdopt: XCTestExpectation? = nil
    ) -> FolderWatcher {
        let watcher = FolderWatcher(
            folderID: UUID(),
            folderURL: directory,
            ledger: ledger,
            sinceEventID: sinceEventID,
            holdsSecurityScope: false,
            probeInterval: 0.05,
            requiredStableProbes: requiredStableProbes,
            // FSEvents coalesces; the production 0.5 s window would make every
            // multi-step test below wait on the batcher rather than on the
            // behaviour it is asserting.
            eventLatency: 0.05,
            // The production 5 s floor exists to spare the config file, not
            // to be asserted here; every test but the throttle's own wants a
            // position the moment there is one.
            positionReportInterval: positionReportInterval,
            exportLedger: exportLedger,
            onImport: { url, token in
                log.recordImport(of: url, token: token)
                onImport?.fulfill()
            },
            onAdopt: { token in
                log.recordAdoption(of: token)
                onAdopt?.fulfill()
            },
            onLedgerReplaced: { tokens in
                log.recordLedger(tokens)
            },
            onEventID: { eventID in
                log.recordEventID(eventID)
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

    /// #6, end to end: `curl -o ~/Downloads/slow.bin` over an existing path
    /// truncates and rewrites it — same inode, same birth date, same directory
    /// entry — and that has to land as a second arrival.
    ///
    /// Both halves are exercised here. The identity has to differ (fixed in
    /// #88, by hashing size and mtime), and *something has to notice the write
    /// at all*: nothing else in this folder changes, which is precisely what a
    /// directory kqueue could not see and what FSEvents reports as
    /// `ItemModified`. The crutch this test used to need — a second file
    /// created purely to fire an event — is gone.
    func testAFileRewrittenInPlaceLandsAgainWithNoOtherChangeInTheFolder() throws {
        let directory = try makeTemporaryDirectory()
        let target = directory.appending(path: "slow.bin")
        try Data("first".utf8).write(to: target)

        let log = ImportLog()
        // No expectation here: this file is meant to import twice, and an
        // XCTestExpectation traps on the second fulfill.
        let watcher = makeWatcher(over: directory, log: log)
        watcher.start(seedExisting: false)
        waitUntil("the first download lands") { log.importedNames == ["slow.bin"] }

        // Same path, same inode, new contents — what `curl -o` does. And the
        // only thing that happens: no create, no rename, no second file.
        let handle = try FileHandle(forWritingTo: target)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("a second, longer download".utf8))
        try handle.close()

        // FSEvents is latency-delayed and coalescing, so this is generous on
        // purpose — a slow batch must read as slow, never as a lost event.
        waitUntil("the rewritten file lands again", timeout: 15) {
            log.importedNames.filter { $0 == "slow.bin" }.count == 2
        }
        XCTAssertEqual(log.importedNames, ["slow.bin", "slow.bin"])
        let slowImports = log.importedTokens
        XCTAssertNotEqual(slowImports.first, slowImports.last)
    }

    /// The stream position perch persists: real, monotonic, and only ever
    /// advanced by a scan that already ran. It is what `WatchedFolderStore`
    /// stores per folder so the next launch resumes there instead of at
    /// `kFSEventStreamEventIdSinceNow` (#8).
    func testTheWatcherReportsAStreamPositionToResumeFrom() throws {
        let directory = try makeTemporaryDirectory()
        let log = ImportLog()
        let watcher = makeWatcher(over: directory, log: log)
        watcher.start(seedExisting: false)

        try Data("one".utf8).write(to: directory.appending(path: "a.txt"))
        waitUntil("a stream position is reported", timeout: 15) { !log.reportedEventIDs.isEmpty }

        try Data("two".utf8).write(to: directory.appending(path: "b.txt"))
        waitUntil("a second, later position", timeout: 15) { log.reportedEventIDs.count >= 2 }

        let reported = log.reportedEventIDs
        // The end-of-history marker carries id 0 and must never be persisted
        // as a position, and positions only ever move forward.
        XCTAssertTrue(reported.allSatisfy { $0 > 0 })
        XCTAssertEqual(reported, reported.sorted())
        XCTAssertEqual(Set(reported).count, reported.count)
    }

    /// Resuming from a persisted position replays what happened while perch
    /// was down — the mechanism behind #8. Isolated deliberately: the folder
    /// is quiet from the moment the second watcher starts, and its ledger
    /// already holds everything on disk, so the launch catch-up scan has
    /// nothing to say. Any event it reports came out of FSEvents' history.
    ///
    /// The launch rescan is still perch's primary catch-up, and it would find
    /// a missed *arrival* on its own. What replay adds is that the stream
    /// itself covers the downtime rather than the rescan being the only thing
    /// that does — so this asserts the replay happens, not that it is the only
    /// path to a file.
    func testAResumedStreamReplaysHistoryAQuietFolderWouldNotProduce() throws {
        let directory = try makeTemporaryDirectory()

        let first = ImportLog()
        let watcher = makeWatcher(over: directory, log: first)
        watcher.start(seedExisting: false)
        try Data("one".utf8).write(to: directory.appending(path: "a.txt"))
        waitUntil("a stream position to resume from", timeout: 15) { !first.reportedEventIDs.isEmpty }
        let resumeFrom = try XCTUnwrap(first.reportedEventIDs.first)

        // Everything that happens while perch is "not running".
        watcher.stop()
        try Data("two".utf8).write(to: directory.appending(path: "b.txt"))
        try Data("three".utf8).write(to: directory.appending(path: "c.txt"))

        // A ledger holding the whole folder: the catch-up scan imports nothing
        // and reports nothing, so only replay can make this watcher speak.
        let ledger = Set(
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .map { try FolderWatchRules.identityToken(forFileAt: $0) }
        )

        let replayed = ImportLog()
        let resumed = makeWatcher(over: directory, ledger: ledger, sinceEventID: resumeFrom, log: replayed)
        resumed.start(seedExisting: false)
        waitUntil("the missed writes are replayed", timeout: 15) { !replayed.reportedEventIDs.isEmpty }
        XCTAssertGreaterThan(try XCTUnwrap(replayed.reportedEventIDs.last), resumeFrom)
        XCTAssertEqual(replayed.importedNames, [], "a fully ledgered folder imports nothing on replay")
        let replayedThrough = try XCTUnwrap(replayed.reportedEventIDs.last)
        resumed.stop()

        // The control: the same folder, started with no position. It must not
        // replay any of that history — which is what a folder perch just added
        // does, and what every launch did before positions were persisted.
        // Asserted by making it speak rather than by sleeping and hoping: it
        // is given a brand-new file, and the *first* thing it ever reports has
        // to be that file, not the writes it was started after.
        let blind = ImportLog()
        let fresh = makeWatcher(over: directory, ledger: ledger, log: blind)
        fresh.start(seedExisting: false)
        try Data("four".utf8).write(to: directory.appending(path: "d.txt"))
        waitUntil("the control hears its own arrival", timeout: 15) { !blind.reportedEventIDs.isEmpty }
        XCTAssertGreaterThan(
            try XCTUnwrap(blind.reportedEventIDs.first),
            replayedThrough,
            "starting at since-now must replay nothing that happened before it"
        )
    }

    /// FSEvents watches recursively and reports every write underneath a
    /// watched folder, so an unthrottled position report would re-encode and
    /// rewrite the whole config once per latency window for as long as
    /// anything in the subtree is busy. The floor holds, and the last position
    /// in a burst is still the one that gets reported — dropping *that* one
    /// would leave the persisted position permanently behind.
    func testStreamPositionsAreThrottledButTheLastOneStillArrives() throws {
        let directory = try makeTemporaryDirectory()
        let log = ImportLog()
        let watcher = makeWatcher(over: directory, positionReportInterval: 0.6, log: log)
        watcher.start(seedExisting: false)

        for index in 0..<8 {
            try Data("x".utf8).write(to: directory.appending(path: "f\(index).txt"))
            Thread.sleep(forTimeInterval: 0.1)
        }
        // The first report goes out immediately; the throttle then swallows the
        // rest of the burst and owes a trailing one. Count the reports rather
        // than watching for a *higher* id than one sampled mid-burst: under
        // parallel test hosts the sample can land after the trailing report has
        // already fired, and then nothing else in the folder will ever move.
        waitUntil("the trailing position", timeout: 15) {
            log.reportedEventIDs.count >= 2
        }
        // One snapshot, asserted twice — reading the watcher's log again here
        // could pick up a report that landed between the two reads.
        let reported = log.reportedEventIDs
        XCTAssertLessThanOrEqual(
            reported.count, 3,
            "eight arrivals over ~0.8 s must not cost eight config writes"
        )
        XCTAssertEqual(
            reported, reported.sorted(),
            "positions only ever move forward"
        )
    }

    /// Field-test, 2026-08-23: two `curl -o` downloads running at once looked
    /// like only one file ever landed. On *separate* paths that must not
    /// happen — each file gets its own probe chain, and one still growing must
    /// never hold up another that has settled.
    ///
    /// Two curls onto the *same* path are a different story and not a bug: one
    /// path is one file, it never holds still until the last writer stops, so
    /// one tile at the end is the only answer available. See the note under
    /// "Not bugs" in the 2026-08-22 field-test file.
    ///
    /// The writers here append *continuously* — faster than
    /// `probeInterval × requiredStableProbes`. Growing in slower bursts leaves
    /// a quiet window between them, and the probe promotes on each one, which
    /// is D2's intended "replaced contents are a new arrival" and not what this
    /// test is about.
    func testTwoFilesGrowingAtOnceBothLand() throws {
        let directory = try makeTemporaryDirectory()
        let log = ImportLog()
        let watcher = makeWatcher(over: directory, log: log)
        watcher.start(seedExisting: false)

        let first = directory.appending(path: "first.bin")
        let second = directory.appending(path: "second.bin")

        /// Appends `chunks` × 500 B at 15 ms intervals, like a download that
        /// never pauses. Returns once the file is complete.
        func download(to url: URL, chunks: Int) throws {
            try Data(repeating: 7, count: 500).write(to: url)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            for _ in 1..<chunks {
                Thread.sleep(forTimeInterval: 0.015)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(repeating: 7, count: 500))
            }
        }

        // `second` starts first and finishes while `first` is still going, so
        // one file settles with the other mid-flight — the shape of the
        // field-test report. Neither is ever rewritten, so neither is a second
        // arrival.
        let secondFinished = expectation(description: "second written")
        DispatchQueue.global().async {
            try? download(to: second, chunks: 10)
            secondFinished.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.05)
        try download(to: first, chunks: 24)
        wait(for: [secondFinished], timeout: 10)

        waitUntil("both files land", timeout: 10) {
            Set(log.importedNames) == ["first.bin", "second.bin"]
        }
        XCTAssertEqual(log.importedNames.sorted(), ["first.bin", "second.bin"])
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


    // MARK: - Drag-out into a watched folder

    /// The round-trip: `~/Downloads` and `~/Desktop` are both the folders
    /// people watch and the folders people drag onto, and an export lands
    /// there as a brand-new inode — an identity no ledger has seen. Without
    /// the export ledger the watcher shelves the item the user just took out,
    /// which reads as the tile never leaving.
    func testAFilePerchExportedIsAdoptedRatherThanShelvedBack() throws {
        let directory = try makeTemporaryDirectory()
        let source = try makeTemporaryDirectory().appending(path: "staged.txt")
        try Data("exported".utf8).write(to: source)

        let exportLedger = ExportLedger()
        let log = ImportLog()
        let adopted = expectation(description: "export adopted")
        let watcher = makeWatcher(
            over: directory,
            exportLedger: exportLedger,
            log: log,
            onAdopt: adopted
        )
        // What `FolderWatchCenter` wires in production: perch writes the last
        // byte itself, so the folder can fall quiet with no event left to
        // trigger the scan that would claim the file.
        exportLedger.onWritten = { [weak watcher] _ in watcher?.rescan() }
        watcher.start(seedExisting: false)

        // Exactly the promise's sequence: reserve, copy, confirm.
        let destination = directory.appending(path: "staged.txt")
        exportLedger.willWrite(to: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        exportLedger.didWrite(to: destination)

        wait(for: [adopted], timeout: 5)
        // Long enough for a probe cycle to have promoted it, had it started one.
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(log.importedNames, [], "a drag-out must not come straight back")
        XCTAssertEqual(
            log.adoptedTokens,
            [try FolderWatchRules.identityToken(forFileAt: destination)],
            "the token is ledgered so a later scan does not treat it as an arrival"
        )
    }

    /// Adopting one file must not put the watcher to sleep: the folder is
    /// still watched, and the next genuine arrival still belongs on the shelf.
    func testTheWatcherKeepsImportingAfterAnAdoption() throws {
        let directory = try makeTemporaryDirectory()
        let exportLedger = ExportLedger()
        let log = ImportLog()
        let adopted = expectation(description: "export adopted")
        let landed = expectation(description: "the later arrival imported")
        let watcher = makeWatcher(
            over: directory,
            exportLedger: exportLedger,
            log: log,
            onImport: landed,
            onAdopt: adopted
        )
        exportLedger.onWritten = { [weak watcher] _ in watcher?.rescan() }
        watcher.start(seedExisting: false)

        let destination = directory.appending(path: "note.txt")
        exportLedger.willWrite(to: destination)
        try Data("ours".utf8).write(to: destination)
        exportLedger.didWrite(to: destination)
        wait(for: [adopted], timeout: 5)

        try Data("theirs".utf8).write(to: directory.appending(path: "other.txt"))
        wait(for: [landed], timeout: 5)
        XCTAssertEqual(log.importedNames, ["other.txt"])
    }

    /// A promise whose copy threw leaves nothing of ours at that path, so the
    /// reservation must not swallow whatever genuinely arrives there next.
    func testACancelledExportDoesNotSwallowARealArrival() throws {
        let directory = try makeTemporaryDirectory()
        let exportLedger = ExportLedger()
        let log = ImportLog()
        let landed = expectation(description: "the real arrival imported")
        let watcher = makeWatcher(
            over: directory,
            exportLedger: exportLedger,
            log: log,
            onImport: landed
        )
        watcher.start(seedExisting: false)

        let destination = directory.appending(path: "contested.txt")
        exportLedger.willWrite(to: destination)
        exportLedger.cancelWrite(at: destination)
        try Data("a genuine download".utf8).write(to: destination)

        wait(for: [landed], timeout: 5)
        XCTAssertEqual(log.importedNames, ["contested.txt"])
        XCTAssertEqual(log.adoptedTokens, [])
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

/// The book the export path and the watchers share. Its whole job is to be
/// right about *which* file is perch's own, so each verdict gets a case.
final class ExportLedgerTests: XCTestCase {
    func testAPathNobodyReservedIsUnrelated() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appending(path: "stranger.txt")
        try Data("hi".utf8).write(to: file)

        let ledger = ExportLedger()
        XCTAssertEqual(
            ledger.claim(file, token: try FolderWatchRules.identityToken(forFileAt: file)),
            .unrelated
        )
    }

    func testAReservationIsInFlightUntilTheCopyConfirms() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appending(path: "half.txt")

        let ledger = ExportLedger()
        ledger.willWrite(to: file)
        // The copy has started; the file exists but its identity is not final.
        try Data("part".utf8).write(to: file)
        XCTAssertEqual(
            ledger.claim(file, token: try FolderWatchRules.identityToken(forFileAt: file)),
            .inFlight,
            "a half-written export must not be ledgered at the identity it has mid-copy"
        )

        try Data("part and the rest".utf8).write(to: file)
        ledger.didWrite(to: file)
        let settled = try FolderWatchRules.identityToken(forFileAt: file)
        XCTAssertEqual(ledger.claim(file, token: settled), .ours)
        XCTAssertEqual(
            ledger.claim(file, token: settled),
            .unrelated,
            "the claim is consumed — a second sighting is an ordinary arrival"
        )
    }

    func testAnIdentityThatMovedOnIsSomebodyElsesFile() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appending(path: "replaced.txt")

        let ledger = ExportLedger()
        ledger.willWrite(to: file)
        try Data("ours".utf8).write(to: file)
        ledger.didWrite(to: file)

        // Same path, different contents: `curl -o` onto what perch exported.
        try Data("theirs, and longer".utf8).write(to: file)
        XCTAssertEqual(
            ledger.claim(file, token: try FolderWatchRules.identityToken(forFileAt: file)),
            .unrelated
        )
    }

    func testAReservationExpires() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appending(path: "abandoned.txt")

        let ledger = ExportLedger(lifetime: 0.05)
        ledger.willWrite(to: file)
        try Data("nobody claimed me".utf8).write(to: file)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(
            ledger.claim(file, token: try FolderWatchRules.identityToken(forFileAt: file)),
            .unrelated,
            "a destination outside every watched folder must not blind that path forever"
        )
    }

    func testTheDestinationIsMatchedThroughSymlinkedPathSpellings() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appending(path: "spelled.txt")
        try Data("same file".utf8).write(to: file)

        let ledger = ExportLedger()
        ledger.willWrite(to: file)
        ledger.didWrite(to: file)

        // What a watcher hands back: the folder URL its bookmark resolved to,
        // with the entry appended. `/var` against `/private/var` is the
        // disagreement every temporary directory walks into.
        let asWatcherSeesIt = directory.resolvingSymlinksInPath().appending(path: "spelled.txt")
        XCTAssertEqual(
            ledger.claim(asWatcherSeesIt, token: try FolderWatchRules.identityToken(forFileAt: file)),
            .ours
        )
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "PerchFolderWatch-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
