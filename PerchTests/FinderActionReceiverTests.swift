import Foundation
import XCTest
@testable import Perch

@MainActor
final class FinderActionReceiverTests: XCTestCase {
    private struct Fixture {
        let shelfRoot: URL
        let mailboxRoot: URL
        let defaultsName: String
        let repository: StagingRepository
        let store: ShelfStore
        let mailbox: FinderActionMailbox
        let receiver: FinderActionReceiver
    }

    private func makeFixture() throws -> Fixture {
        let token = UUID().uuidString
        let shelfRoot = FileManager.default.temporaryDirectory
            .appending(path: "PerchFinderShelf-\(token)", directoryHint: .isDirectory)
        let mailboxRoot = FileManager.default.temporaryDirectory
            .appending(path: "PerchFinderMailbox-\(token)", directoryHint: .isDirectory)
        let defaultsName = "PerchFinderSettings-\(token)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))

        let repository = try StagingRepository(rootURL: shelfRoot)
        let store = ShelfStore(
            repository: repository,
            settings: AppSettings(store: TransientSettings.store(), defaults: defaults)
        )
        let mailbox = try FinderActionMailbox(rootURL: mailboxRoot)
        let receiver = FinderActionReceiver(store: store, mailbox: mailbox)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: shelfRoot)
            try? FileManager.default.removeItem(at: mailboxRoot)
            UserDefaults().removePersistentDomain(forName: defaultsName)
        }
        return Fixture(
            shelfRoot: shelfRoot,
            mailboxRoot: mailboxRoot,
            defaultsName: defaultsName,
            repository: repository,
            store: store,
            mailbox: mailbox,
            receiver: receiver
        )
    }

    func testAdmissionIsPersistedBeforeAnyFinderBytesAreRequested() async throws {
        let fixture = try makeFixture()
        let request = FinderActionRequest(
            id: UUID(),
            createdAt: Date(),
            items: (0..<3).map {
                FinderActionItem(id: UUID(), displayName: "Item \($0).txt", attachmentIndex: $0)
            }
        )
        try fixture.mailbox.createRequest(request)

        await fixture.receiver.scanOnce()

        let response = try XCTUnwrap(fixture.mailbox.readResponse(for: request.id))
        XCTAssertEqual(response.acceptedItemIDs, request.items.map(\.id))
        XCTAssertEqual(fixture.store.pendingTransfers.map(\.id), response.acceptedItemIDs)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.mailboxRoot
                    .appending(path: request.id.uuidString)
                    .appending(path: FinderActionProtocol.stagedDirectoryName)
                    .path
            ),
            "the app only grants admission; Finder has not been asked for bytes yet"
        )

        let persistedRequest = try Data(
            contentsOf: fixture.mailboxRoot
                .appending(path: request.id.uuidString)
                .appending(path: FinderActionProtocol.requestFilename)
        )
        let json = String(decoding: persistedRequest, as: UTF8.self)
        XCTAssertFalse(json.contains("file://"))
        XCTAssertFalse(json.contains("/Users/"))
    }

    func testCompletedMailboxCopyBecomesAVisibleShelfItem() async throws {
        let fixture = try makeFixture()
        let offered = FinderActionItem(id: UUID(), displayName: "report.txt", attachmentIndex: 0)
        let request = FinderActionRequest(id: UUID(), createdAt: Date(), items: [offered])
        try fixture.mailbox.createRequest(request)
        await fixture.receiver.scanOnce()

        let stagedDirectory = try fixture.mailbox.stagedDirectory(
            for: request.id,
            itemID: offered.id
        )
        let stagedURL = stagedDirectory.appending(path: offered.displayName)
        try Data("from Finder".utf8).write(to: stagedURL, options: [.atomic])
        let relativePath = try fixture.mailbox.relativePath(
            for: stagedURL,
            requestID: request.id
        )
        try fixture.mailbox.writeCompletion(
            FinderActionCompletion(
                stagedItems: [FinderActionStagedItem(id: offered.id, relativePath: relativePath)],
                failedItemIDs: []
            ),
            for: request.id
        )

        await fixture.receiver.scanOnce()

        XCTAssertTrue(fixture.store.pendingTransfers.isEmpty)
        XCTAssertEqual(fixture.store.items.map(\.id), [offered.id])
        let shelfURL = try XCTUnwrap(fixture.store.items.first?.fileURL(inside: fixture.shelfRoot))
        XCTAssertEqual(try Data(contentsOf: shelfURL), Data("from Finder".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
        XCTAssertTrue(try fixture.mailbox.snapshots().isEmpty)
    }

    func testPersistedAdmissionResumesAfterTheAppRelaunches() async throws {
        let fixture = try makeFixture()
        let offered = FinderActionItem(id: UUID(), displayName: "resume.txt", attachmentIndex: 0)
        let request = FinderActionRequest(id: UUID(), createdAt: Date(), items: [offered])
        try fixture.mailbox.createRequest(request)
        try fixture.mailbox.writeResponse(
            FinderActionResponse(acceptedItemIDs: [offered.id]),
            for: request.id
        )

        let relaunched = FinderActionReceiver(store: fixture.store, mailbox: fixture.mailbox)
        await relaunched.scanOnce()

        XCTAssertEqual(fixture.store.pendingTransfers.map(\.id), [offered.id])
        XCTAssertEqual(fixture.store.pendingTransfers.first?.displayName, offered.displayName)
    }

    func testStaleTransactionReleasesItsPersistedReservation() async throws {
        let fixture = try makeFixture()
        let offered = FinderActionItem(id: UUID(), displayName: "stale.txt", attachmentIndex: 0)
        let createdAt = Date(timeIntervalSinceNow: -FinderActionProtocol.abandonedAfter - 1)
        let request = FinderActionRequest(id: UUID(), createdAt: createdAt, items: [offered])
        try fixture.mailbox.createRequest(request)
        try fixture.mailbox.writeResponse(
            FinderActionResponse(acceptedItemIDs: [offered.id]),
            for: request.id
        )
        fixture.store.resumeFinderItems([offered])

        await fixture.receiver.scanOnce()

        XCTAssertTrue(fixture.store.pendingTransfers.isEmpty)
        XCTAssertTrue(try fixture.mailbox.snapshots().isEmpty)
    }

    // MARK: - Verbs this build didn't write

    /// Hand-written request JSON, the way a sender that isn't this build writes
    /// it. The only way to test what happens to a field we would never encode.
    private func writeRawRequest(_ fields: [String: Any], in fixture: Fixture) throws -> UUID {
        let id = UUID()
        var payload = fields
        payload["id"] = id.uuidString
        payload["createdAt"] = Date().timeIntervalSince1970 * 1000
        let directory = fixture.mailboxRoot
            .appending(path: id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: payload).write(
            to: directory.appending(path: FinderActionProtocol.requestFilename),
            options: [.atomic]
        )
        return id
    }

    /// A request from a `perch` tool older than the read verbs names no verb at
    /// all. The mailbox had exactly one, so that request is an add and still
    /// lands — an installed tool writes to this directory, and it need not be
    /// the one this app shipped with.
    func testARequestWithoutAKindIsStillAnAdd() async throws {
        let fixture = try makeFixture()
        let itemID = UUID()
        let requestID = try writeRawRequest(
            [
                "items": [
                    ["id": itemID.uuidString, "displayName": "legacy.txt", "attachmentIndex": 0],
                ],
            ],
            in: fixture
        )

        await fixture.receiver.scanOnce()

        let response = try XCTUnwrap(fixture.mailbox.readResponse(for: requestID))
        XCTAssertEqual(response.acceptedItemIDs, [itemID])
        XCTAssertNil(response.entries)
        XCTAssertEqual(fixture.store.pendingTransfers.map(\.displayName), ["legacy.txt"])
    }

    /// The other direction: a verb from a *newer* sender. It is answered with
    /// no entries — which is how that sender learns this shelf can't serve it —
    /// rather than throwing, because one unparseable request would otherwise
    /// stall every transaction sitting behind it in the directory.
    func testAnUnknownVerbIsAnsweredAndLetsTheQueueThrough() async throws {
        let fixture = try makeFixture()
        let strangerID = try writeRawRequest(["kind": "purge", "items": []], in: fixture)
        let offered = FinderActionItem(id: UUID(), displayName: "after.txt", attachmentIndex: 0)
        try fixture.mailbox.createRequest(
            FinderActionRequest(id: UUID(), createdAt: Date(), items: [offered])
        )

        await fixture.receiver.scanOnce()

        let answer = try XCTUnwrap(fixture.mailbox.readResponse(for: strangerID))
        XCTAssertNil(answer.entries, "no entries is how a sender learns the verb is unknown here")
        XCTAssertTrue(answer.acceptedItemIDs.isEmpty)
        XCTAssertEqual(
            fixture.store.pendingTransfers.map(\.displayName),
            ["after.txt"],
            "the request behind it was served in the same pass"
        )
    }

    /// An empty shelf answers with an empty list, never with the absence that
    /// means "this build doesn't know the verb". The tool branches on exactly
    /// that difference.
    func testAnEmptyShelfListsAsEmptyRatherThanUnknown() async throws {
        let fixture = try makeFixture()
        let request = FinderActionRequest(id: UUID(), createdAt: Date(), items: [], kind: .list)
        try fixture.mailbox.createRequest(request)

        await fixture.receiver.scanOnce()

        let response = try XCTUnwrap(fixture.mailbox.readResponse(for: request.id))
        XCTAssertEqual(response.entries, [])
    }

    func testMailboxRejectsPathsOutsideItsRequestDirectory() throws {
        let fixture = try makeFixture()
        XCTAssertThrowsError(
            try fixture.mailbox.stagedURL(
                relativePath: "../../private.txt",
                requestID: UUID()
            )
        ) { error in
            XCTAssertEqual(error as? FinderActionMailboxError, .unsafeRelativePath)
        }
    }
}
