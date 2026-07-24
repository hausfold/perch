import Foundation
import XCTest
@testable import Morsel

final class TransferPipelineTests: XCTestCase {
    func testStagesFileAsPrivateCopy() async throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appending(path: "MorselPipeline-\(UUID().uuidString)", directoryHint: .isDirectory)
        let sourceRoot = FileManager.default.temporaryDirectory
            .appending(path: "MorselSource-\(UUID().uuidString)", directoryHint: .isDirectory)
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
}
