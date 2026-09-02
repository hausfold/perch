import Foundation
import XCTest
@testable import Perch

/// The `perch` tool is the App Group mailbox's one sender, so these drive
/// `HandoffClient` against a real `FinderActionReceiver` — the whole handoff,
/// end to end, minus the two process boundaries.
@MainActor
final class HandoffClientTests: XCTestCase {
    private struct Fixture {
        let shelfRoot: URL
        let sourceRoot: URL
        let store: ShelfStore
        let receiver: FinderActionReceiver
        let client: HandoffClient
    }

    private func makeFixture() throws -> Fixture {
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

        let store = ShelfStore(
            repository: try StagingRepository(rootURL: shelfRoot),
            settings: AppSettings(store: TransientSettings.store(), defaults: defaults)
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

    /// The whole `add` loop, run for its side effect: one file on the shelf,
    /// through the same four steps the tool takes. What the read verbs are then
    /// asked about.
    @discardableResult
    private func shelve(
        _ name: String,
        contents: String,
        in fixture: Fixture
    ) async throws -> ShelfItem {
        let source = try makeSource(name, contents: contents, in: fixture)
        let request = try fixture.client.openRequest(displayNames: [name])
        await fixture.receiver.scanOnce()
        let response = try XCTUnwrap(
            fixture.client.waitForAnswer(request.id, deadline: Date().addingTimeInterval(1))
        )
        let item = try XCTUnwrap(
            fixture.client.acceptedItems(in: request, response: response).first
        )
        let staged = try fixture.client.stage(
            sourceURL: source,
            item: item,
            requestID: request.id
        )
        try fixture.client.finish(
            FinderActionCompletion(stagedItems: [staged], failedItemIDs: []),
            for: request.id
        )
        await fixture.receiver.scanOnce()
        return try XCTUnwrap(fixture.store.items.first { $0.id == item.id })
    }

    private func answerURL(for requestID: UUID, in fixture: Fixture) -> URL {
        fixture.client.mailbox.rootURL
            .appending(path: requestID.uuidString, directoryHint: .isDirectory)
            .appending(path: FinderActionProtocol.responseFilename)
    }

    /// The whole loop the `perch` tool runs: ask by name, wait for the receipt,
    /// copy only what was admitted, publish, and let the app adopt it.
    func testCommandLineHandoffBecomesAShelfItem() async throws {
        let fixture = try makeFixture()
        let source = try makeSource("notes.txt", contents: "from the CLI", in: fixture)

        let request = try fixture.client.openRequest(displayNames: ["notes.txt"])
        await fixture.receiver.scanOnce()

        let response = try XCTUnwrap(
            fixture.client.waitForAnswer(request.id, deadline: Date().addingTimeInterval(1))
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

    /// The running app admits everything it is offered: the handshake exists so
    /// the tool never copies bytes perch isn't there to adopt, and there is no
    /// ceiling left for it to trim a batch against.
    func testEveryOfferedItemIsAdmitted() async throws {
        let fixture = try makeFixture()
        let sources = try (0..<3).map {
            try makeSource("item\($0).txt", contents: "item \($0)", in: fixture)
        }

        let request = try fixture.client.openRequest(
            displayNames: sources.map(\.lastPathComponent)
        )
        await fixture.receiver.scanOnce()
        let response = try XCTUnwrap(
            fixture.client.waitForAnswer(request.id, deadline: Date().addingTimeInterval(1))
        )
        let accepted = fixture.client.acceptedItems(in: request, response: response)
        XCTAssertEqual(accepted.map(\.displayName), ["item0.txt", "item1.txt", "item2.txt"])
        XCTAssertEqual(fixture.store.pendingTransfers.count, 3)
    }

    /// No original path may reach the shared container — not in the request, not
    /// in the completion. The names are all Perch ever learns.
    func testNoOriginalPathIsWrittenIntoTheContainer() async throws {
        let fixture = try makeFixture()
        let source = try makeSource("secret.txt", contents: "shh", in: fixture)

        let request = try fixture.client.openRequest(displayNames: ["secret.txt"])
        await fixture.receiver.scanOnce()
        let response = try XCTUnwrap(
            fixture.client.waitForAnswer(request.id, deadline: Date().addingTimeInterval(1))
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


    // MARK: - The read verbs

    /// `perch list`: the shelf the panel is showing, in the panel's order, with
    /// the pin a person at a terminal can act on. It reserves nothing and
    /// changes nothing.
    func testListAnswersWithTheShelfTheAppIsShowing() async throws {
        let fixture = try makeFixture()
        let first = try await shelve("notes.txt", contents: "one", in: fixture)
        let second = try await shelve("shot.png", contents: "two", in: fixture)
        fixture.store.setPinned(true, for: second)

        let request = try fixture.client.openRequest(kind: .list)
        await fixture.receiver.scanOnce()
        let response = try XCTUnwrap(
            fixture.client.waitForAnswer(request.id, deadline: Date().addingTimeInterval(1))
        )
        let entries = try XCTUnwrap(response.entries)

        XCTAssertEqual(entries.map(\.id), [first.id, second.id])
        XCTAssertEqual(entries.map(\.displayName), ["notes.txt", "shot.png"])
        XCTAssertEqual(entries.map(\.isPinned), [false, true])
        XCTAssertEqual(entries.map(\.byteCount), fixture.store.items.map(\.byteCount))
        XCTAssertTrue(response.acceptedItemIDs.isEmpty, "a list reserves no slots")
        XCTAssertEqual(fixture.store.items.count, 2, "reading the shelf does not change it")

        // The sender closes its own transaction: an app that dropped the
        // directory the moment it answered would race the reader of that answer.
        await fixture.receiver.scanOnce()
        XCTAssertFalse(try fixture.client.mailbox.snapshots().isEmpty)
        fixture.client.acknowledge(request.id)
        await fixture.receiver.scanOnce()
        XCTAssertTrue(try fixture.client.mailbox.snapshots().isEmpty)
    }

    /// The answer names items and says nothing about where anything lives — not
    /// the original, and not the staged copy either.
    func testAListedShelfCarriesNamesAndNoPaths() async throws {
        let fixture = try makeFixture()
        try await shelve("secret.txt", contents: "shh", in: fixture)

        let request = try fixture.client.openRequest(kind: .list)
        await fixture.receiver.scanOnce()

        let json = String(
            decoding: try Data(contentsOf: answerURL(for: request.id, in: fixture)),
            as: UTF8.self
        )
        XCTAssertTrue(json.contains("secret.txt"))
        XCTAssertFalse(json.contains(fixture.sourceRoot.path))
        XCTAssertFalse(json.contains(fixture.shelfRoot.path))
        XCTAssertFalse(json.contains("file://"))
    }

    /// `perch rm`: the same removal the shelf's own menu performs — the item
    /// goes, and the bytes Perch staged for it go with it. The original was
    /// never Perch's to touch.
    func testRemoveTakesTheItemAndTheBytesPerchStaged() async throws {
        let fixture = try makeFixture()
        let source = try makeSource("original.txt", contents: "bye", in: fixture)
        let item = try await shelve("stale.txt", contents: "bye", in: fixture)
        let stagedURL = try XCTUnwrap(fixture.store.stagedURL(for: item))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))

        let request = try fixture.client.openRequest(kind: .remove, targetItemIDs: [item.id])
        await fixture.receiver.scanOnce()
        let response = try XCTUnwrap(
            fixture.client.waitForAnswer(request.id, deadline: Date().addingTimeInterval(1))
        )

        XCTAssertEqual(try XCTUnwrap(response.entries).map(\.id), [item.id])
        XCTAssertEqual(try XCTUnwrap(response.entries).map(\.displayName), ["stale.txt"])
        XCTAssertTrue(fixture.store.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))

        fixture.client.acknowledge(request.id)
        await fixture.receiver.scanOnce()
        XCTAssertTrue(try fixture.client.mailbox.snapshots().isEmpty)
    }

    /// An id the shelf no longer has is simply absent from the answer — that is
    /// how the tool reports it and still exits having removed the rest. And the
    /// answer is written once: a rescan before the sender acknowledges must not
    /// recompute it into "nothing was removed".
    func testRemoveAnswersWithWhatItTookAndOnlyOnce() async throws {
        let fixture = try makeFixture()
        let kept = try await shelve("keep.txt", contents: "keep", in: fixture)
        let gone = try await shelve("gone.txt", contents: "gone", in: fixture)

        let request = try fixture.client.openRequest(
            kind: .remove,
            targetItemIDs: [gone.id, UUID()]
        )
        await fixture.receiver.scanOnce()
        let response = try XCTUnwrap(
            fixture.client.waitForAnswer(request.id, deadline: Date().addingTimeInterval(1))
        )
        XCTAssertEqual(try XCTUnwrap(response.entries).map(\.id), [gone.id])
        XCTAssertEqual(fixture.store.items.map(\.id), [kept.id])

        let answered = try Data(contentsOf: answerURL(for: request.id, in: fixture))
        await fixture.receiver.scanOnce()
        XCTAssertEqual(
            try Data(contentsOf: answerURL(for: request.id, in: fixture)),
            answered,
            "the response on disk is what makes a read verb idempotent across scans"
        )
        XCTAssertEqual(fixture.store.items.map(\.id), [kept.id])
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
