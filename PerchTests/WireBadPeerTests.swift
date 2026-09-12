import CryptoKit
import Foundation
import Network
import XCTest

@testable import Perch

/// The phone against a Mac that breaks its own promises.
///
/// Three of them, all reached through one `fetch`: a Mac that streams past the
/// length it offered, one that offers an item the phone never named, and one
/// that streams bytes having offered nothing at all. Our own `WireServer` can
/// make none of these mistakes — it is held to its own offer on the way out,
/// and it answers a fetch with that offer or a failure and nothing else — so
/// the peer below is hand-rolled. Built out of the real server it would stop
/// being bad the moment the server's own guard tightened.
final class WireBadPeerTests: XCTestCase {
    private var inbox: URL!

    override func setUpWithError() throws {
        inbox = FileManager.default.temporaryDirectory
            .appending(path: "WireBadPeer-\(UUID().uuidString)")
            .appending(path: "inbox")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: inbox.deletingLastPathComponent())
    }

    /// The Mac offers N bytes and then streams more than N. Nothing may land,
    /// and the session is finished: the chunks already on their way would
    /// otherwise answer the *next* request — a `list()` replying with file
    /// bytes. The phone must say so from its own state, before it asks.
    func testAMacThatStreamsPastItsOfferEndsTheSessionInsteadOfDesyncingIt() async throws {
        let (peer, client) = try await session(with: .streamsPastItsOffer)

        do {
            _ = try await client.fetch(peer.itemID, into: inbox)
            XCTFail("Bytes past the offer must not land")
        } catch WireClientError.peerFailure {
            // Expected: a chunk that crosses the offer is a peer bug, stated
            // as one rather than written to disk.
        }

        try await assertTheSessionIsFinished(client, peer)
    }

    /// The Mac answers the fetch with an offer for something else. The phone
    /// has just been handed a reply belonging to no request it made, so it can
    /// no longer pair *any* reply with a request — and the stranger's bytes
    /// are already on their way behind the offer.
    func testAMacThatOffersAnItemThePhoneNeverAskedForEndsTheSession() async throws {
        let (peer, client) = try await session(with: .offersAnotherItem)

        do {
            _ = try await client.fetch(peer.itemID, into: inbox)
            XCTFail("An offer for another item must not be fetched")
        } catch WireClientError.unexpectedReply {
            // Expected: the bytes may be perfectly good, but they are not the
            // ones that were asked for and nothing here says which are.
        }

        try await assertTheSessionIsFinished(client, peer)
    }

    /// The Mac answers the fetch with file bytes and no offer at all — no
    /// length, no digest, nothing to hold them to. The same verdict: refuse
    /// them, and end a session whose next reply is now a chunk.
    func testAMacThatStreamsAnItemItNeverOfferedEndsTheSession() async throws {
        let (peer, client) = try await session(with: .streamsWithoutOffering)

        do {
            _ = try await client.fetch(peer.itemID, into: inbox)
            XCTFail("Bytes with no offer behind them must not land")
        } catch WireClientError.unexpectedReply {
            // Expected: an unoffered chunk is a peer bug, and an unbounded one.
        }

        try await assertTheSessionIsFinished(client, peer)
    }

    // MARK: - The session under test

    /// A peer with one fault in it and a phone dialled into it. No pairing:
    /// both halves of this session are ours, so the device key both sides
    /// derive from is simply a number they already agree on.
    private func session(
        with fault: BadPeer.Fault
    ) async throws -> (BadPeer, WireRemoteClient) {
        let deviceKey = Data(repeating: 0x5A, count: 32)
        let peer = BadPeer(deviceKey: deviceKey, fault: fault)
        try peer.start()
        addTeardownBlock { peer.stop() }
        let client = try await WireRemoteClient.connect(
            to: try await peer.endpoint(),
            deviceID: UUID(),
            deviceKey: deviceKey
        )
        // Teardown rather than a `defer`, so the socket still closes on the
        // day one of these assertions throws something nobody expected.
        addTeardownBlock { await client.close() }
        return (peer, client)
    }

    /// What every one of these faults costs, whatever the fetch itself said.
    ///
    /// Nothing the phone could hand to another app is left in the fetch
    /// directory — no `.partial` spool, no wrongly-named file — and the next
    /// request is refused by the phone's own state, taken before it goes
    /// anywhere near the backlog of frames still in the socket. The peer is
    /// still perfectly willing to answer a list, so a phone that reaches it
    /// has done the thing that must not happen.
    private func assertTheSessionIsFinished(
        _ client: WireRemoteClient,
        _ peer: BadPeer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        XCTAssertEqual(
            try contents(of: inbox), [],
            "no partial and no wrongly-named file may survive",
            file: file,
            line: line
        )

        do {
            _ = try await client.list()
            XCTFail("A session abandoned mid-item must not answer another request", file: file, line: line)
        } catch WireClientError.sessionLost {
            // Expected.
        }
        XCTAssertEqual(peer.listRequestCount(), 0, file: file, line: line)
    }

    /// What the phone actually has in a fetch directory, hidden `.partial`
    /// spools included — the whole point of that assertion.
    private func contents(of directory: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }
}

/// A Mac that breaks exactly one promise, chosen when it is built.
///
/// It speaks the protocol from the hello onwards and nothing else — no
/// pairing, and deliberately no Bonjour service, so it is reachable only by
/// the test that dials it.
private final class BadPeer: @unchecked Sendable {
    /// Which promise this one breaks — one each, and one only, so a test that
    /// goes red says which mistake it went red for. All three are answers to a
    /// `fetchItem`, the only request whose reply is a stream, and so the only
    /// one that leaves the rest of itself in the socket when the phone refuses
    /// what it was handed.
    enum Fault {
        /// Offers N bytes and then streams more: the shape of a Mac whose file
        /// grew after it was hashed, and of any peer whose sender never
        /// checked.
        case streamsPastItsOffer
        /// Offers an item nobody asked for: the shape of a Mac that lined a
        /// reply up with the wrong request.
        case offersAnotherItem
        /// Streams with no offer in front of it: no length, no digest, nothing
        /// to hold the bytes to.
        case streamsWithoutOffering
    }

    /// What an offer claims. Small, so the phone accepts all of it before the
    /// first byte too many arrives.
    static let offeredByteCount = 1 << 10
    /// And what the phone walks away from. Several frames, because one
    /// stranded frame would not be a backlog — the desync this guards against
    /// is the next request reading a queue of them as its reply.
    static let strandedChunkSize = 64 << 10
    static let strandedChunks = 4
    /// Those frames' bytes, as one run: the same filler for every fault, since
    /// no test looks at them. Reading them at all is the bug.
    static let stranded = Data(
        repeating: 0xE2,
        count: BadPeer.strandedChunkSize * BadPeer.strandedChunks
    )

    /// The item the phone asks for. What comes back is the fault's business.
    let itemID = UUID()

    private let deviceKey: Data
    private let fault: Fault
    private let lock = NSLock()
    private var listener: NWListener?
    private var connection: WireConnection?
    private var listRequests = 0

    init(deviceKey: Data, fault: Fault) {
        self.deviceKey = deviceKey
        self.fault = fault
    }

    func start() throws {
        let listener = try NWListener(using: NWParameters.tcp)
        listener.newConnectionHandler = { [weak self] raw in
            guard let self else {
                raw.cancel()
                return
            }
            let connection = WireConnection(connection: raw)
            lock.withLock { self.connection = connection }
            Task { await self.run(connection) }
        }
        listener.start(queue: .global(qos: .userInitiated))
        lock.withLock { self.listener = listener }
    }

    func stop() {
        let (listener, connection) = lock.withLock {
            defer {
                self.listener = nil
                self.connection = nil
            }
            return (self.listener, self.connection)
        }
        listener?.cancel()
        Task { await connection?.cancel() }
    }

    /// How many times the phone asked for a shelf listing. Zero is the
    /// assertion: a lost session is answered locally.
    func listRequestCount() -> Int {
        lock.withLock { listRequests }
    }

    /// Where to dial, once Network.framework has bound the listener a port.
    ///
    /// Named error rather than a bare timeout: xcodebuild prints a duration,
    /// and a red run has to say which wait ran out. The budget is a
    /// failure-path number — a healthy run leaves after a poll or two.
    func endpoint(timeout: Duration = .seconds(30)) async throws -> NWEndpoint {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let raw = lock.withLock({ listener?.port?.rawValue }),
               raw != 0,
               let port = NWEndpoint.Port(rawValue: raw) {
                return .hostPort(host: .ipv4(.loopback), port: port)
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        throw BadPeerWait.neverBoundAPort(timeout)
    }

    enum BadPeerWait: Error, CustomStringConvertible {
        case neverBoundAPort(Duration)

        var description: String {
            switch self {
            case let .neverBoundAPort(timeout):
                "The bad peer's listener never bound a port in \(timeout)."
            }
        }
    }

    // MARK: - The session

    private func run(_ connection: WireConnection) async {
        do {
            try await connection.start()
            guard case let .hello(_, _, phoneNonce) = try await connection.receivePlaintextMessage() else {
                return
            }
            let macNonce = WireCrypto.randomSecret(16)
            try await connection.sendPlaintext(.helloAck(macName: "Bad Peer", nonce: macNonce))
            let keys = WireCrypto.sessionKeys(
                deviceKey: SymmetricKey(data: deviceKey),
                phoneNonce: phoneNonce,
                macNonce: macNonce
            )
            await connection.secure(
                send: FrameCryptor(key: keys.macToPhone),
                receive: FrameCryptor(key: keys.phoneToMac)
            )

            while true {
                switch try await connection.receive() {
                case let .control(.fetchItem(requested)) where requested == itemID:
                    switch fault {
                    case .streamsPastItsOffer: try await streamPastTheOffer(on: connection)
                    case .offersAnotherItem: try await offerAnotherItem(on: connection)
                    case .streamsWithoutOffering: try await streamWithoutOffering(on: connection)
                    }
                case .control(.shelfListRequest):
                    // Answered, and correctly — so a phone that reaches here
                    // proves it asked, which is the thing that must not happen.
                    lock.withLock { listRequests += 1 }
                    try await connection.send(.control(.shelfList(entries: [])))
                case .control(.bye):
                    return
                default:
                    continue
                }
            }
        } catch {
            // The phone stops reading part-way through by design, so every
            // send after that point is expected to fail eventually. There is
            // nobody left to tell.
        }
    }

    // MARK: - The faults

    /// Exactly the offer's worth, which the phone takes, and then the bytes it
    /// never agreed to hold.
    private func streamPastTheOffer(on connection: WireConnection) async throws {
        let promised = Data(repeating: 0xE1, count: Self.offeredByteCount)
        try await connection.send(.control(.offer(transferID: UUID(), items: [
            // The digest of what was offered, not of what is sent: a Mac whose
            // file grew hashed the smaller one.
            offer(of: itemID, named: "overrun.bin", bytes: promised),
        ])))
        try await connection.send(.chunk(itemID: itemID, offset: 0, data: promised))
        try await strand(itemID, from: Int64(promised.count), on: connection)
        try await connection.send(.control(.itemDone(itemID: itemID)))
    }

    /// A whole, honest item — offered to its true length and digest, streamed
    /// and closed to the letter. Only the id is wrong, which is enough: the
    /// phone has a reply belonging to no request it made, and the frames
    /// behind it say no more about which request they answer.
    private func offerAnotherItem(on connection: WireConnection) async throws {
        let stranger = UUID()
        try await connection.send(.control(.offer(transferID: UUID(), items: [
            offer(of: stranger, named: "someone-elses.bin", bytes: Self.stranded),
        ])))
        try await strand(stranger, from: 0, on: connection)
        try await connection.send(.control(.itemDone(itemID: stranger)))
    }

    /// The right item, straight to its bytes. Skipping the offer is what makes
    /// the stream unbounded: there is no length to read it up to.
    private func streamWithoutOffering(on connection: WireConnection) async throws {
        try await strand(itemID, from: 0, on: connection)
        try await connection.send(.control(.itemDone(itemID: itemID)))
    }

    /// `stranded`, as the frames left in the socket once the phone has walked
    /// away — sequential from `start`, since a peer that is wrong about its
    /// offsets too would be failed for the wrong reason.
    private func strand(_ id: UUID, from start: Int64, on connection: WireConnection) async throws {
        var offset = start
        for frame in 0..<Self.strandedChunks {
            let begin = frame * Self.strandedChunkSize
            let extra = Self.stranded[begin ..< begin + Self.strandedChunkSize]
            try await connection.send(.chunk(itemID: id, offset: offset, data: Data(extra)))
            offset += Int64(extra.count)
        }
    }

    private func offer(of id: UUID, named name: String, bytes: Data) -> OfferedItem {
        OfferedItem(
            id: id,
            displayName: name,
            contentTypeIdentifier: nil,
            kindHint: "file",
            byteCount: Int64(bytes.count),
            sha256: Data(SHA256.hash(data: bytes))
        )
    }
}
