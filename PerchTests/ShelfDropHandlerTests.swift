import AppKit
import XCTest
@testable import Perch

@MainActor
final class ShelfDropHandlerTests: XCTestCase {
    func testFileURLPasteboardStagesARealCopy() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "PerchDrop-\(UUID().uuidString)", directoryHint: .isDirectory)
        let source = FileManager.default.temporaryDirectory
            .appending(path: "drop-source-\(UUID().uuidString).txt")
        let suiteName = "PerchDropSettings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: source)
            defaults.removePersistentDomain(forName: suiteName)
        }
        try "dropped".write(to: source, atomically: true, encoding: .utf8)

        let repository = try StagingRepository(rootURL: root)
        let settings = AppSettings(defaults: defaults)
        let store = ShelfStore(repository: repository, settings: settings)
        let handler = ShelfDropHandler(store: store)
        let pasteboard = NSPasteboard(name: .init("PerchTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([source as NSURL])

        XCTAssertTrue(handler.accept(pasteboard))
        try await waitUntil { !store.items.isEmpty && store.pendingTransfers.isEmpty }

        let item = try XCTUnwrap(store.items.first)
        let staged = try XCTUnwrap(item.fileURL(inside: root))
        XCTAssertNotEqual(staged, source)
        XCTAssertEqual(try String(contentsOf: staged, encoding: .utf8), "dropped")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testTextPasteboardBecomesStagedTextFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "PerchText-\(UUID().uuidString)", directoryHint: .isDirectory)
        let suiteName = "PerchTextSettings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let repository = try StagingRepository(rootURL: root)
        let store = ShelfStore(
            repository: repository,
            settings: AppSettings(defaults: defaults)
        )
        let handler = ShelfDropHandler(store: store)
        let pasteboard = NSPasteboard(name: .init("PerchTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("a temporary thought", forType: .string)

        XCTAssertTrue(handler.accept(pasteboard))
        try await waitUntil { !store.items.isEmpty && store.pendingTransfers.isEmpty }

        XCTAssertEqual(store.items.first?.kind, .text)
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for the asynchronous import")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
