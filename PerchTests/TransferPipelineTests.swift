import Foundation
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
    }
}
