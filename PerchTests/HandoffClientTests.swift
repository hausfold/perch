import Foundation
import XCTest
@testable import Perch

/// The `perch` tool is a client of the same App Group mailbox the Finder Action
/// uses, so these drive `HandoffClient` against a real `FinderActionReceiver` —
/// the whole handoff, end to end, minus the two process boundaries.
@MainActor
final class HandoffClientTests: XCTestCase {
    private struct Fixture {
        let shelfRoot: URL
        let sourceRoot: URL
        let store: ShelfStore
        let receiver: FinderActionReceiver
        let client: HandoffClient
    }

    private func makeFixture(forceFree: Bool = false) throws -> Fixture {
        let token = UUID().uuidString
        let temporary = FileManager.default.temporaryDirectory
        let shelfRoot = temporary
            .appending(path: "PerchHandoffShelf-\(token)", directoryHint: .isDirectory)
        let mailboxRoot = temporary
            .appending(path: "PerchHandoffMailbox-\(token)", directoryHint: .isDirectory)
        let sourceRoot = temporary
            .appending(path: "PerchHandoffSource-\(token)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let defaultsName = "PerchHandoffSettings-\(token)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defaults.set(forceFree, forKey: "licenseDebugForceFree")

        let store = ShelfStore(
            repository: try StagingRepository(rootURL: shelfRoot),
            settings: AppSettings(defaults: defaults),
            license: LicenseStore(
                defaults: defaults,
                verifier: LicenseVerifier(publicKey: Data([0x01]))
            )
        )
        let mailbox = try FinderActionMailbox(rootURL: mailboxRoot)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: shelfRoot)
            try? FileManager.default.removeItem(at: mailboxRoot)
            try? FileManager.default.removeItem(at: sourceRoot)
            UserDefaults().removePersistentDomain(forName: defaultsName)
        }
        return Fixture(
            shelfRoot: shelfRoot,
            sourceRoot: sourceRoot,
            store: store,
            receiver: FinderActionReceiver(store: store, mailbox: mailbox),
            client: HandoffClient(mailbox: mailbox)
        )
    }

    private func makeSource(
        _ name: String,
        contents: String,
        in fixture: Fixture
    ) throws -> URL {
        let url = fixture.sourceRoot.appending(path: name)
        try Data(contents.utf8).write(to: url, options: [.atomic])
        return url
    }

    /// The whole loop the `perch` tool runs: ask by name, wait for the receipt,
    /// copy only what was admitted, publish, and let the app adopt it.
    func testCommandLineHandoffBecomesAShelfItem() async throws {
        let fixture = try makeFixture()
        let source = try makeSource("notes.txt", contents: "from the CLI", in: fixture)

        let request = try fixture.client.openRequest(displayNames: ["notes.txt"])
        await fixture.receiver.scanOnce()

        let response = try XCTUnwrap(
            fixture.client.waitForAdmission(request.id, deadline: Date().addingTimeInterval(1))
        )
        let accepted = fixture.client.acceptedItems(in: request, response: response)
        XCTAssertEqual(accepted.count, 1)
        let staged = try fixture.client.stage(
            sourceURL: source,
            item: try XCTUnwrap(accepted.first),
            requestID: request.id
        )
        try fixture.client.finish(
            FinderActionCompletion(stagedItems: [staged], failedItemIDs: []),
            for: request.id
        )

        await fixture.receiver.scanOnce()

        XCTAssertTrue(fixture.store.pendingTransfers.isEmpty)
        XCTAssertEqual(fixture.store.items.map(\.displayName), ["notes.txt"])
        let shelfURL = try XCTUnwrap(
            fixture.store.items.first?.fileURL(inside: fixture.shelfRoot)
        )
        XCTAssertEqual(try Data(contentsOf: shelfURL), Data("from the CLI".utf8))
        XCTAssertEqual(
            try Data(contentsOf: source),
            Data("from the CLI".utf8),
            "the tool only ever reads the original"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    /// The cap is answered in the admission receipt, before the tool has copied
    /// a single byte — which is what lets `perch add` exit 2 without ever
    /// touching the files it was refused.
    func testRefusedItemsAreNeverCopied() async throws {
        let fixture = try makeFixture(forceFree: true)
        let sources = try (0..<3).map {
            try makeSource("item\($0).txt", contents: "item \($0)", in: fixture)
        }

        let request = try fixture.client.openRequest(
            displayNames: sources.map(\.lastPathComponent)
        )
        await fixture.receiver.scanOnce()
        let response = try XCTUnwrap(
            fixture.client.waitForAdmission(request.id, deadline: Date().addingTimeInterval(1))
        )
        let accepted = fixture.client.acceptedItems(in: request, response: response)
        XCTAssertEqual(accepted.map(\.displayName), ["item0.txt", "item1.txt"])

        for item in accepted {
            _ = try fixture.client.stage(
                sourceURL: sources[item.attachmentIndex],
                item: item,
                requestID: request.id
            )
        }
        let refused = request.items.filter { item in
            !accepted.contains(where: { $0.id == item.id })
        }
        for item in refused {
            XCTAssertNil(
                try? fixture.client.mailbox.stagedURL(
                    relativePath: "\(FinderActionProtocol.stagedDirectoryName)/"
                        + "\(item.id.uuidString)/\(item.displayName)",
                    requestID: request.id
                ).checkResourceIsReachable(),
                "a refused item is never copied into the container"
            )
        }
    }

    /// No original path may reach the shared container — not in the request, not
    /// in the completion. The names are all Perch ever learns.
    func testNoOriginalPathIsWrittenIntoTheContainer() async throws {
        let fixture = try makeFixture()
        let source = try makeSource("secret.txt", contents: "shh", in: fixture)

        let request = try fixture.client.openRequest(displayNames: ["secret.txt"])
        await fixture.receiver.scanOnce()
        let response = try XCTUnwrap(
            fixture.client.waitForAdmission(request.id, deadline: Date().addingTimeInterval(1))
        )
        let staged = try fixture.client.stage(
            sourceURL: source,
            item: try XCTUnwrap(fixture.client.acceptedItems(in: request, response: response).first),
            requestID: request.id
        )
        try fixture.client.finish(
            FinderActionCompletion(stagedItems: [staged], failedItemIDs: []),
            for: request.id
        )

        let written = try FileManager.default.subpathsOfDirectory(
            atPath: fixture.client.mailbox.rootURL.path
        )
        .filter { $0.hasSuffix(".json") }
        .map { fixture.client.mailbox.rootURL.appending(path: $0) }
        XCTAssertFalse(written.isEmpty)
        for url in written {
            let json = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            XCTAssertFalse(json.contains(fixture.sourceRoot.path))
            XCTAssertFalse(json.contains("file://"))
        }
    }

    /// A tool that gives up must not leave the shelf holding a slot it will
    /// never fill: the empty completion is what releases the reservation.
    func testAbandonedRequestReleasesTheReservation() async throws {
        let fixture = try makeFixture()
        let request = try fixture.client.openRequest(displayNames: ["gone.txt"])
        await fixture.receiver.scanOnce()
        XCTAssertEqual(fixture.store.pendingTransfers.count, 1)

        fixture.client.abandon(request.id)
        await fixture.receiver.scanOnce()

        XCTAssertTrue(fixture.store.pendingTransfers.isEmpty)
        XCTAssertTrue(fixture.store.items.isEmpty)
        XCTAssertTrue(try fixture.client.mailbox.snapshots().isEmpty)
    }

    /// The unsandboxed lookup the tool uses answers with the group container's
    /// documented path, and refuses rather than creating one Perch has not made.
    func testUnsandboxedLookupRefusesToCreateTheContainer() throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "PerchHandoffHome-\(UUID().uuidString)", directoryHint: .isDirectory)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }

        XCTAssertEqual(
            HandoffClient.groupContainerURL(home: home).path,
            home.appending(path: "Library/Group Containers")
                .appending(path: FinderActionProtocol.appGroupIdentifier).path
        )
        XCTAssertThrowsError(try HandoffClient.unsandboxed(home: home)) { error in
            XCTAssertEqual(error as? FinderActionMailboxError, .appGroupUnavailable)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: HandoffClient.groupContainerURL(home: home).path)
        )
    }
}
