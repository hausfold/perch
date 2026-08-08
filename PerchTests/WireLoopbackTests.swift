import CryptoKit
import Foundation
import Network
import XCTest

@testable import Perch

/// The whole wire, no UI: a real listener on a real localhost port, a real
/// client, pairing followed by delivery, bytes verified on the far side.
final class WireLoopbackTests: XCTestCase {
    private var spoolDirectory: URL!
    private var shelfDirectory: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "WireLoopback-\(UUID().uuidString)")
        spoolDirectory = base.appending(path: "spool")
        shelfDirectory = base.appending(path: "shelf")
        try FileManager.default.createDirectory(at: spoolDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shelfDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(
            at: spoolDirectory.deletingLastPathComponent()
        )
    }

    func testPairThenDeliverTwoItems() async throws {
        let identity = MacIdentity(id: UUID(), name: "Loopback Mac")
        let delegate = LoopbackDelegate(
            identity: identity,
            spool: spoolDirectory,
            shelf: shelfDirectory,
            pairingSecret: nil
        )
        let server = WireServer(delegate: delegate)
        try server.start(identity: identity)
        defer { server.stop() }
        let port = try XCTUnwrap(waitForPort(server))

        // --- Pair ---
        let offer = PairingOffer(
            macID: identity.id,
            macName: identity.name,
            secret: WireCrypto.randomSecret()
        )
        delegate.setPairingSecret(offer.secret)
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        let deviceID = UUID()
        let mac = try await WirePairingClient.pair(
            offer: offer,
            endpoint: endpoint,
            deviceID: deviceID,
            deviceName: "Test iPhone"
        ) { code in
            // Both sides derive the code from the same transcript; the
            // delegate recorded the Mac's.
            XCTAssertEqual(code.count, 6)
            return true
        }
        XCTAssertEqual(mac.id, identity.id)
        XCTAssertEqual(delegate.storedPeer?.id, deviceID)
        XCTAssertEqual(delegate.storedPeer?.deviceKey, mac.deviceKey)

        // --- Deliver ---
        let smallURL = spoolDirectory.appending(path: "hello.txt")
        try Data("hello from the phone".utf8).write(to: smallURL)
        var big = Data(capacity: 3 << 20)
        for index in 0..<(3 << 20) {
            big.append(UInt8(truncatingIfNeeded: index &* 31))
        }
        let bigURL = spoolDirectory.appending(path: "big.bin")
        try big.write(to: bigURL)

        let outgoing = [
            try outgoingItem(for: smallURL, kind: "text"),
            try outgoingItem(for: bigURL, kind: "file"),
        ]
        let events = EventLog()
        try await WireTransferClient.deliver(
            outgoing,
            to: endpoint,
            deviceID: deviceID,
            deviceKey: mac.deviceKey
        ) { event in
            events.append(event)
        }

        let storedIDs = events.stored
        XCTAssertEqual(Set(storedIDs), Set(outgoing.map(\.offered.id)))
        for item in outgoing {
            let landed = shelfDirectory.appending(path: item.offered.displayName)
            let data = try Data(contentsOf: landed)
            XCTAssertEqual(Data(SHA256.hash(data: data)), item.offered.sha256)
        }
    }

    /// The reverse direction end to end: the phone lists the Mac's shelf,
    /// pulls one item down byte-for-byte, and prunes another off it.
    func testPhoneListsFetchesAndRemovesFromTheMacShelf() async throws {
        let identity = MacIdentity(id: UUID(), name: "Loopback Mac")
        let delegate = LoopbackDelegate(
            identity: identity,
            spool: spoolDirectory,
            shelf: shelfDirectory,
            pairingSecret: nil
        )
        let server = WireServer(delegate: delegate)
        try server.start(identity: identity)
        defer { server.stop() }
        let port = try XCTUnwrap(waitForPort(server))
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)

        let offer = PairingOffer(
            macID: identity.id,
            macName: identity.name,
            secret: WireCrypto.randomSecret()
        )
        delegate.setPairingSecret(offer.secret)
        let deviceID = UUID()
        let mac = try await WirePairingClient.pair(
            offer: offer,
            endpoint: endpoint,
            deviceID: deviceID,
            deviceName: "Test iPhone"
        ) { _ in true }

        // Two things on the Mac's shelf, one of them big enough to span many
        // chunk frames.
        let noteURL = shelfDirectory.appending(path: "note.txt")
        try Data("dragged onto the notch".utf8).write(to: noteURL)
        var big = Data(capacity: 2 << 20)
        for index in 0..<(2 << 20) {
            big.append(UInt8(truncatingIfNeeded: index &* 17))
        }
        let bigURL = shelfDirectory.appending(path: "reverse.bin")
        try big.write(to: bigURL)
        let noteID = UUID()
        let bigID = UUID()
        delegate.place(noteURL, id: noteID)
        delegate.place(bigURL, id: bigID)

        let client = try await WireRemoteClient.connect(
            to: endpoint,
            deviceID: deviceID,
            deviceKey: mac.deviceKey
        )

        let listed = try await client.list()
        XCTAssertEqual(Set(listed.map(\.id)), [noteID, bigID])
        XCTAssertEqual(listed.first(where: { $0.id == bigID })?.byteCount, Int64(big.count))

        let inbox = spoolDirectory.appending(path: "inbox")
        let fetched = try await client.fetch(bigID, into: inbox)
        XCTAssertEqual(fetched.lastPathComponent, "reverse.bin")
        XCTAssertEqual(try Data(contentsOf: fetched), big)
        // Fetching is a copy: the Mac still holds it.
        XCTAssertEqual(delegate.served().count, 2)
        // …and the Mac only claims it was taken once every byte is there.
        XCTAssertEqual(delegate.servedOutcomes(), [.served(bigID)])

        try await client.remove(noteID)
        XCTAssertEqual(delegate.served().map(\.id), [bigID])
        XCTAssertFalse(FileManager.default.fileExists(atPath: noteURL.path))
        // The same session keeps working after a removal.
        let afterRemoval = try await client.list()
        XCTAssertEqual(afterRemoval.map(\.id), [bigID])

        await client.close()
    }

    /// A fetch for something the Mac no longer has must come back as a stated
    /// failure, not a hung phone waiting on bytes that will never arrive.
    func testFetchingAVanishedItemFails() async throws {
        let identity = MacIdentity(id: UUID(), name: "Loopback Mac")
        let delegate = LoopbackDelegate(
            identity: identity,
            spool: spoolDirectory,
            shelf: shelfDirectory,
            pairingSecret: nil
        )
        let server = WireServer(delegate: delegate)
        try server.start(identity: identity)
        defer { server.stop() }
        let port = try XCTUnwrap(waitForPort(server))
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)

        let offer = PairingOffer(
            macID: identity.id,
            macName: identity.name,
            secret: WireCrypto.randomSecret()
        )
        delegate.setPairingSecret(offer.secret)
        let deviceID = UUID()
        let mac = try await WirePairingClient.pair(
            offer: offer,
            endpoint: endpoint,
            deviceID: deviceID,
            deviceName: "Test iPhone"
        ) { _ in true }

        let client = try await WireRemoteClient.connect(
            to: endpoint,
            deviceID: deviceID,
            deviceKey: mac.deviceKey
        )
        do {
            _ = try await client.fetch(UUID(), into: spoolDirectory.appending(path: "inbox"))
            XCTFail("Fetching an unknown item must fail")
        } catch {
            // Expected — and the session survives it.
        }
        // Nothing was ever described, so there is no outcome to report: the
        // delegate raised the reason itself and must not also be told about it.
        XCTAssertEqual(delegate.servedOutcomes(), [])
        let stillListable = try await client.list()
        XCTAssertEqual(stillListable.count, 0)
        await client.close()
    }

    func testUnpairedDeviceIsRefused() async throws {
        let identity = MacIdentity(id: UUID(), name: "Loopback Mac")
        let delegate = LoopbackDelegate(
            identity: identity,
            spool: spoolDirectory,
            shelf: shelfDirectory,
            pairingSecret: nil
        )
        let server = WireServer(delegate: delegate)
        try server.start(identity: identity)
        defer { server.stop() }
        let port = try XCTUnwrap(waitForPort(server))
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)

        let url = spoolDirectory.appending(path: "nope.txt")
        try Data("refused".utf8).write(to: url)
        do {
            try await WireTransferClient.deliver(
                [try outgoingItem(for: url, kind: "text")],
                to: endpoint,
                deviceID: UUID(),
                deviceKey: Data(repeating: 9, count: 32)
            ) { _ in }
            XCTFail("An unpaired device must be refused")
        } catch {
            // Expected: the server answers `failure(.unpaired)` before keys.
        }
    }

    /// Regression: waiting for a Mac that never appears must time out, not
    /// deadlock. The first implementation leaked a continuation here and hung
    /// forever — which is the product's headline "Mac is away" case.
    func testWaitingForAnAbsentMacTimesOut() async {
        let started = Date()
        let endpoint = await WireBrowser.waitFor(macID: UUID(), timeout: .seconds(1))
        XCTAssertNil(endpoint)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    /// A zero-byte item is a real shelf item (an empty file dragged onto the
    /// notch), and its digest is the digest of nothing — the streamer must not
    /// treat "no chunks" as "nothing happened".
    func testFetchingAnEmptyItemLandsAnEmptyFile() async throws {
        let paired = try await pairedSession()
        defer { paired.server.stop() }

        let emptyURL = shelfDirectory.appending(path: "empty.txt")
        try Data().write(to: emptyURL)
        let emptyID = UUID()
        paired.delegate.place(emptyURL, id: emptyID)

        let inbox = spoolDirectory.appending(path: "inbox")
        let fetched = try await paired.client.fetch(emptyID, into: inbox)
        XCTAssertEqual(fetched.lastPathComponent, "empty.txt")
        XCTAssertEqual(try Data(contentsOf: fetched), Data())
        await paired.client.close()
    }

    /// The file shrank between the digest and the first byte. The phone must
    /// end up with nothing — not a short file wearing the real name — and the
    /// session must still be usable, exactly as a vanished item is.
    func testAFileThatShrankMidFetchLeavesNoPartialAndKeepsTheSession() async throws {
        let paired = try await pairedSession()
        defer { paired.server.stop() }

        let url = shelfDirectory.appending(path: "shrinking.bin")
        try Data(repeating: 0xAB, count: 2 << 20).write(to: url)
        let itemID = UUID()
        paired.delegate.place(url, id: itemID)
        paired.delegate.setMutationBeforeStreaming { url in
            try? Data(repeating: 0xAB, count: 1 << 10).write(to: url)
        }

        let inbox = spoolDirectory.appending(path: "inbox-shrank")
        do {
            _ = try await paired.client.fetch(itemID, into: inbox)
            XCTFail("A file that shrank underfoot must not land")
        } catch {
            // Expected.
        }
        XCTAssertEqual(try contents(of: inbox), [], "no partial and no wrongly-named file may survive")
        // The Mac described this item, so it must hear how it ended — its own
        // status line said "sending…" and has nothing else to resolve it.
        XCTAssertEqual(paired.delegate.servedOutcomes().map(\.itemID), [itemID])
        if case .served = paired.delegate.servedOutcomes().first {
            XCTFail("A file that shrank underfoot was not served")
        }
        // The contract this class already asserts for a vanished item: a failed
        // fetch is one failed request, not a dead session.
        _ = try await paired.client.list()
        await paired.client.close()
    }

    /// The mirror case: the file grew, so the Mac streams past the byte count it
    /// promised and the phone stops taking it part-way through.
    ///
    /// Regression: the abandoned item's remaining chunk frames were still in the
    /// socket, so the *next* request on that session read file bytes as its
    /// reply — a `list()` answered with a chunk. Nothing may land, and the
    /// session must say it is finished rather than answer from the backlog.
    func testAFileThatGrewMidFetchEndsTheSessionInsteadOfDesyncingIt() async throws {
        let paired = try await pairedSession()
        defer { paired.server.stop() }

        let url = shelfDirectory.appending(path: "growing.bin")
        try Data(repeating: 0xCD, count: 1 << 10).write(to: url)
        let itemID = UUID()
        paired.delegate.place(url, id: itemID)
        paired.delegate.setMutationBeforeStreaming { url in
            try? Data(repeating: 0xCD, count: 3 << 20).write(to: url)
        }

        let inbox = spoolDirectory.appending(path: "inbox-grew")
        do {
            _ = try await paired.client.fetch(itemID, into: inbox)
            XCTFail("A file that grew underfoot must not land")
        } catch {
            // Expected.
        }
        XCTAssertEqual(try contents(of: inbox), [], "no partial and no wrongly-named file may survive")
        do {
            _ = try await paired.client.list()
            XCTFail("A session abandoned mid-item must not answer another request")
        } catch WireClientError.sessionLost {
            // Expected: stated, not guessed. Answered locally, which is why it
            // works while the Mac is still pushing bytes at nobody.
        }
        // Hanging up is what tells the Mac the phone stopped reading. It must
        // then report the fetch as failed — its status line said "sending…" and
        // has nothing else to resolve it.
        await paired.client.close()
        switch await waitForOutcome(paired.delegate, itemID: itemID) {
        case let .failed(_, reason):
            XCTAssertFalse(reason.isEmpty)
        case .served:
            XCTFail("A file that grew underfoot was never served whole")
        case nil:
            XCTFail("The Mac must report a fetch the phone abandoned")
        }
    }

    /// Bytes that do not match the digest are a failed item, not a failed
    /// session: the Mac closed the item, so the phone can simply ask again.
    func testAWrongDigestFailsTheItemButNotTheSession() async throws {
        let paired = try await pairedSession()
        defer { paired.server.stop() }

        let url = shelfDirectory.appending(path: "swapped.bin")
        try Data(repeating: 0x11, count: 900 << 10).write(to: url)
        let itemID = UUID()
        paired.delegate.place(url, id: itemID)
        // Same length, different bytes: the offer's digest is already out and
        // only the digest check can catch this.
        paired.delegate.setMutationBeforeStreaming { url in
            try? Data(repeating: 0x22, count: 900 << 10).write(to: url)
        }

        let inbox = spoolDirectory.appending(path: "inbox-digest")
        do {
            _ = try await paired.client.fetch(itemID, into: inbox)
            XCTFail("Bytes that miss the digest must not land")
        } catch {
            // Expected.
        }
        XCTAssertEqual(try contents(of: inbox), [], "corrupt bytes must never get the real name")
        // The one place the Mac's account and the phone's disagree, honestly:
        // the Mac sent every byte it promised, so it reports the item served.
        // Only the phone can know the bytes stopped matching a digest taken
        // moments earlier, and the wire gives it no frame to say so. Rare
        // enough (same length, different bytes) to state rather than fix here.
        XCTAssertEqual(paired.delegate.servedOutcomes(), [.served(itemID)])
        _ = try await paired.client.list()
        await paired.client.close()
    }

    /// Two whole files down one session, back to back. Each must land complete
    /// — a fetch that leaves frames unread poisons the one after it.
    func testTwoFetchesOnOneSessionBothLandWhole() async throws {
        let paired = try await pairedSession()
        defer { paired.server.stop() }

        let firstURL = shelfDirectory.appending(path: "first.bin")
        let secondURL = shelfDirectory.appending(path: "second.bin")
        let first = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        let second = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 29) })
        try first.write(to: firstURL)
        try second.write(to: secondURL)
        let firstID = UUID()
        let secondID = UUID()
        paired.delegate.place(firstURL, id: firstID)
        paired.delegate.place(secondURL, id: secondID)

        let inbox = spoolDirectory.appending(path: "inbox-two")
        let firstLanded = try await paired.client.fetch(firstID, into: inbox.appending(path: "a"))
        XCTAssertEqual(try Data(contentsOf: firstLanded), first)
        let secondLanded = try await paired.client.fetch(secondID, into: inbox.appending(path: "b"))
        XCTAssertEqual(try Data(contentsOf: secondLanded), second)
        // One outcome per served item, in order — not one per chunk, not one
        // for the pair.
        XCTAssertEqual(paired.delegate.servedOutcomes(), [.served(firstID), .served(secondID)])
        await paired.client.close()
    }

    // MARK: - Helpers

    /// A running server with one paired phone and an open session: what every
    /// reverse-direction test needs before it can say anything interesting.
    private struct PairedSession {
        let server: WireServer
        let delegate: LoopbackDelegate
        let client: WireRemoteClient
    }

    private func pairedSession() async throws -> PairedSession {
        let identity = MacIdentity(id: UUID(), name: "Loopback Mac")
        let delegate = LoopbackDelegate(
            identity: identity,
            spool: spoolDirectory,
            shelf: shelfDirectory,
            pairingSecret: nil
        )
        let server = WireServer(delegate: delegate)
        try server.start(identity: identity)
        let port = try XCTUnwrap(waitForPort(server))
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        let offer = PairingOffer(
            macID: identity.id,
            macName: identity.name,
            secret: WireCrypto.randomSecret()
        )
        delegate.setPairingSecret(offer.secret)
        let deviceID = UUID()
        let mac = try await WirePairingClient.pair(
            offer: offer,
            endpoint: endpoint,
            deviceID: deviceID,
            deviceName: "Test iPhone"
        ) { _ in true }
        return PairedSession(
            server: server,
            delegate: delegate,
            client: try await WireRemoteClient.connect(
                to: endpoint,
                deviceID: deviceID,
                deviceKey: mac.deviceKey
            )
        )
    }

    /// A fetch outcome the Mac reports from its own task. When the phone stops
    /// reading part-way it has no idea when that lands, so poll for it.
    private func waitForOutcome(
        _ delegate: LoopbackDelegate,
        itemID: UUID,
        timeout: Duration = .seconds(5)
    ) async -> LoopbackDelegate.ServeOutcome? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let outcome = delegate.servedOutcomes().first(where: { $0.itemID == itemID }) {
                return outcome
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    /// What the phone actually has in a fetch directory, hidden `.partial`
    /// spools included — the whole point of these assertions.
    private func contents(of directory: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    private func waitForPort(_ server: WireServer, attempts: Int = 50) -> UInt16? {
        for _ in 0..<attempts {
            if let port = server.port, port != 0 {
                return port
            }
            usleep(100_000)
        }
        return nil
    }

    private func outgoingItem(for url: URL, kind: String) throws -> OutgoingItem {
        let data = try Data(contentsOf: url)
        return OutgoingItem(
            offered: OfferedItem(
                id: UUID(),
                displayName: url.lastPathComponent,
                contentTypeIdentifier: nil,
                kindHint: kind,
                byteCount: Int64(data.count),
                sha256: Data(SHA256.hash(data: data))
            ),
            fileURL: url
        )
    }
}

/// A wire-server delegate with no UI and no ShelfStore: auto-approves, keeps
/// the one paired peer in memory, commits arrivals into a flat directory.
private final class LoopbackDelegate: WireServerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let macIdentity: MacIdentity
    private let spool: URL
    private let shelf: URL
    private var secret: Data?
    private var peer: PairedPeer?
    private var shelved: [(id: UUID, url: URL)] = []
    private var mutateBeforeStreaming: (@Sendable (URL) -> Void)?
    private var outcomes: [ServeOutcome] = []

    /// How a fetch this delegate described actually ended.
    enum ServeOutcome: Equatable {
        case served(UUID)
        case failed(UUID, String)

        var itemID: UUID {
            switch self {
            case let .served(id): id
            case let .failed(id, _): id
            }
        }
    }

    init(identity: MacIdentity, spool: URL, shelf: URL, pairingSecret: Data?) {
        macIdentity = identity
        self.spool = spool
        self.shelf = shelf
        secret = pairingSecret
    }

    func setPairingSecret(_ new: Data?) {
        lock.withLock { secret = new }
    }

    var storedPeer: PairedPeer? {
        lock.withLock { peer }
    }

    func identity() -> MacIdentity {
        macIdentity
    }

    func activePairingSecret() -> Data? {
        lock.withLock { secret }
    }

    func approvePairing(deviceID: UUID, deviceName: String, code: String) -> Bool {
        true
    }

    func storePairedPeer(_ newPeer: PairedPeer) throws {
        lock.withLock { peer = newPeer }
    }

    func pairedPeer(for deviceID: UUID) -> PairedPeer? {
        lock.withLock { peer?.id == deviceID ? peer : nil }
    }

    func admit(_ items: [OfferedItem], from peer: PairedPeer) -> (accepted: [OfferedItem], refused: [RefusedItem]) {
        (items, [])
    }

    func spoolDirectory() throws -> URL {
        spool
    }

    func commit(_ item: OfferedItem, stagedFileURL: URL, from peer: PairedPeer) throws {
        let landed = shelf.appending(path: item.displayName)
        try FileManager.default.moveItem(at: stagedFileURL, to: landed)
        lock.withLock { shelved.append((id: item.id, url: landed)) }
    }

    func transferFailed(_ item: OfferedItem, from peer: PairedPeer, reason: String) {}

    // MARK: - Serving the shelf back

    /// Everything committed here, in arrival order — the loopback stand-in for
    /// the Mac's ShelfStore.
    func served() -> [(id: UUID, url: URL)] {
        lock.withLock { shelved }
    }

    func shelfEntries(for peer: PairedPeer) -> [RemoteEntry] {
        lock.withLock { shelved }.map { entry in
            let size = (try? entry.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return RemoteEntry(
                id: entry.id,
                displayName: entry.url.lastPathComponent,
                kindHint: "file",
                contentTypeIdentifier: nil,
                byteCount: Int64(size),
                addedAt: Date()
            )
        }
    }

    func readItem(_ itemID: UUID, for peer: PairedPeer) throws -> OutgoingItem {
        guard let entry = lock.withLock({ shelved.first { $0.id == itemID } }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let outgoing = try WireStreaming.offer(
            id: entry.id,
            displayName: entry.url.lastPathComponent,
            contentTypeIdentifier: nil,
            kindHint: "file",
            fileURL: entry.url
        )
        // The offer is out; anything the test does to the file now is the
        // "changed underfoot between the digest and the bytes" case.
        lock.withLock { mutateBeforeStreaming }?(entry.url)
        return outgoing
    }

    /// Rewrites a shelf file after its offer is built but before a byte moves.
    func setMutationBeforeStreaming(_ hook: (@Sendable (URL) -> Void)?) {
        lock.withLock { mutateBeforeStreaming = hook }
    }

    func itemServed(_ item: OfferedItem, to peer: PairedPeer) {
        lock.withLock { outcomes.append(.served(item.id)) }
    }

    func serveFailed(_ item: OfferedItem, to peer: PairedPeer, reason: String) {
        lock.withLock { outcomes.append(.failed(item.id, reason)) }
    }

    /// Every fetch outcome this delegate was told about, in order.
    func servedOutcomes() -> [ServeOutcome] {
        lock.withLock { outcomes }
    }

    func removeItem(_ itemID: UUID, for peer: PairedPeer) throws {
        let removed: URL? = lock.withLock {
            guard let index = shelved.firstIndex(where: { $0.id == itemID }) else { return nil }
            return shelved.remove(at: index).url
        }
        guard let removed else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.removeItem(at: removed)
    }

    /// Puts a file on the loopback shelf without a transfer, so the reverse
    /// direction can be tested on its own.
    func place(_ url: URL, id: UUID = UUID()) {
        lock.withLock { shelved.append((id: id, url: url)) }
    }
}

/// Event sink usable from a @Sendable callback.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [TransferEvent] = []

    func append(_ event: TransferEvent) {
        lock.withLock { events.append(event) }
    }

    var stored: [UUID] {
        lock.withLock {
            events.compactMap {
                if case let .stored(id) = $0 { return id }
                return nil
            }
        }
    }
}
