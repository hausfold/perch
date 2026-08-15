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
            settings: AppSettings(defaults: defaults)
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
