import AppKit
import XCTest
@testable import Perch

/// The Info.plist and the provider are joined by a *string*. Rename either
/// side and nothing fails to compile — the Finder menu item simply stops
/// working, silently, in a signed build nobody rebuilds to check. These tests
/// are that missing compile error.
@MainActor
final class ShelfServicesProviderTests: XCTestCase {
    private func serviceEntry() throws -> [String: Any] {
        let services = try XCTUnwrap(
            Bundle(for: ShelfServicesProvider.self).infoDictionary?["NSServices"] as? [[String: Any]],
            "The host bundle declares no NSServices — Perch/Config/Info.plist is not reaching the app."
        )
        return try XCTUnwrap(services.first)
    }

    func testDeclaredMessageMatchesAnImplementedSelector() throws {
        let message = try XCTUnwrap(serviceEntry()["NSMessage"] as? String)
        // The Services machinery appends the two remaining arguments itself.
        let selector = Selector("\(message):userData:error:")
        XCTAssertTrue(
            ShelfServicesProvider.instancesRespond(to: selector),
            "NSMessage \"\(message)\" has no matching \(message):userData:error: on ShelfServicesProvider."
        )
    }

    func testTheMenuItemStillAdvertisesFilesAndText() throws {
        let entry = try serviceEntry()
        let title = try XCTUnwrap((entry["NSMenuItem"] as? [String: Any])?["default"] as? String)
        XCTAssertFalse(title.isEmpty)

        let sendTypes = Set(try XCTUnwrap(entry["NSSendTypes"] as? [String]))
        // Files are the point; text and URLs are the deliberate extra reach
        // into other apps' Services menus, and dropping one silently narrows
        // the feature rather than breaking it.
        XCTAssertTrue(sendTypes.contains("public.file-url"))
        XCTAssertTrue(sendTypes.contains("NSFilenamesPboardType"))
        XCTAssertTrue(sendTypes.contains("public.plain-text"))
    }

    /// The whole design claim of this door: it is the drag path, reached from
    /// a menu. A staged copy appearing while the source is untouched is what
    /// proves the Service didn't grow a staging path of its own.
    func testAFileFromTheServiceIsStagedLikeADrop() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "PerchServices-\(UUID().uuidString)", directoryHint: .isDirectory)
        let source = FileManager.default.temporaryDirectory
            .appending(path: "service-source-\(UUID().uuidString).txt")
        let suiteName = "PerchServicesSettings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: source)
            defaults.removePersistentDomain(forName: suiteName)
        }
        try "sent from Finder".write(to: source, atomically: true, encoding: .utf8)

        let store = ShelfStore(
            repository: try StagingRepository(rootURL: root),
            settings: AppSettings(defaults: defaults)
        )
        let provider = ShelfServicesProvider(store: store)
        let pasteboard = NSPasteboard(name: .init("PerchServicesTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([source as NSURL])

        XCTAssertNil(provider.handle(pasteboard))
        try await waitUntil { !store.items.isEmpty && store.pendingTransfers.isEmpty }

        let staged = try XCTUnwrap(store.items.first?.fileURL(inside: store.repository.rootURL))
        XCTAssertNotEqual(staged, source, "The shelf must hold a copy, never the original.")
        XCTAssertEqual(try String(contentsOf: staged, encoding: .utf8), "sent from Finder")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: source.path),
            "The source file must still be exactly where Finder left it."
        )
    }

    func testAPasteboardWithNothingReadableIsRefused() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "PerchServices-\(UUID().uuidString)", directoryHint: .isDirectory)
        let suiteName = "PerchServicesSettings-\(UUID().uuidString)"
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
        let provider = ShelfServicesProvider(store: store)
        let pasteboard = NSPasteboard(name: .init("PerchServicesTests-\(UUID().uuidString)"))
        pasteboard.clearContents()

        XCTAssertNotNil(
            provider.handle(pasteboard),
            "An unreadable pasteboard must report why, not fail mutely."
        )
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(store.pendingTransfers.isEmpty)
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
