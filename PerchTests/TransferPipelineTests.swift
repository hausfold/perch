import Foundation
import os
import XCTest
@testable import Perch

final class TransferPipelineTests: XCTestCase {
    func testStagesFileAsPrivateCopy() async throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appending(path: "PerchPipeline-\(UUID().uuidString)", directoryHint: .isDirectory)
        let sourceRoot = FileManager.default.temporaryDirectory
            .appending(path: "PerchSource-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: testRoot)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        let source = sourceRoot.appending(path: "large.mov")
        let sourceData = Data(repeating: 0x2A, count: 128 * 1024)
        try sourceData.write(to: source)

        let repository = try StagingRepository(rootURL: testRoot)
        let pipeline = TransferPipeline(repository: repository)
        let item = try await pipeline.stageFile(
            at: source,
            itemID: UUID(),
            phaseChanged: { _ in }
        )
        let stagedURL = try XCTUnwrap(item.fileURL(inside: repository.rootURL))

        XCTAssertNotEqual(stagedURL, source)
        XCTAssertEqual(try Data(contentsOf: stagedURL), sourceData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    // MARK: - iCloud (#2)

    /// The field-test symptom was a tile stuck on "Downloading" with no way to
    /// tell a slow download from a wedged one. Two minutes of `Thread.sleep`
    /// held one of the queue's two slots, so two cloud files also stalled every
    /// ordinary drop behind them. The wait now runs before the queue, and says
    /// out loud how long it has been waiting.
    func testCloudWaitReportsElapsedSecondsAndThenSucceeds() async throws {
        let probeCount = OSAllocatedUnfairLock(initialState: 0)
        let waiter = CloudDownloadWaiter(
            timeout: .seconds(5),
            pollInterval: .milliseconds(10),
            probe: { _ in
                probeCount.withLock { count in
                    count += 1
                    return count > 40 ? .downloaded : .downloading
                }
            }
        )

        let reported = OSAllocatedUnfairLock(initialState: [Int]())
        try await waiter.wait(for: URL(fileURLWithPath: "/dev/null")) { elapsed in
            reported.withLock { $0.append(elapsed) }
        }

        let elapsed = reported.withLock { $0 }
        XCTAssertEqual(elapsed.first, 0, "the tile must go to 'Downloading' immediately")
        XCTAssertEqual(elapsed, elapsed.sorted(), "elapsed seconds only ever climb")
        XCTAssertEqual(elapsed, Array(Set(elapsed)).sorted(), "one update per second, not per poll")
    }

    /// Field-test, 2026-08-23: the tile still sat on "Downloading" while Finder
    /// showed the file had arrived. A `URL` caches resource values on its
    /// `NSURL` box, so every poll of the same URL returned the status read the
    /// *first* time — the wait could only ever end at its deadline. Pinned with
    /// file size, which needs no iCloud account and moves the same way.
    func testTheProbeSeesValuesChangeRatherThanTheFirstReadForever() throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "perch-rvcache-\(UUID().uuidString).bin")
        try Data(repeating: 0, count: 100).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertEqual(
            try CloudDownloadWaiter.uncachedResourceValues(of: file, forKeys: [.fileSizeKey])
                .fileSize,
            100
        )
        try Data(repeating: 0, count: 5_000).write(to: file)
        XCTAssertEqual(
            try CloudDownloadWaiter.uncachedResourceValues(of: file, forKeys: [.fileSizeKey])
                .fileSize,
            5_000,
            "a second read must see the new size, not the cached one"
        )

        // And the cache this exists to defeat is real, so the guard is not
        // decoration: the plain call still answers with the first read.
        let cached = file
        _ = try cached.resourceValues(forKeys: [.fileSizeKey])
        try Data(repeating: 0, count: 9_000).write(to: file)
        XCTAssertEqual(try cached.resourceValues(forKeys: [.fileSizeKey]).fileSize, 5_000)
    }

    /// "Never started" and "did not finish in time" look identical on screen and
    /// have different answers, so they are different errors.
    func testCloudWaitDistinguishesNeverStartedFromTimedOut() async throws {
        let neverStarted = CloudDownloadWaiter(
            timeout: .milliseconds(60),
            pollInterval: .milliseconds(10),
            probe: { _ in .notStarted }
        )
        do {
            try await neverStarted.wait(for: URL(fileURLWithPath: "/dev/null")) { _ in }
            XCTFail("A download that never starts must fail")
        } catch {
            XCTAssertEqual(error as? TransferPipelineError, .cloudDownloadNeverStarted)
        }

        let tooSlow = CloudDownloadWaiter(
            timeout: .milliseconds(60),
            pollInterval: .milliseconds(10),
            probe: { _ in .downloading }
        )
        do {
            try await tooSlow.wait(for: URL(fileURLWithPath: "/dev/null")) { _ in }
            XCTFail("A download that never finishes must fail")
        } catch {
            XCTAssertEqual(error as? TransferPipelineError, .cloudDownloadTimedOut)
        }
    }

    /// The half of #2 that is not about the spinner: a cloud wait must not
    /// occupy one of the pipeline's two slots. Two files waiting on iCloud used
    /// to hold both, so every ordinary drop behind them stalled for up to two
    /// minutes — which is what "sticks forever" looked like from the outside.
    func testACloudWaitDoesNotBlockOrdinaryImports() async throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appending(path: "PerchPipeline-\(UUID().uuidString)", directoryHint: .isDirectory)
        let sourceRoot = FileManager.default.temporaryDirectory
            .appending(path: "PerchSource-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: testRoot)
            try? FileManager.default.removeItem(at: sourceRoot)
        }

        // Files whose name starts with "cloud-" stand in for evicted iCloud
        // items: they exist on disk, so the copy that follows the wait is real.
        let releaseTheCloud = OSAllocatedUnfairLock(initialState: false)
        let pipeline = TransferPipeline(
            repository: try StagingRepository(rootURL: testRoot),
            cloudWaiter: CloudDownloadWaiter(
                timeout: .seconds(30),
                pollInterval: .milliseconds(10),
                isUndownloadedCloudItem: { $0.lastPathComponent.hasPrefix("cloud-") },
                startDownload: { _ in },
                probe: { _ in releaseTheCloud.withLock { $0 } ? .downloaded : .downloading }
            )
        )

        func write(_ name: String) throws -> URL {
            let url = sourceRoot.appending(path: name)
            try name.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        // Two cloud items — the full width of the queue — left waiting.
        let cloudSources = [try write("cloud-a.txt"), try write("cloud-b.txt")]
        async let cloudItems = withThrowingTaskGroup(of: ShelfItem.self) { group in
            for source in cloudSources {
                group.addTask {
                    try await pipeline.stageFile(at: source, itemID: UUID(), phaseChanged: { _ in })
                }
            }
            return try await group.reduce(into: [ShelfItem]()) { $0.append($1) }
        }

        // Three ordinary drops must land while those two are still waiting.
        // Before the fix this deadlocked until the 120 s timeout fired.
        for index in 0..<3 {
            let item = try await pipeline.stageFile(
                at: try write("ordinary-\(index).txt"),
                itemID: UUID(),
                phaseChanged: { _ in }
            )
            XCTAssertEqual(item.displayName, "ordinary-\(index).txt")
        }

        releaseTheCloud.withLock { $0 = true }
        let landed = try await cloudItems.map(\.displayName).sorted()
        XCTAssertEqual(landed, ["cloud-a.txt", "cloud-b.txt"])
    }

    /// A drop that is not an iCloud item never waits and never says
    /// "Downloading" — the wait is opt-in per file, not a phase every import
    /// passes through.
    func testAnOrdinaryFileNeverEntersTheCloudWait() async throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appending(path: "PerchPipeline-\(UUID().uuidString)", directoryHint: .isDirectory)
        let sourceRoot = FileManager.default.temporaryDirectory
            .appending(path: "PerchSource-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: testRoot)
            try? FileManager.default.removeItem(at: sourceRoot)
        }

        let probed = OSAllocatedUnfairLock(initialState: false)
        let pipeline = TransferPipeline(
            repository: try StagingRepository(rootURL: testRoot),
            cloudWaiter: CloudDownloadWaiter(
                isUndownloadedCloudItem: { _ in false },
                probe: { _ in
                    probed.withLock { $0 = true }
                    return .downloaded
                }
            )
        )

        let source = sourceRoot.appending(path: "local.txt")
        try "local".write(to: source, atomically: true, encoding: .utf8)
        let phases = OSAllocatedUnfairLock(initialState: [PendingTransfer.Phase]())
        _ = try await pipeline.stageFile(at: source, itemID: UUID()) { phase in
            phases.withLock { $0.append(phase) }
        }

        XCTAssertFalse(probed.withLock { $0 })
        XCTAssertEqual(phases.withLock { $0 }, [.copying])
    }

    /// Save to… copies out and keeps the shelf's copy: the staged bytes are the
    /// source of the copy, never its casualty, so saving twice or saving over
    /// something is safe and the tile survives either way.
    func testCopiesOutWithoutDisturbingTheStagedCopy() async throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appending(path: "PerchPipeline-\(UUID().uuidString)", directoryHint: .isDirectory)
        let destinationRoot = FileManager.default.temporaryDirectory
            .appending(path: "PerchSaveTo-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: destinationRoot,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: testRoot)
            try? FileManager.default.removeItem(at: destinationRoot)
        }

        let repository = try StagingRepository(rootURL: testRoot)
        let pipeline = TransferPipeline(repository: repository)
        let staged = try await pipeline.stageText(
            "saved",
            suggestedName: "note.txt",
            itemID: UUID()
        )
        let stagedURL = try XCTUnwrap(staged.fileURL(inside: repository.rootURL))

        let destination = destinationRoot.appending(path: "note.txt")
        try await pipeline.copyOut(from: stagedURL, to: destination)

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "saved")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))

        // The panel takes the user's answer to "replace it?" and then hands us
        // an existing path anyway; `copyItem` alone would fail there.
        try "stale".write(to: destination, atomically: true, encoding: .utf8)
        try await pipeline.copyOut(from: stagedURL, to: destination)

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "saved")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))

        // And the replace is all-or-nothing. A copy that fails must leave what
        // was already at the destination untouched — deleting first and then
        // failing would take the user's file and give nothing back, and perch
        // is sandboxed, so it would not be in the Trash either.
        try "theirs".write(to: destination, atomically: true, encoding: .utf8)
        let vanished = repository.rootURL.appending(path: "gone-\(UUID().uuidString)")
        do {
            try await pipeline.copyOut(from: vanished, to: destination)
            XCTFail("Copying from a missing staged file should fail")
        } catch {
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "theirs")
        }
    }
}
