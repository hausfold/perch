import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Perch

@MainActor
final class ExportPromiseProviderTests: XCTestCase {
    /// Receivers that never learned to consume file promises (terminals, most
    /// editors) only accept a drag that carries `public.file-url`. Without it
    /// the drag is invisible to them — no drop cursor, no drop.
    func testExportAdvertisesBothThePromiseAndTheStagedFileURL() throws {
        let staged = FileManager.default.temporaryDirectory
            .appending(path: "perch-export-\(UUID().uuidString).txt")
        try "staged".write(to: staged, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: staged) }

        let source = DragSourceNSView()
        let provider = ExportPromiseProvider(
            fileType: UTType.plainText.identifier,
            delegate: source
        )
        provider.userInfo = ExportItem(
            id: UUID(),
            url: staged,
            fileType: UTType.plainText.identifier,
            fileName: staged.lastPathComponent
        )

        let pasteboard = NSPasteboard(name: .init("PerchExportTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([provider])

        let types = try XCTUnwrap(pasteboard.types)
        XCTAssertTrue(types.contains(.fileURL), "terminals and editors read the file URL")
        XCTAssertTrue(
            types.contains { $0.rawValue.contains("promised-file") },
            "promise-aware receivers still get the promise"
        )
        // Promise types come first so a receiver that understands both prefers
        // the promise, which is what confirms the destination copy.
        let written = provider.writableTypes(for: pasteboard)
        XCTAssertEqual(written.last, .fileURL)

        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        XCTAssertEqual(urls?.first?.standardizedFileURL, staged.standardizedFileURL)
    }
}
